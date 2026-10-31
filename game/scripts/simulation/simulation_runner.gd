class_name SimulationRunner
extends Node
## Inline clock or frontend consumer of the worker clock. Engine.time_scale
## stays at 1; exactly one executor advances the world and retains backlog.
signal frame_updated
signal step_completed(elapsed_usec: int)
var world: SimulationWorld
var presentation: WorldPresentation
var access: SimulationAccess
var snapshot_age_msec: float = 0.0
var _motion_publication_usec: int = 0
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
	_last_usec = Time.get_ticks_usec()

func _exit_tree() -> void:
	if access != null and access.executor != null:
		access.close()

func _submit_control(kind: SimulationCommand.Kind, integer: int = 0, scalar: float = 0.0, scenario: ScenarioConfig = null) -> bool:
	var command := SimulationCommand.new()
	command.kind = kind
	command.integer = integer
	command.scalar = scalar
	command.scenario = scenario.duplicate() as ScenarioConfig if scenario != null else null
	return access.submit(command)

func request_reset(scenario: ScenarioConfig) -> void:
	if access != null:
		_submit_control(SimulationCommand.Kind.RESET, 0, 0.0, scenario)
		return
	_pending_reset = scenario.duplicate() as ScenarioConfig

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
	# Bounded frontend work; a busy worker never forces a join. Old snapshots
	# remain visible with their age instead of extrapolating uncomputed movement.
	for index: int in 4:
		if index > 0 and Time.get_ticks_usec() - started >= 3000:
			break
		var next: SimulationPublication = access.executor.poll()
		if next == null:
			break
		var prior_tick: int = access.tick
		var prior_epoch: int = access.store.epoch
		var was_paused: bool = paused
		access.adopt(next)
		paused = next.paused
		if not access.has_pending_control(SimulationCommand.Kind.PAUSE):
			_pending_pause = -1
		speed = next.speed
		accumulator_seconds = next.backlog_seconds
		presentation.bind_publication(access)
		access.deliver_captures()
		presentation.observe_published(next.tick)
		if next.tick > prior_tick or prior_epoch != access.store.epoch:
			_motion_publication_usec = next.published_usec
			_display_current_until_step = false
			last_step_count += 1
			for phase: int in 7:
				frame_phase_usec[phase] += next.phase_usec[phase]
		elif was_paused and not paused:
			_display_current_until_step = true
	var now: int = Time.get_ticks_usec()
	snapshot_age_msec = float(now - _motion_publication_usec) / 1000.0 if _motion_publication_usec > 0 else 0.0
	var alpha: float = clampf(float(now - _motion_publication_usec) / (access.config.fixed_dt * 1000000.0), 0.0, 1.0)
	presentation.present(access.tick, alpha, paused or _display_current_until_step)
	cpu_frame_msec = float(Time.get_ticks_usec() - started) / 1000.0
	if _ui_seconds >= 0.2:
		_ui_seconds = 0.0
		frame_updated.emit()

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
