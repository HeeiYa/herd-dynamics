extends SceneTree
## Behavior outcomes use production trees, motion and next-step coordination.
## Static sheep/wolf stimuli have bodies but no registered behavior trees.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_coordination_results_and_promotion()
	await _test_unknown_and_lost_flock()
	await _test_protection_group()
	await _test_return_completion()
	await _test_running_task_metadata()
	await _test_full_hunt_fallback()
	await _test_exploration_coverage()
	print("DUTY_BEHAVIOR_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _world() -> SimulationWorld:
	var config := SimulationConfig.new()
	config.ai_budget_usec = 100000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	return world

func _step(world: SimulationWorld) -> void:
	world.ai.begin_frame()
	world.step()

func _move_body(world: SimulationWorld, handle: AgentHandle, destination: Vector2) -> void:
	var dense: int = world.store.resolve(handle)
	world.store.position_current[dense] = destination
	world.store.position_next[dense] = destination
	world.store.velocity_current[dense] = Vector2.ZERO
	world.store.velocity_next[dense] = Vector2.ZERO

func _decide(world: SimulationWorld, handles: Array[AgentHandle], tick: int) -> void:
	world.grid.rebuild(world.store)
	for handle: AgentHandle in handles:
		var context: AgentContext = world.ai.contexts[handle.slot]
		context.current_tick = tick
		world.ai.perception.update(context, tick)
		world.ai._request_urgent(context, tick)
	while world.ai._run_decision(tick):
		pass

func _test_coordination_results_and_promotion() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	var coordination := CoordinationSystem.new()
	coordination.setup(store, config, AISettings.new())
	var sheep: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(900, 500))
	var wolves: Array[AgentHandle] = []
	for index: int in range(4):
		var wolf: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(800, 480 + index * 15))
		wolves.append(wolf)
		coordination.request(wolf, sheep, CoordinationSystem.Kind.HUNT, index + 10, Vector2(800, 480 + index * 15), 0)
	_check(coordination.request_status(wolves[3], sheep, 13, 0) == CoordinationSystem.RequestStatus.PENDING, "A request remains pending in its creation step")
	coordination.begin_step(1)
	_check(coordination.request_status(wolves[0], sheep, 10, 1) == CoordinationSystem.RequestStatus.ACCEPTED, "Accepted hunt is reported to its exact owner")
	_check(coordination.request_status(wolves[3], sheep, 13, 1) == CoordinationSystem.RequestStatus.REJECTED, "Fourth hunter receives an explicit rejection")
	_check(coordination.request_status(wolves[3], sheep, 99, 1) == CoordinationSystem.RequestStatus.INVALID, "Another task token cannot read a previous request result")
	coordination.release(wolves[0], 10)
	_check(coordination.get_lease(wolves[1], 1).role == CoordinationSystem.Role.LEFT, "Role repair waits for the next step boundary")
	coordination.begin_step(2)
	_check(coordination.get_lease(wolves[1], 2).role == CoordinationSystem.Role.MAIN, "A surviving hunter fills the main role at the next boundary")
	_check(coordination.get_lease(wolves[2], 2).role == CoordinationSystem.Role.RIGHT, "Unaffected flank role stays stable during promotion")
	coordination.request(wolves[3], sheep, CoordinationSystem.Kind.HUNT, 14, Vector2(800, 525), 2)
	coordination.begin_step(3)
	_check(coordination.get_lease(wolves[3], 3).role == CoordinationSystem.Role.LEFT, "New member fills the remaining role without duplicating MAIN")
	coordination.remove(wolves[3])
	store.remove_agent(wolves[3])
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(800, 525))
	_check(coordination.request_status(replacement, sheep, 13, 3) == CoordinationSystem.RequestStatus.INVALID, "Slot reuse never inherits an old request result")

func _test_unknown_and_lost_flock() -> void:
	for previously_seen: bool in [false, true]:
		var world: SimulationWorld = _world()
		var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(500, 500))
		var sheep_position: Vector2 = Vector2(540, 500) if previously_seen else Vector2(1000, 500)
		var sheep: AgentHandle = world.store.create_agent(SimTypes.Species.SHEEP, sheep_position, world.config.agent_radius)
		await process_frame
		var context: AgentContext = world.ai.contexts[dog.slot]
		for step: int in range(60):
			_step(world)
		if previously_seen:
			_check(context.last_flock_seen_tick >= 0, "Positive flock observations establish a historical anchor")
			_move_body(world, sheep, Vector2(1000, 500))
		var start: Vector2 = context.position()
		var maximum_displacement: float = 0.0
		var searched: bool = false
		for step: int in range(600):
			_step(world)
			maximum_displacement = maxf(maximum_displacement, context.position().distance_to(start))
			searched = searched or context.task_name == &"search_area"
		_check(searched and maximum_displacement > 100.0, "A dog actually explores after an unknown or lost flock instead of guarding empty ground")
		world.queue_free()
		await process_frame

func _test_protection_group() -> void:
	var world: SimulationWorld = _world()
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(500, 500))
	for position: Vector2 in [Vector2(380, 495), Vector2(380, 505), Vector2(620, 485), Vector2(620, 491), Vector2(620, 497), Vector2(620, 503), Vector2(620, 509), Vector2(620, 515)]:
		world.store.create_agent(SimTypes.Species.SHEEP, position, world.config.agent_radius)
	await process_frame
	var context: AgentContext = world.ai.contexts[dog.slot]
	for step: int in range(180):
		_step(world)
	_check(context.protection_anchor.distance_to(Vector2(620, 500)) < 25.0, "Protection selects an observed dense local group instead of the empty inter-group mean")
	_check(context.position().distance_to(context.protection_anchor) < 55.0, "Dog physically reaches its selected protection group")
	world.queue_free()
	await process_frame

