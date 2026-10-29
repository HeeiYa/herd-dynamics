extends SceneTree
## Controlled behavioral fixtures run the production BT, motion and interaction.
## Stationary unregistered stimuli isolate policy defects from pursuit and budget.
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
	_test_resource_geometry()
	_test_consumption_geometry()
	await _test_boundary_escape()
	await _test_opposing_threats()
	await _test_crowded_grazing()
	await _test_food_commitment()
	await _test_satiety_cycle()
	await _test_regroup_hysteresis()
	await _test_hard_regroup_and_threat_priority()
	await _test_stalled_food_approach()
	print("SHEEP_BEHAVIOR_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _new_world() -> SimulationWorld:
	var config := SimulationConfig.new()
	config.ai_budget_usec = 100000
	config.grass_recovery_rate = 0.0
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	_fill_grass(world.resources, 1.0)
	return world

func _fill_grass(resources: ResourceGrid, amount: float) -> void:
	# Explicit fixture preparation before any step, never a runtime mutation path.
	resources._amount.fill(amount)
	resources._previous_amount.fill(amount)

func _step(world: SimulationWorld) -> void:
	world.ai.begin_frame()
	world.step()

func _test_resource_geometry() -> void:
	var config := SimulationConfig.new()
	config.world_size = Vector2(170, 130)
	config.grass_recovery_rate = 0.0
	var resources := ResourceGrid.new(config)
	_check(resources.can_graze_at(0, Vector2(14, 14)), "Grass consumption includes reachable corners outside the old center circle")
	_check(not resources.can_graze_at(0, Vector2(80, 40)) and resources.can_graze_at(1, Vector2(80, 40)), "A cell boundary belongs to exactly one consumption region")
	_check(not resources.can_graze_at(0, Vector2(-1, 40)), "An out-of-world position cannot consume a clamped cell")
	var destinations: Array[Vector2] = []
	var all_reachable: bool = true
	for slot: int in range(32):
		var point: Vector2 = resources.grazing_point(4, AgentHandle.new(slot, 1, 1), config.agent_radius)
		all_reachable = all_reachable and resources.can_graze_at(4, point)
		all_reachable = all_reachable and point.y <= config.world_size.y - config.agent_radius
		if not destinations.has(point):
			destinations.append(point)
	_check(all_reachable and destinations.size() == 32, "Grazing destinations are dispersed and clipped to a partial edge cell's reachable area")
	_fill_grass(resources, 0.0)
	resources._amount[2] = 1.0
	resources._previous_amount[2] = 1.0
	_check(resources.best_cell(Vector2(140, 40), 180.0, 0) == -1, "A thin edge strip outside all legal body centers is not selected as reachable food")

func _test_consumption_geometry() -> void:
	var config := SimulationConfig.new()
	config.hunger_rate = 0.0
	config.grass_recovery_rate = 0.0
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	var resources := ResourceGrid.new(config)
	_fill_grass(resources, 1.0)
	var interaction := InteractionSystem.new()
	interaction.setup(store, resources, intents, config)
	var inside: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(14, 14))
	var adjacent: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(81, 40))
	for handle: AgentHandle in [inside, adjacent]:
		var intent := MotionIntent.new()
		intent.mode = SimTypes.IntentMode.GRAZE
		intent.resource_cell = 0
		intent.expires_tick = 10
		intents.write(handle, intent)
	var hunger_before: float = store.hunger[store.resolve(inside)]
	interaction.step(0, config.fixed_dt)
	var intake: float = hunger_before - store.hunger[store.resolve(inside)]
	_check(intake > 0.0, "A sheep consumes from its selected cell away from the old center circle")
	_check(is_equal_approx(store.hunger[store.resolve(adjacent)], hunger_before), "A sheep cannot consume its selected cell while physically in the next cell")
	_check(is_equal_approx(intake, interaction.grass_consumed), "Whole-cell geometry preserves hunger-to-resource conservation")
	_check(is_equal_approx(resources.get_effective_amount(0, 0), 1.0), "Consumption preserves the pre-step resource snapshot")

