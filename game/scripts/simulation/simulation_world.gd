class_name SimulationWorld
extends Node
## Orchestrates stage ownership. Strategies live in the three behavior trees.
signal captured(event: CaptureEvent)
var config: SimulationConfig
var scenario: ScenarioConfig
var store := AgentStore.new()
var intents := IntentBuffer.new()
var grid: SpatialGrid
var resources: ResourceGrid
var ai: AICoordinator
var motion: MotionSystem
var interaction: InteractionSystem
var tick: int = 0
var capture_count: int = 0
var phase_usec: PackedInt64Array = PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
var pending_spawns: PackedInt32Array = PackedInt32Array([0, 0, 0])
var _pending_removals: Array[AgentHandle] = []
var _random := RandomNumberGenerator.new()

func setup(settings: SimulationConfig, initial: ScenarioConfig) -> void:
	config = settings
	grid = SpatialGrid.new(config.world_size, config.cell_size)
	resources = ResourceGrid.new(config)
	ai = AICoordinator.new()
	add_child(ai)
	ai.setup(store, grid, resources, intents, config)
	motion = MotionSystem.new()
	motion.setup(store, grid, intents, config)
	interaction = InteractionSystem.new()
	interaction.setup(store, resources, intents, config)
	reset(initial)

func reset(initial: ScenarioConfig) -> void:
	# Called only at a render-frame safe boundary, never in the middle of a step.
	ai.reset()
	interaction.reset()
	intents.clear()
	store.reset()
	scenario = initial.duplicate() as ScenarioConfig
	_random.seed = scenario.random_seed
	resources.reset(scenario.random_seed)
	tick = 0
	capture_count = 0
	_pending_removals.clear()
	pending_spawns = PackedInt32Array([scenario.sheep_count, scenario.wolf_count, scenario.dog_count])
	phase_usec.fill(0)

func queue_spawn(species: int, amount: int) -> void:
	assert(species >= 0 and species <= SimTypes.Species.DOG)
	pending_spawns[species] += maxi(0, amount)

func queue_remove(handle: AgentHandle) -> void:
	if handle != null:
		_pending_removals.append(handle)

func create_at(species: int, position: Vector2) -> AgentHandle:
	# Stage 0 and isolated fixtures only. Runtime UI queues commands instead.
	var handle: AgentHandle = store.create_agent(species, position, config.agent_radius)
	ai.register_agent(handle, tick)
	return handle

func _spawn_position(species: int) -> Vector2:
	var center: Vector2 = config.world_size * Vector2(0.45, 0.5)
	if scenario.layout == ScenarioConfig.Layout.TWO_FLOCKS:
		center = config.world_size * (Vector2(0.3, 0.35) if _random.randf() < 0.5 else Vector2(0.7, 0.65))
	var angle: float = _random.randf_range(0.0, TAU)
	var distance: float = sqrt(_random.randf()) * 150.0
	if species == SimTypes.Species.WOLF:
		distance = _random.randf_range(225.0, 350.0)
	elif species == SimTypes.Species.DOG:
		distance = _random.randf_range(40.0, 140.0)
	if scenario.layout == ScenarioConfig.Layout.CROWDED:
		distance *= 0.35
	var position: Vector2 = center + Vector2.from_angle(angle) * distance
	return position.clamp(Vector2.ONE * 16.0, config.world_size - Vector2.ONE * 16.0)

func _apply_commands() -> void:
	for handle: AgentHandle in _pending_removals:
		_remove(handle)
	_pending_removals.clear()
	var allowance: int = config.spawn_per_tick
	for species: int in range(3):
		var amount: int = mini(allowance, pending_spawns[species])
		for index: int in range(amount):
			create_at(species, _spawn_position(species))
		pending_spawns[species] -= amount
		allowance -= amount

func _remove(handle: AgentHandle) -> void:
	# Coordinator invalidates ownership before the slot can be reused.
	ai.unregister_agent(handle)
	interaction.remove(handle)
	intents.remove(handle)
	store.remove_agent(handle)

func step() -> void:
	var started: int = Time.get_ticks_usec()
	_apply_commands()
	phase_usec[0] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	ai.begin_step(tick)
	phase_usec[1] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	grid.rebuild(store)
	phase_usec[2] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	ai.step(tick)
	phase_usec[3] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	motion.step(tick, config.fixed_dt)
	phase_usec[4] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	interaction.step(tick, config.fixed_dt)
	for event: CaptureEvent in interaction.captures:
		capture_count += 1
		ai.notify_capture(event.actor, event.position, event.tick + config.feed_ticks)
		captured.emit(event)
	phase_usec[5] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	for handle: AgentHandle in interaction.deaths:
		_remove(handle)
	store.publish_motion()
	tick += 1
	phase_usec[6] = Time.get_ticks_usec() - started

func counts() -> PackedInt32Array:
	var result := PackedInt32Array([0, 0, 0])
	for dense: int in range(store.count):
		if store.alive[dense] != 0:
			result[store.species[dense]] += 1
	return result