func _test_return_completion() -> void:
	var world: SimulationWorld = _world()
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(500, 500))
	world.store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500), world.config.agent_radius)
	await process_frame
	for step: int in range(60):
		_step(world)
	var context: AgentContext = world.ai.contexts[dog.slot]
	_move_body(world, dog, Vector2(800, 500))
	world.store.create_agent(SimTypes.Species.WOLF, Vector2(680, 500), world.config.agent_radius)
	# Isolate duty completion from when a naturally successful pursuit expires.
	context.pursuit_until = world.tick
	var started_return: bool = false
	var reached_anchor: bool = false
	var premature_intercepts: int = 0
	var late_return_ticks: int = 0
	var first_return_tick: int = -1
	for step: int in range(300):
		_step(world)
		var intent: MotionIntent = world.intents.get_intent(dog, world.tick - 1)
		if context.returning_to_flock and not started_return:
			started_return = true
			first_return_tick = world.tick
		if started_return and context.position().distance_to(context.protection_anchor) <= world.ai.settings.guard_arrival_distance:
			reached_anchor = true
		if started_return and not reached_anchor and intent != null:
			if intent.behavior == SimTypes.Behavior.INTERCEPT:
				premature_intercepts += 1
			if world.tick - first_return_tick > world.ai.settings.dog_rest_ticks and intent.behavior == SimTypes.Behavior.RETURN:
				late_return_ticks += 1
	_check(started_return and reached_anchor, "Duty return ends through actual arrival at the observed anchor")
	_check(late_return_ticks > 0 and premature_intercepts == 0, "A one-second rest timer cannot interrupt a still-incomplete return")
	world.queue_free()
	await process_frame

func _test_running_task_metadata() -> void:
	var world: SimulationWorld = _world()
	world.store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500), world.config.agent_radius)
	world.store.create_agent(SimTypes.Species.WOLF, Vector2(650, 500), world.config.agent_radius)
	var dogs: Array[AgentHandle] = [world.create_at(SimTypes.Species.DOG, Vector2(480, 500)), world.create_at(SimTypes.Species.DOG, Vector2(500, 500))]
	await process_frame
	var mismatches: int = 0
	var inspected: int = 0
	for step: int in range(1200):
		_step(world)
		for dog: AgentHandle in dogs:
			var intent: MotionIntent = world.intents.get_intent(dog, world.tick - 1)
			if intent == null:
				continue
			inspected += 1
			var context: AgentContext = world.ai.contexts[dog.slot]
			if context.task_token != intent.owner_token:
				mismatches += 1
	_check(inspected > 1000 and mismatches == 0, "Failed defense attempts never overwrite the running intent's activity token")
	world.queue_free()
	await process_frame

func _test_full_hunt_fallback() -> void:
	var world: SimulationWorld = _world()
	var sheep: AgentHandle = world.store.create_agent(SimTypes.Species.SHEEP, Vector2(900, 500), world.config.agent_radius)
	var wolves: Array[AgentHandle] = []
	for index: int in range(4):
		wolves.append(world.create_at(SimTypes.Species.WOLF, Vector2(848, 480 + index * 13)))
	await process_frame
	_decide(world, wolves, 0)
	world.ai.coordination.begin_step(1)
	_decide(world, wolves, 1)
	var rejected: AgentContext = world.ai.contexts[wolves[3].slot]
	var intent: MotionIntent = world.intents.get_intent(wolves[3], 1)
	_check(rejected.rejected_prey != null and rejected.rejected_prey.same_life(sheep), "A full local hunt records a bounded retry cooldown for that prey")
	_check(intent != null and intent.behavior == SimTypes.Behavior.SEARCH and intent.destination.distance_to(rejected.position()) > 100.0, "Rejected hunter publishes a useful exploration destination immediately")
	for tick: int in range(2, 20):
		world.ai.coordination.begin_step(tick)
		_decide(world, [wolves[3]], tick)
	_check(rejected.task_name == &"search_area" and world.ai.coordination.get_lease(wolves[3], 19) == null, "Rejected target is not selected again on the next decision")
	world.queue_free()
	await process_frame

func _test_exploration_coverage() -> void:
	var world: SimulationWorld = _world()
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(800, 500))
	await process_frame
	var context: AgentContext = world.ai.contexts[wolf.slot]
	var visited: Dictionary[int, bool] = {}
	var maximum_displacement: float = 0.0
	for step: int in range(3600):
		_step(world)
		if step % 12 == 0:
			visited[world.resources.cell_at(context.position())] = true
			maximum_displacement = maxf(maximum_displacement, context.position().distance_to(Vector2(800, 500)))
	_check(visited.size() > 25 and maximum_displacement > 400.0, "Unknown-area search expands actual coverage instead of circling the starting area")
	_check(context.exploration_history.size() <= world.ai.settings.exploration_history_size, "Exploration memory stays bounded")
	print("DUTY_SEARCH visited_cells=%d maximum_displacement_px=%.2f" % [visited.size(), maximum_displacement])
	world.queue_free()
	await process_frame