func _test_boundary_escape() -> void:
	var origins: Array[Vector2] = [Vector2(13, 500), Vector2(1587, 500), Vector2(800, 13), Vector2(800, 987), Vector2(13, 13), Vector2(1587, 13), Vector2(13, 987), Vector2(1587, 987)]
	var threats: Array[Vector2] = [Vector2(113, 500), Vector2(1487, 500), Vector2(800, 113), Vector2(800, 887), Vector2(83, 83), Vector2(1517, 83), Vector2(83, 917), Vector2(1517, 917)]
	for fixture: int in range(origins.size() + 1):
		var world: SimulationWorld = _new_world()
		var is_wolf: bool = fixture == origins.size()
		var fixture_index: int = 0 if is_wolf else fixture
		var species: int = SimTypes.Species.WOLF if is_wolf else SimTypes.Species.SHEEP
		var threat_species: int = SimTypes.Species.DOG if is_wolf else SimTypes.Species.WOLF
		var origin: Vector2 = origins[fixture_index]
		var actor: AgentHandle = world.create_at(species, origin)
		world.store.create_agent(threat_species, threats[fixture_index], world.config.agent_radius)
		await process_frame
		var maximum_displacement: float = 0.0
		var stationary_escape_ticks: int = 0
		var previous: Vector2 = origin
		for tick: int in range(300):
			_step(world)
			var position: Vector2 = world.store.position_current[world.store.resolve(actor)]
			maximum_displacement = maxf(maximum_displacement, origin.distance_to(position))
			var intent: MotionIntent = world.intents.get_intent(actor, world.tick - 1)
			if intent != null and intent.mode == SimTypes.IntentMode.FLEE and position.distance_to(previous) < 0.001:
				stationary_escape_ticks += 1
			previous = position
		_check(maximum_displacement > 100.0, "Boundary escape %d makes real progress instead of targeting outside the world" % fixture)
		if maximum_displacement <= 100.0:
			print("ESCAPE_DIAGNOSTIC fixture=%d displacement=%f position=%s task=%s" % [fixture, maximum_displacement, str(previous), world.ai.contexts[actor.slot].task_name])
		_check(stationary_escape_ticks < 45, "Boundary escape %d does not sustain a motionless flee intent" % fixture)
		_check(world.ai.budget_exhaustions == 0, "Boundary fixture is free of AI budget exhaustion")
		world.queue_free()
		await process_frame

func _test_opposing_threats() -> void:
	var world: SimulationWorld = _new_world()
	var origin := Vector2(800, 500)
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, origin)
	world.store.create_agent(SimTypes.Species.WOLF, Vector2(740, 500), world.config.agent_radius)
	world.store.create_agent(SimTypes.Species.WOLF, Vector2(860, 500), world.config.agent_radius)
	await process_frame
	var maximum_vertical_progress: float = 0.0
	for tick: int in range(300):
		_step(world)
		var position: Vector2 = world.store.position_current[world.store.resolve(sheep)]
		maximum_vertical_progress = maxf(maximum_vertical_progress, absf(position.y - origin.y))
	_check(maximum_vertical_progress > 150.0, "Two opposing threats produce a lateral exit instead of repeated nearest-threat reversals")
	world.queue_free()
	await process_frame

