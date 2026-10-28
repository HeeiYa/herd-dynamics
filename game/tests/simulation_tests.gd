extends SceneTree
## Durable regression fixtures for identity, stage isolation and real BT integration.
var _failures: int = 0
var _checks: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_identity()
	_test_grid()
	_test_intent_ownership()
	_test_resources()
	_test_motion()
	await _test_world()
	print("SIMULATION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_identity() -> void:
	var store := AgentStore.new()
	var removed: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(12, 15))
	var retained: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(55, 67))
	store.velocity_current[1] = Vector2(3, 4)
	store.position_next[1] = Vector2(58, 71)
	store.mark_dead(removed)
	_check(store.resolve(removed) == -1, "Logical death invalidates lookup before compaction")
	_check(store.remove_agent(removed), "Dead agent remains structurally removable")
	_check(store.resolve(retained) == 0, "Swap deletion repairs reverse map")
	_check(store.velocity_current[0] == Vector2(3, 4) and store.position_next[0] == Vector2(58, 71), "Swap deletion preserves motion columns")
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.DOG, Vector2(90, 90))
	_check(replacement.slot == removed.slot and replacement.generation != removed.generation, "Slot reuse advances generation")
	_check(store.resolve(removed) == -1, "Old handle cannot resolve replacement")
	store.publish_motion()
	_check(store.position_previous[0] == Vector2(55, 67) and store.position_current[0] == Vector2(58, 71), "Publication preserves interpolation interval")
	var capacity_before: int = store.capacity
	while store.count < capacity_before:
		store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	var recycled: AgentHandle = store.handle_at(0)
	store.remove_agent(recycled)
	store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	_check(store.capacity == capacity_before, "Reuse at capacity does not grow arrays")
	store.reset()
	var fresh: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	_check(fresh.world_epoch != replacement.world_epoch and store.resolve(replacement) == -1, "Reset invalidates previous world")

func _test_grid() -> void:
	var store := AgentStore.new()
	var random := RandomNumberGenerator.new()
	random.seed = 9182
	for index: int in range(120):
		store.create_agent(index % 3, Vector2(random.randf_range(0, 500), random.randf_range(0, 400)))
	store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	var grid := SpatialGrid.new(Vector2(500, 400), 37.0)
	grid.rebuild(store)
	var actual: Array[int] = []
	for trial: int in range(80):
		var center := Vector2(random.randf_range(-80, 580), random.randf_range(-80, 480))
		var radius: float = random.randf_range(0.0, 230.0)
		var species: int = (trial % 4) - 1
		grid.query(center, radius, species, store, actual)
		var expected: Array[int] = []
		for dense: int in range(store.count):
			if species >= 0 and store.species[dense] != species:
				continue
			if center.distance_squared_to(store.position_current[dense]) <= radius * radius:
				expected.append(dense)
		actual.sort()
		expected.sort()
		_check(actual == expected, "Grid matches exact snapshot scan at trial %d" % trial)
	grid.query(Vector2.ZERO, 0.0, SimTypes.Species.SHEEP, store, actual)
	_check(actual.size() == 1, "Zero-radius query at map origin")

func _test_intent_ownership() -> void:
	var handle := AgentHandle.new(2, 3, 4)
	var buffer := IntentBuffer.new()
	var old := MotionIntent.new()
	old.owner_token = 10
	old.expires_tick = 100
	buffer.write(handle, old)
	var current := MotionIntent.new()
	current.owner_token = 11
	current.expires_tick = 110
	buffer.write(handle, current)
	buffer.clear_owned(handle, 10)
	_check(buffer.get_intent(handle, 50) == current, "Interrupted old task cannot clear newer intent")
	_check(current.revision > old.revision, "Intent revision increases")
	_check(buffer.get_intent(handle, 110) == null, "Intent expires on the exact boundary")

