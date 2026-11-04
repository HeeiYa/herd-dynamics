class_name SimulationRunner
extends Node
## Inline clock or frontend consumer of the worker clock. Engine.time_scale
## stays at 1; exactly one executor advances the world and retains backlog.
signal display_committed
signal frame_updated
signal step_completed(elapsed_usec: int)
var world: SimulationWorld
var presentation: WorldPresentation
var access: SimulationAccess
var snapshot_age_msec: float = 0.0
# Cooperative frontend budget; engine submission and signal handlers are atomic.
const FRONTEND_BUDGET_USEC: int = 5000
const EVENT_BUDGET_USEC: int = 750
const COMMIT_RESERVE_USEC: int = 500
var event_usec: int = 0
var prepare_usec: int = 0
var commit_usec: int = 0
var budget_overrun_usec: int = 0
var display_sequence: int = -1
var committed_frames: int = 0
var skipped_display_states: int = 0
var _front_job: PresentationJob
var _back_job := PresentationJob.new()
var _building: bool = false
var paused: bool = false
var pause_requested: bool:
	get: return _pending_pause == 1 if _pending_pause >= 0 else paused
var speed: float = 1.0
var accumulator_seconds: float = 0.0
var last_step_count: int = 0
var frame_phase_usec := PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
var cpu_frame_msec: float = 0.0
# Instrumented frame totals include every catch-up step; never sum last-step
# snapshots as if they covered the full frame.
var frame_observe_usec: int = 0
var frame_field_build_usec: int = 0
var frame_field_sample_usec: int = 0
var frame_exact_sample_usec: int = 0
var frame_moved_agent_steps: int = 0
var frame_displacement_pixels: float = 0.0
var frame_intervals: Array[float] = []
var _sample_cursor: int = 0
var _last_usec: int = 0
var _ui_seconds: float = 0.0
var _pending_reset: ScenarioConfig
var _single_step: bool = false
var _pending_pause: int = -1
var _display_current_until_step: bool = false

func setup(simulation: SimulationWorld, view: WorldPresentation) -> void:
	world = simulation
	presentation = view
	_last_usec = Time.get_ticks_usec()

func setup_threaded(observer: SimulationAccess, view: WorldPresentation) -> void:
	access = observer
	presentation = view
	process_priority = 30 # Observer tools (10) and camera (20) respond first.
	access.delivery_completed.connect(_on_delivery)
	_last_usec = Time.get_ticks_usec()

func _exit_tree() -> void:
	if access != null and access.executor != null:
		access.close()

func _submit_control(kind: SimulationCommand.Kind, integer: int = 0, scalar: float = 0.0, scenario: ScenarioConfig = null) -> bool:
	var command := SimulationCommand.new()
	command.kind = kind
	command.integer = integer
	command.scalar = scalar
	command.scenario = scenario.duplicate(true) as ScenarioConfig if scenario != null else null
	return access.submit(command)

func request_reset(scenario: ScenarioConfig) -> bool:
	var owned: ScenarioConfig = scenario.validated_copy() if scenario != null else null
	if owned == null:
		return false
	if access != null:
		return _submit_control(SimulationCommand.Kind.RESET, 0, 0.0, owned)
	_pending_reset = owned
	return true

func request_pause(value: bool) -> void:
	if access != null:
		if _submit_control(SimulationCommand.Kind.PAUSE, int(value)):
			_pending_pause = int(value)
		return
	_pending_pause = int(value)

func request_single_step() -> void:
	if access != null:
		_submit_control(SimulationCommand.Kind.SINGLE_STEP)
		return
	_pending_pause = 1
	_single_step = true

func set_speed(value: float) -> bool:
	if not is_finite(value) or value <= 0.0:
		return false
	if access != null:
		return _submit_control(SimulationCommand.Kind.SPEED, 0, value)
	if not is_equal_approx(speed, value):
		speed = value
		world.record_observer_event("time_scale", {"value": speed})
	return true

func _process(_delta: float) -> void:
	if access != null:
		_process_publications()
		return
	if world == null:
		return
	var frame_start: int = Time.get_ticks_usec()
	var elapsed: float = float(frame_start - _last_usec) / 1000000.0
	_last_usec = frame_start
	_record_frame_interval(elapsed * 1000.0)
	_ui_seconds += elapsed
	if _pending_pause >= 0:
		var was_paused: bool = paused
		paused = _pending_pause == 1
		if paused != was_paused:
			world.record_observer_event("pause", {"value": paused})
		_pending_pause = -1
		# Pause has already shown S(n). Interpolating the old interval on resume
		# would move the display clock backward until another step is published.
		if was_paused and not paused:
			_display_current_until_step = true
		elif paused:
			_display_current_until_step = false
		# Do not add time measured on the other side of a pause transition.
		elapsed = 0.0
	if _pending_reset != null:
		world.reset(_pending_reset)
		presentation.bind_world(world)
		presentation.set_seed(world.scenario.random_seed)
		_pending_reset = null
		accumulator_seconds = 0.0
		elapsed = 0.0
		_single_step = false
		_display_current_until_step = false
	world.ai.begin_frame()
	frame_phase_usec.fill(0)
	frame_observe_usec = 0
	frame_field_build_usec = 0
	frame_field_sample_usec = 0
	frame_exact_sample_usec = 0
	frame_moved_agent_steps = 0
	frame_displacement_pixels = 0.0
	last_step_count = 0
	if _single_step:
		_run_step()
		world.record_observer_event("single_step")
		_single_step = false
	elif not paused:
		accumulator_seconds += elapsed * speed
		while accumulator_seconds >= world.config.fixed_dt and last_step_count < world.config.max_catchup_steps:
			_run_step()
			accumulator_seconds -= world.config.fixed_dt
	var alpha: float = clampf(accumulator_seconds / world.config.fixed_dt, 0.0, 1.0)
	presentation.present(world.tick, alpha, paused or _display_current_until_step)
	cpu_frame_msec = float(Time.get_ticks_usec() - frame_start) / 1000.0
	if _ui_seconds >= 0.2:
		_ui_seconds = 0.0
		frame_updated.emit()

