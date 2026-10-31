extends SceneTree
## Scan completion is a dependency, including when urgent/shared work arrives.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _step(world: SimulationWorld) -> void:
	world.ai.begin_frame()
	world.step()

func _run() -> void:
	var config := SimulationConfig.new()
	config.ai_budget_usec = 100000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	var subject: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(300, 300))
	world.create_at(SimTypes.Species.SHEEP, Vector2(320, 300))
	var background: Array[AgentHandle] = []
	for index: int in 20:
		background.append(world.create_at(SimTypes.Species.SHEEP, Vector2(700 + index * 30, 200)))
	for tick: int in 40:
		_step(world)
	world.queue_hold(subject)
	world._apply_commands()
	var context: AgentContext = world.ai.inspect(subject)
	var old_scan: int = context.last_perception_tick
	config.perception_jobs = 1
	for handle: AgentHandle in background:
		world.ai._schedule_perception(world.ai.inspect(handle), world.tick)
	world.queue_drop(subject, Vector2(1300, 800))
	var drop_tick: int = world.tick
	for tick: int in 3:
		_step(world)
		world.ai._request_urgent(context, world.tick)
		_check(context.last_perception_tick == old_scan and context.awaiting_resume_perception, "Restored dog really remains behind the scan backlog")
		_check(not context.decision_queued and world.intents.get_intent(subject, world.tick) == null, "Urgent work cannot bypass the first post-drop scan")
		_check(world.store.position_current[world.store.resolve(subject)] == Vector2(1300, 800), "No old intent moves the restored body while it waits")
	for tick: int in 80:
		if context.last_decision_tick >= drop_tick:
			break
		_step(world)
	_check(context.last_perception_tick >= drop_tick and context.last_decision_tick >= context.last_perception_tick, "Decision resumes only after scan completion")
	_check(not context.awaiting_resume_perception, "Completion releases the gate without clearing the whole context")
	world.queue_free()
	await process_frame
	print("RESUME_DEPENDENCY_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
