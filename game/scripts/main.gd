extends Node2D
## Creates branch-specific simulation services and wires the observer scene.

var _world: SimulationWorld
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
			if argument in ["--benchmark=cpu", "--benchmark=frames", "--benchmark=threat", "--benchmark=threat-cohort"]:
				get_tree().root.add_child.call_deferred(BenchmarkSession.new())
				queue_free()
				return
	RenderingServer.set_default_clear_color(UiStyle.BACKDROP)
	# Run after the runner so tools and overlays see this frame's publication.
	process_priority = 10
	call_deferred("_initialize")

func _initialize() -> void:
	_world = SimulationWorld.new()
	add_child(_world)
	var scenario := ScenarioConfig.new()
	scenario.layout = ScenarioConfig.Layout.NATURAL
	_world.setup(SimulationConfig.new(), scenario)
	_view = WorldPresentation.new(_world.probes)
	add_child(_view)
	_view.setup(_world.store, _world.intents, _world.resources, _world.config)
	_view.set_seed(_world.scenario.random_seed)
	_world.captured.connect(_on_capture)
	_insight = InsightOverlay.new()
	add_child(_insight)
	_insight.setup(_world, _view)
	_grab = GrabTool.new()
	add_child(_grab)
	_grab.setup(_world, _view)
	_camera = ObserverCamera.new()
	add_child(_camera)
	_camera.setup(_world.config.world_size, _view.display_foot)
	_camera.make_current()
	_runner = SimulationRunner.new()
	add_child(_runner)
	_runner.setup(_world, _view)
	if not has_meta("benchmark_view"):
		_session_log = ObserverSessionLog.new()
		_session_log.start(_world, _runner)
	observer.setup(_world, _view, _runner, _camera, _insight, _grab, hud)

func _exit_tree() -> void:
	if _session_log != null:
		_session_log.close()

func _on_capture(event: CaptureEvent) -> void:
	_view.add_capture(event.target, event.position, event.facing, event.tick)