func _process_publications() -> void:
	var started: int = Time.get_ticks_usec()
	var elapsed: float = float(started - _last_usec) / 1000000.0
	_last_usec = started
	_record_frame_interval(elapsed * 1000.0)
	_ui_seconds += elapsed
	frame_phase_usec.fill(0)
	last_step_count = 0
	event_usec = 0
	prepare_usec = 0
	commit_usec = 0
	access.pump_events(started + EVENT_BUDGET_USEC)
	event_usec = Time.get_ticks_usec() - started
	var next: SimulationPublication = access.executor.poll_state(access.delivered_sequence)
	if next != null:
		access.adopt(next)
	if access.control_status != null:
		paused = access.control_status.paused
		speed = access.control_status.speed
		accumulator_seconds = access.control_status.backlog_seconds
		if not access.has_pending_control(SimulationCommand.Kind.PAUSE):
			_pending_pause = -1
	# Cancel an obsolete epoch before it can become the front frame.
	if _building and _back_job.source.epoch != access.store.epoch:
		_building = false
	var preparation_start: int = Time.get_ticks_usec()
	var preparation_deadline: int = started + FRONTEND_BUDGET_USEC - COMMIT_RESERVE_USEC
	if access.publication.completed_usec > 0 and preparation_start < preparation_deadline:
		if not _building:
			var age_usec: int = preparation_start - access.publication.completed_usec
			var alpha: float = clampf(float(age_usec) / (access.config.fixed_dt * 1000000.0), 0.0, 1.0)
			_back_job.begin(presentation, access.publication, alpha, paused)
			_building = true
		_back_job.advance(preparation_deadline)
	prepare_usec = Time.get_ticks_usec() - preparation_start
	if _building and _back_job.phase == PresentationJob.Phase.READY and Time.get_ticks_usec() <= preparation_deadline:
		var commit_start: int = Time.get_ticks_usec()
		presentation.commit_job(_back_job)
		access.acknowledge_display(_back_job.source.sequence)
		var previous_front: PresentationJob = _front_job
		_front_job = _back_job
		_back_job = previous_front if previous_front != null else PresentationJob.new()
		_building = false
		if display_sequence >= 0:
			skipped_display_states += maxi(0, _front_job.source.sequence - display_sequence - 1)
		display_sequence = _front_job.source.sequence
		committed_frames += 1
		display_committed.emit()
		commit_usec = Time.get_ticks_usec() - commit_start
	presentation.render_build_usec = prepare_usec + commit_usec
	# HUD work shares the allowance and can wait until another frame.
	if _ui_seconds >= 0.2 and Time.get_ticks_usec() < preparation_deadline:
		_ui_seconds = 0.0
		frame_updated.emit()
	var now: int = Time.get_ticks_usec()
	snapshot_age_msec = display_age_msec(now)
	cpu_frame_msec = float(now - started) / 1000.0
	budget_overrun_usec = maxi(0, now - started - FRONTEND_BUDGET_USEC)

func display_age_msec(now_usec: int) -> float:
	if _front_job == null:
		return 0.0
	var source: SimulationPublication = _front_job.source
	var displayed_usec: float = source.completed_usec
	if not _front_job.direct:
		# Use the actual wall-clock endpoints, including slow or accelerated
		# simulation. A nominal fixed_dt is not a wall duration under overload.
		displayed_usec = lerpf(source.previous_completed_usec, source.completed_usec, _front_job.alpha)
	return (now_usec - displayed_usec) / 1000.0

func _on_delivery(metrics: SimulationTelemetry) -> void:
	if metrics.step_usec <= 0:
		return
	last_step_count += 1
	for phase: int in 7:
		frame_phase_usec[phase] += metrics.phase_usec[phase]

func _run_step() -> void:
	var started: int = Time.get_ticks_usec()
	world.step()
	var elapsed_usec: int = Time.get_ticks_usec() - started
	var observe_start: int = Time.get_ticks_usec() if world.probes.enabled else 0
	presentation.observe_published(world.tick)
	if world.probes.enabled:
		frame_observe_usec += Time.get_ticks_usec() - observe_start
		frame_field_build_usec += world.motion.field_build_usec
		frame_field_sample_usec += world.motion.field_sample_usec
		frame_exact_sample_usec += world.motion.exact_sample_usec
		frame_moved_agent_steps += world.motion.moving_agent_count
		frame_displacement_pixels += world.motion.displacement_sum
	_display_current_until_step = false
	last_step_count += 1
	for phase: int in range(frame_phase_usec.size()):
		frame_phase_usec[phase] += world.phase_usec[phase]
	step_completed.emit(elapsed_usec)

func _record_frame_interval(milliseconds: float) -> void:
	if frame_intervals.size() < 600:
		frame_intervals.append(milliseconds)
	else:
		frame_intervals[_sample_cursor] = milliseconds
		_sample_cursor = (_sample_cursor + 1) % 600

func frame_percentile(fraction: float) -> float:
	if frame_intervals.is_empty():
		return 0.0
	var sorted: Array[float] = frame_intervals.duplicate()
	sorted.sort()
	return sorted[clampi(ceili(fraction * sorted.size()) - 1, 0, sorted.size() - 1)]