func _test_resources() -> void:
	var config := SimulationConfig.new()
	var resources := ResourceGrid.new(config)
	resources.reset(12)
	var before: float = resources.get_effective_amount(0, 0)
	var future: float = resources.get_effective_amount(0, 100)
	_check(is_equal_approx(before, resources.get_effective_amount(0, 0)) and future >= before, "Future grass query is pure")
	var consumed: float = resources.consume(0, 20.0, 10)
	_check(consumed <= 1.0 and is_zero_approx(resources.get_effective_amount(0, 11)), "Grass consumption clamps to availability")
	_check(resources.get_effective_amount(0, 10) >= before, "Display retains pre-commit grass amount")
	_check(resources.get_effective_amount(0, 71) > 0.0, "Consumed grass recovers in simulation time")
	config.world_size = Vector2(165, 165)
	var edge := ResourceGrid.new(config)
	_check(edge.cell_center(edge.cell_count - 1) == Vector2(162.5, 162.5), "Partial edge cell centers stay inside the pasture")

func _test_motion() -> void:
	var config := SimulationConfig.new()
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	for index: int in range(3):
		var handle: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(1, 1))
		var intent := MotionIntent.new()
		intent.mode = SimTypes.IntentMode.MOVE
		intent.destination = Vector2(200, 200)
		intent.speed = 80.0
		intent.expires_tick = 10
		intents.write(handle, intent)
	var grid := SpatialGrid.new(config.world_size, config.cell_size)
	grid.rebuild(store)
	var motion := MotionSystem.new()
	motion.setup(store, grid, intents, config)
	motion.step(0, config.fixed_dt)
	for dense: int in range(store.count):
		_check(store.position_current[dense] == Vector2(1, 1) and store.velocity_current[dense] == Vector2.ZERO, "Motion preserves current snapshot")
		_check(store.position_next[dense].is_finite() and store.velocity_next[dense].is_finite(), "Coincident agents have finite motion")
		_check(store.position_next[dense].x >= 0 and store.position_next[dense].y >= 0, "Boundary clamps next position")

func _test_world() -> void:
	var config := SimulationConfig.new()
	# Remove wall-clock variability from this behavior fixture, not from production.
	config.ai_budget_usec = 100000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 20
	scenario.wolf_count = 4
	scenario.dog_count = 2
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	await process_frame
	var observed: Dictionary[int, int] = {}
	for step: int in range(1200):
		world.ai.begin_frame()
		world.step()
		for dense: int in range(world.store.count):
			var intent: MotionIntent = world.intents.get_intent(world.store.handle_at(dense), world.tick)
			if intent != null:
				observed[intent.behavior] = observed.get(intent.behavior, 0) + 1
	_check(world.tick == 1200, "One publication per fixed step")
	_check(observed.has(SimTypes.Behavior.GRAZE), "Real sheep BT reaches grazing")
	_check(observed.has(SimTypes.Behavior.FLEE), "Real sheep BT responds to wolves")
	_check(observed.has(SimTypes.Behavior.CHASE) or observed.has(SimTypes.Behavior.FLANK), "Real wolf BT selects a hunt")
	_check(observed.has(SimTypes.Behavior.INTERCEPT), "Real dog BT intercepts a local threat")
	print("BEHAVIOR_VISITS ", observed, " captures=", world.capture_count)
	var first_context: AgentContext = world.ai.contexts[world.store.handle_at(0).slot]
	var second_context: AgentContext = world.ai.contexts[world.store.handle_at(1).slot]
	_check(first_context.player.blackboard != second_context.player.blackboard, "Per-agent blackboards remain private")
	_check(first_context.player.get_bt_instance() != second_context.player.get_bt_instance(), "Shared tree resource creates independent runtime instances")
	var old: AgentHandle = world.store.handle_at(0)
	world.queue_remove(old)
	world.queue_spawn(SimTypes.Species.SHEEP, 1)
	world.ai.begin_frame()
	world.step()
	_check(not world.store.is_alive(old), "Runtime removal invalidates full handle")
	world.reset(scenario)
	_check(world.tick == 0 and world.store.count == 0 and not world.store.is_alive(old), "Reset clears population before queued stage-zero creation")
	world.ai.begin_frame()
	world.step()
	_check(world.store.count == 26, "Reset repopulates the same configured scenario")
	world.queue_spawn(SimTypes.Species.SHEEP, 140)
	for step: int in range(30):
		world.ai.begin_frame()
		world.step()
	for slot: int in world.ai.contexts:
		var context: AgentContext = world.ai.contexts[slot]
		_check(context.last_perception_tick >= 0 and context.last_decision_tick > 0, "Batched birth does not schedule into the past")
	world.queue_free()
	await process_frame