func _test_crowded_grazing() -> void:
	var world: SimulationWorld = _new_world()
	var center := Vector2(760, 520)
	var sheep: Array[AgentHandle] = []
	for index: int in range(32):
		sheep.append(world.create_at(SimTypes.Species.SHEEP, center + Vector2.from_angle(TAU * index / 32.0) * 32.0))
	await process_frame
	var ate: Dictionary[int, bool] = {}
	var total_consumed: float = 0.0
	for tick: int in range(120):
		var hunger_before: PackedFloat32Array = world.store.hunger.duplicate()
		_step(world)
		total_consumed += world.interaction.grass_consumed
		for handle: AgentHandle in sheep:
			var dense: int = world.store.resolve(handle)
			var without_food: float = hunger_before[dense] + world.config.hunger_rate * world.config.fixed_dt
			if world.store.hunger[dense] < without_food - 0.000001:
				ate[handle.slot] = true
	_check(ate.size() == sheep.size(), "All 32 sheep around a grass-cell rim receive actual food")
	if ate.size() != sheep.size():
		for handle: AgentHandle in sheep:
			if ate.has(handle.slot):
				continue
			var context: AgentContext = world.ai.contexts[handle.slot]
			var intent: MotionIntent = world.intents.get_intent(handle, world.tick - 1)
			print("GRAZING_DIAGNOSTIC slot=%d position=%s task=%s destination=%s cell=%d" % [handle.slot, str(context.position()), context.task_name, str(intent.destination) if intent != null else "none", intent.resource_cell if intent != null else -1])
	_check(total_consumed > 0.4, "Crowded grazing transfers measurable resources instead of only publishing graze tasks")
	world.queue_free()
	await process_frame

func _test_food_commitment() -> void:
	var world: SimulationWorld = _new_world()
	_fill_grass(world.resources, 0.0)
	var origin := Vector2(760, 520)
	var patch := Vector2(920, 520)
	var patch_cell: int = world.resources.cell_at(patch)
	world.resources._amount[patch_cell] = 1.0
	world.resources._previous_amount[patch_cell] = 1.0
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, origin)
	for index: int in range(8):
		world.store.create_agent(SimTypes.Species.SHEEP, origin + Vector2.from_angle(TAU * index / 8.0) * 10.0, world.config.agent_radius)
	await process_frame
	var first_intake_tick: int = -1
	var regroup_before_food: int = 0
	var total_consumed: float = 0.0
	for tick: int in range(600):
		_step(world)
		total_consumed += world.interaction.grass_consumed
		if first_intake_tick < 0:
			if world.interaction.grass_consumed > 0.0:
				first_intake_tick = world.tick
			elif world.ai.contexts[sheep.slot].task_name == &"regroup_flock":
				regroup_before_food += 1
	_check(first_intake_tick > 0 and first_intake_tick < 600, "Hungry sheep reaches the in-range patch 160 pixels from its local flock")
	_check(regroup_before_food == 0 and total_consumed > 0.1, "Ordinary regroup does not repeatedly interrupt a viable food commitment")
	world.queue_free()
	await process_frame

func _test_satiety_cycle() -> void:
	var world: SimulationWorld = _new_world()
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(760, 520))
	await process_frame
	var rest_tick: int = -1
	var ate_after_rest: bool = false
	var rest_consumption: float = 0.0
	for tick: int in range(1800):
		_step(world)
		var context: AgentContext = world.ai.contexts[sheep.slot]
		if context.task_name == &"rest_satiated":
			if rest_tick < 0:
				rest_tick = world.tick
			rest_consumption += world.interaction.grass_consumed
		elif rest_tick >= 0 and world.interaction.grass_consumed > 0.0:
			ate_after_rest = true
	_check(rest_tick > 0 and rest_tick < 600, "Satiation ends feeding and enters an explicit rest branch")
	_check(is_zero_approx(rest_consumption), "Resting sheep do not keep consuming grass")
	_check(ate_after_rest, "Hunger eventually resumes feeding after a meaningful rest interval")
	world.queue_free()
	await process_frame

