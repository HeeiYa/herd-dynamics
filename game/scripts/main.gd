extends Node2D
## Creates branch-specific simulation services and wires the observer scene.

var _world: SimulationWorld
var _access: SimulationAccess
var _view: WorldPresentation
var _runner: SimulationRunner
var _camera: ObserverCamera
var _insight: InsightOverlay
var _grab: GrabTool
var _session_log: ObserverSessionLog
@onready var observer: ObserverController = $ObserverController
@onready var hud: ObserverHud = $Interface/ObserverHud

func _ready() -> void:
	if not has_meta("benchmark_view"):
		for argument: String in OS.get_cmdline_user_args():
			if argument == "--benchmark=execution":
				get_tree().root.add_child.call_deferred(ExecutionBenchmark.new())
				queue_free()
				return
			if argument in ["--benchmark=cpu", "--benchmark=frames", "--benchmark=threat", "--benchmark=threat-cohort"]:
				get_tree().root.add_child.call_deferred(BenchmarkSession.new())
				queue_free()
				return
	RenderingServer.set_default_clear_color(UiStyle.BACKDROP)
	# Run after the runner so tools and overlays see this frame's publication.
	process_priority = 10
	call_deferred("_initialize")

func _initialize() -> void:
	var scenario := ScenarioConfig.new()
	scenario.layout = ScenarioConfig.Layout.NATURAL
	var simulation_config := SimulationConfig.new()
	simulation_config.motion_backend = SimulationConfig.MotionBackend.GPU
	if has_meta("initial_scenario"):
		scenario = get_meta("initial_scenario") as ScenarioConfig
	if has_meta("initial_config"):
		simulation_config = get_meta("initial_config") as SimulationConfig
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--motion-backend=cpu":
			simulation_config.motion_backend = SimulationConfig.MotionBackend.CPU
		elif argument == "--gpu-bulk=0":
			simulation_config.gpu_bulk_upload = false
	var use_worker: bool = not has_meta("benchmark_view") and not has_meta("inline_simulation")
	if has_meta("worker_benchmark"):
		use_worker = bool(get_meta("worker_benchmark"))
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--simulation=inline":
			use_worker = false
		elif argument.begins_with("--worker-ai-budget-usec="):
			simulation_config.worker_ai_budget_usec = clampi(int(argument.trim_prefix("--worker-ai-budget-usec=")), 100, 100000)
	if use_worker:
		_access = SimulationAccess.threaded(simulation_config, scenario)
	else:
		_world = SimulationWorld.new()
		add_child(_world)
		_world.setup(simulation_config, scenario)
		_access = SimulationAccess.local(_world)
	_access.command_rejected.connect(hud.show_toast)
	_view = WorldPresentation.new(_access.probes)
	add_child(_view)
	_view.setup(_access.store, _access.intents, _access.resources, _access.config)
	_view.set_seed(_access.scenario.random_seed)
	_access.captured.connect(_on_capture)
	_insight = InsightOverlay.new()
	add_child(_insight)
	_insight.setup(_access, _view)
	_grab = GrabTool.new()
	add_child(_grab)
	_grab.setup(_access, _view)
	_camera = ObserverCamera.new()
	add_child(_camera)
	_camera.setup(_access.config.world_size, _view.display_foot)
	_camera.make_current()
	_runner = SimulationRunner.new()
	add_child(_runner)
	if use_worker:
		_runner.setup_threaded(_access, _view)
	else:
		_runner.setup(_world, _view)
	if not has_meta("benchmark_view"):
		_session_log = ObserverSessionLog.new()
		_session_log.start(_access, _runner)
	observer.setup(_access, _view, _runner, _camera, _insight, _grab, hud)

func _exit_tree() -> void:
	if _access != null and _access.executor != null:
		_access.close()
	if _session_log != null:
		_session_log.close()

func _on_capture(event: CaptureEvent) -> void:
	_view.add_capture(event.target, event.position, event.facing, event.tick)
