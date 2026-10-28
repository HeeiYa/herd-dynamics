class_name SimulationRunner
extends Node
## The only simulation clock. Engine.time_scale stays at 1; backlog is retained.
signal frame_updated
var world: SimulationWorld
var presentation: WorldPresentation
var paused: bool = false
var speed: float = 1.0
var accumulator_seconds: float = 0.0
var last_step_count: int = 0
var frame_phase_usec := PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
var cpu_frame_msec: float = 0.0
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

func request_reset(scenario: ScenarioConfig) -> void:
	_pending_reset = scenario.duplicate() as ScenarioConfig

func request_pause(value: bool) -> void:
	_pending_pause = int(value)

func request_single_step() -> void:
	_pending_pause = 1
	_single_step = true

func _process(_delta: float) -> void:
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
	last_step_count = 0
	if _single_step:
		_run_step()
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

func _run_step() -> void:
	world.step()
	presentation.observe_published(world.tick)
	_display_current_until_step = false
	last_step_count += 1
	for phase: int in range(frame_phase_usec.size()):
		frame_phase_usec[phase] += world.phase_usec[phase]

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