func _test_regroup_hysteresis() -> void:
	var world: SimulationWorld = _new_world()
	world.config.hunger_rate = 0.0
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(600, 500))
	world.store.hunger[world.store.resolve(sheep)] = 0.0
	for index: int in range(8):
		world.store.create_agent(SimTypes.Species.SHEEP, Vector2(760, 500) + Vector2.from_angle(TAU * index / 8.0) * 5.0, world.config.agent_radius)
	await process_frame
	var remained_inside_band: bool = false
	var completed: bool = false
	for tick: int in range(300):
		_step(world)
		var context: AgentContext = world.ai.contexts[sheep.slot]
		var distance: float = context.position().distance_to(context.flock_center)
		if distance < world.ai.settings.regroup_distance - 5.0 and distance > world.ai.settings.regroup_exit_distance + 5.0:
			remained_inside_band = remained_inside_band or context.task_name == &"regroup_flock"
		if context.task_name == &"rest_satiated" and distance <= world.ai.settings.regroup_exit_distance + 2.0:
			completed = true
	_check(remained_inside_band, "Regroup remains active between its entry and exit thresholds")
	_check(completed, "Regroup completes at its close threshold and releases the sheep to rest")
	world.queue_free()
	await process_frame

func _test_stalled_food_approach() -> void:
	var world: SimulationWorld = _new_world()
	_fill_grass(world.resources, 0.0)
	var origin := Vector2(760, 520)
	var cell: int = world.resources.cell_at(Vector2(920, 520))
	world.resources._amount[cell] = 1.0
	world.resources._previous_amount[cell] = 1.0
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, origin)
	await process_frame
	var yielded_to_search: bool = false
	for tick: int in range(world.ai.settings.graze_no_progress_ticks + 60):
		# Pin physical input to model a blocked corridor without adding a second
		# movement implementation. The task still receives normal scheduled ticks.
		var dense: int = world.store.resolve(sheep)
		world.store.position_current[dense] = origin
		world.store.velocity_current[dense] = Vector2.ZERO
		_step(world)
		var context: AgentContext = world.ai.contexts[sheep.slot]
		if context.current_tick < context.grazing_retry_after_tick and context.task_name == &"search_area":
			yielded_to_search = true
	_check(yielded_to_search, "A food approach with no progress yields to exploration for a bounded retry delay")
	world.queue_free()
	await process_frame

func _test_hard_regroup_and_threat_priority() -> void:
	var world: SimulationWorld = _new_world()
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(600, 500))
	for index: int in range(8):
		world.store.create_agent(SimTypes.Species.SHEEP, Vector2(760, 500) + Vector2.from_angle(TAU * index / 8.0) * 5.0, world.config.agent_radius)
	await process_frame
	_step(world)
	var context: AgentContext = world.ai.contexts[sheep.slot]
	_check(context.grazing_committed, "Priority fixture begins with a real hungry feeding commitment")
	# Moving the observer leaves a valid historical flock sample. Only dispatch
	# a decision, so this does not invent a new distant flock observation.
	world.store.position_current[world.store.resolve(sheep)] = Vector2(350, 500)
	world.ai._request_urgent(context, 1)
	_check(world.ai._run_decision(1), "Priority fixture dispatches a decision without another perception scan")
	var intent: MotionIntent = world.intents.get_intent(sheep, 1)
	_check(intent != null and intent.behavior == SimTypes.Behavior.REGROUP, "Hard flock distance overrides a hungry feeding commitment")
	var wolf: AgentHandle = world.store.create_agent(SimTypes.Species.WOLF, Vector2(400, 500))
	var report := LocalObservation.new()
	report.handle = wolf
	report.species = SimTypes.Species.WOLF
	report.position = Vector2(400, 500)
	report.observed_tick = 2
	report.expires_tick = 2 + world.config.memory_ticks
	report.source = LocalObservation.Source.SHARED
	world.ai.perception.merge_shared(context, report, 2)
	world.ai.perception.refresh_shared_facts(context, 2)
	world.ai._request_urgent(context, 2)
	_check(world.ai._run_decision(2), "Priority fixture dispatches the local danger decision")
	intent = world.intents.get_intent(sheep, 2)
	_check(intent != null and intent.behavior == SimTypes.Behavior.FLEE, "Known danger preempts both hard regroup and hungry feeding")
	world.queue_free()
	await process_frame
