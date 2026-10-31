extends SceneTree
## Validate the locked LimboAI build outside SceneTree with checks still enabled.
var _thread := Thread.new()
var _frames: int = 0
var _result: Dictionary = {}

func _initialize() -> void:
	var start_error: Error = _thread.start(_simulate)
	if start_error != OK:
		push_error("Worker contract test could not start: " + error_string(start_error))
		quit(1)

func _process(_delta: float) -> bool:
	_frames += 1
	if _thread.is_alive():
		return false
	_result = _thread.wait_to_finish()
	_result["ui_frames"] = _frames
	print("WORKER_CONTRACT_TESTS " + JSON.stringify(_result))
	quit(0 if _result["decisions"] > 0 and _frames > 2 else 1)
	return true

func _simulate() -> Dictionary:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.detached_ai = true
	config.ai_budget_usec = 100000
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--motion-backend=gpu":
			config.motion_backend = SimulationConfig.MotionBackend.GPU
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 80
	scenario.wolf_count = 4
	scenario.dog_count = 3
	world.setup(config, scenario)
	OS.delay_msec(100)
	var decisions: int = 0
	for tick: int in 120:
		world.ai.begin_frame()
		world.step()
		decisions += world.ai.last_decision_jobs
	assert(not world.is_inside_tree() and not world.ai.is_inside_tree())
	for context: AgentContext in world.ai.contexts.values():
		assert(context.detached_tree != null and context.player == null)
	var result: Dictionary = {"tick": world.tick, "decisions": decisions, "population": world.store.count, "motion_backend": world.motion.backend_status}
	world.motion.close()
	world.ai.reset()
	world.free()
	return result
