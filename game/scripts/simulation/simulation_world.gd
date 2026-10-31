class_name SimulationWorld
extends Node
## Orchestrates stage ownership. Strategies live in the three behavior trees.
signal captured(event: CaptureEvent)
## Emitted at stage 0 after observer commands change the world. Presentation
## uses it to clear "pending" labels; it carries no simulation authority.
signal observer_commands_applied(tick: int)
signal observer_reset(epoch: int)
signal observer_event(record: Dictionary)

class DropCommand extends RefCounted:
	var handle: AgentHandle
	var position: Vector2

class PlaceCommand extends RefCounted:
	var species: int
	var position: Vector2

var probes: Probes
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
var _pending_holds: Array[AgentHandle] = []
var _pending_drops: Array[DropCommand] = []
var _pending_places: Array[PlaceCommand] = []
var _pending_tuning: Array[TuningCatalog.Change] = []
# Full identity keys accept equivalent handle objects and survive until removal.
var _grab_origins: Dictionary[String, Vector2] = {}
var _random := RandomNumberGenerator.new()
# Planned layouts own their placement stream; V1 layouts keep _random.
var spawn_planner: SpawnPlanner
var tuning: TuningCatalog

func _exit_tree() -> void:
	if motion != null:
		motion.close()

func setup(settings: SimulationConfig, initial: ScenarioConfig) -> void:
	config = settings
	probes = Probes.new(config.instrument_enabled)
	grid = SpatialGrid.new(config.world_size, config.cell_size)
	resources = ResourceGrid.new(config)
	ai = AICoordinator.new(probes)
	add_child(ai)
	ai.setup(store, grid, resources, intents, config)
	tuning = TuningCatalog.new(config, ai.settings)
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
	_pending_holds.clear()
	_pending_drops.clear()
	_pending_places.clear()
	_pending_tuning.clear()
	_grab_origins.clear()
	spawn_planner = SpawnPlanner.new(config, scenario) if ScenarioConfig.is_planned(scenario.layout) else null
	pending_spawns = PackedInt32Array([scenario.sheep_count, scenario.wolf_count, scenario.dog_count])
	phase_usec.fill(0)
	observer_reset.emit(store.epoch)
	record_observer_event("reset", {
		"counts": [scenario.sheep_count, scenario.wolf_count, scenario.dog_count],
		"parameters": tuning.snapshot(),
	})

func queue_spawn(species: int, amount: int) -> void:
	assert(species >= 0 and species <= SimTypes.Species.DOG)
	pending_spawns[species] += maxi(0, amount)

func queue_remove(handle: AgentHandle) -> void:
	if handle != null:
		_pending_removals.append(handle)

## Observer intervention: lift one life out of the pasture at the next stage 0.
func queue_hold(handle: AgentHandle) -> void:
	if handle != null:
		_pending_holds.append(handle)

## Observer intervention: put a held life down at the next stage 0. A drop
## queued in the same frame as its hold is applied after that hold.
func queue_drop(handle: AgentHandle, position: Vector2) -> void:
	if handle == null or not position.is_finite():
		return
	var command := DropCommand.new()
	command.handle = handle
	command.position = position
	_pending_drops.append(command)

## Cancels a hold that has not reached stage 0 yet. Returns false once applied.
func cancel_pending_hold(handle: AgentHandle) -> bool:
	for index: int in range(_pending_holds.size() - 1, -1, -1):
		if _pending_holds[index].same_life(handle):
			_pending_holds.remove_at(index)
			return true
	return false

## Withdraw this life's queued grab/drop. An applied hold returns at stage 0.
## Returns true only when a return command is pending; never moves a body here.
func cancel_grab(handle: AgentHandle, origin: Vector2) -> bool:
	if handle == null:
		return false
	for index: int in range(_pending_holds.size() - 1, -1, -1):
		if _pending_holds[index].same_life(handle):
			_pending_holds.remove_at(index)
	for index: int in range(_pending_drops.size() - 1, -1, -1):
		if _pending_drops[index].handle.same_life(handle):
			_pending_drops.remove_at(index)
	if store.is_held(handle):
		queue_drop(handle, _grab_origins.get(handle.key(), origin))
		return true
	return false

func queue_place(species: int, position: Vector2) -> void:
	assert(species >= 0 and species <= SimTypes.Species.DOG)
	if not position.is_finite():
		return
	var command := PlaceCommand.new()
	command.species = species
	command.position = position
	_pending_places.append(command)

## Parameter changes take effect at the next stage 0, never inside a step.
func queue_tuning(change: TuningCatalog.Change) -> bool:
	var snapshot: TuningCatalog.Change = tuning.validated_copy(change)
	if snapshot == null:
		return false
	_pending_tuning.append(snapshot)
	return true

func has_pending_observer_commands() -> bool:
	return not (_pending_holds.is_empty() and _pending_drops.is_empty() and _pending_places.is_empty() and _pending_tuning.is_empty())

func has_pending_tuning() -> bool:
	return not _pending_tuning.is_empty()

func is_hold_pending(handle: AgentHandle) -> bool:
	for pending: AgentHandle in _pending_holds:
		if pending.same_life(handle):
			return true
	return false

func create_at(species: int, position: Vector2) -> AgentHandle:
	# Stage 0 and isolated fixtures only. Runtime UI queues commands instead.
	var handle: AgentHandle = store.create_agent(species, position, config.agent_radius)
	ai.register_agent(handle, tick)
	return handle

func _spawn_position(species: int) -> Vector2:
	if spawn_planner != null:
		return spawn_planner.next_position(species)
	return _legacy_spawn_position(species)

## V1 placement for PASTURE / TWO_FLOCKS / CROWDED. Frozen so recorded
## benchmarks keep their initial conditions; new layouts use SpawnPlanner.
func _legacy_spawn_position(species: int) -> Vector2:
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
		if store.is_alive(handle):
			record_observer_event("remove", {"handle": handle.key()})
		_remove(handle)
	_pending_removals.clear()
	var observer_changed: bool = _apply_observer_commands()
	var allowance: int = config.spawn_per_tick
	for species: int in range(3):
		var amount: int = mini(allowance, pending_spawns[species])
		for index: int in range(amount):
			create_at(species, _spawn_position(species))
		pending_spawns[species] -= amount
		allowance -= amount
	if observer_changed:
		observer_commands_applied.emit(tick)

func _apply_observer_commands() -> bool:
	var changed: bool = has_pending_observer_commands()
	for change: TuningCatalog.Change in _pending_tuning:
		var entry: TuningCatalog.LogEntry = tuning.apply(change, tick, store.epoch)
		if entry != null:
			record_observer_event("parameter", {"key": TuningCatalog.Param.keys()[entry.key], "previous": entry.previous, "value": entry.value})
	if not _pending_tuning.is_empty():
		# Radii and policy distances feed cached facts; rebuild them once.
		ai.invalidate_facts()
	_pending_tuning.clear()
	for handle: AgentHandle in _pending_holds:
		_hold(handle)
	_pending_holds.clear()
	for command: DropCommand in _pending_drops:
		_drop(command.handle, command.position)
	_pending_drops.clear()
	for command: PlaceCommand in _pending_places:
		var body: float = config.agent_radius
		var position: Vector2 = command.position.clamp(Vector2.ONE * body, config.world_size - Vector2.ONE * body)
		var handle: AgentHandle = create_at(command.species, position)
		_record_placement("place", handle, position)
	_pending_places.clear()
	return changed

func _hold(handle: AgentHandle) -> void:
	# A dead, removed or recycled life simply has nothing to lift.
	if not store.is_active(handle):
		return
	var dense: int = store.resolve(handle)
	_grab_origins[handle.key()] = store.position_current[dense]
	store.set_held(handle, true)
	interaction.suspend(handle)
	ai.suspend_agent(handle)
	_record_placement("hold", handle, store.position_current[store.resolve(handle)])

func _drop(handle: AgentHandle, position: Vector2) -> void:
	if not store.is_held(handle):
		return
	var body: float = store.radius[store.resolve(handle)]
	store.relocate(handle, position.clamp(Vector2.ONE * body, config.world_size - Vector2.ONE * body))
	store.set_held(handle, false)
	_grab_origins.erase(handle.key())
	ai.resume_agent(handle, tick)
	_record_placement("drop", handle, store.position_current[store.resolve(handle)])

func _record_placement(action: String, handle: AgentHandle, position: Vector2) -> void:
	record_observer_event(action, {"handle": handle.key(), "position": [position.x, position.y]})

## Diagnostics boundary: serialization consumers receive values, not live state.
func record_observer_event(action: String, fields: Dictionary = {}) -> void:
	var record: Dictionary = fields.duplicate(true)
	record.merge({"event": action, "epoch": store.epoch, "tick": tick,
		"seed": scenario.random_seed, "layout": scenario.layout}, true)
	observer_event.emit(record)

func _remove(handle: AgentHandle) -> void:
	_grab_origins.erase(handle.key())
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
	if probes.enabled:
		ai.sample_pending(tick - 1)
		probes.end_step()

func counts() -> PackedInt32Array:
	var result := PackedInt32Array([0, 0, 0])
	for dense: int in range(store.count):
		if store.alive[dense] != 0:
			result[store.species[dense]] += 1
	return result

## Live bodies currently held out of the pasture by the observer, per species.
func held_counts() -> PackedInt32Array:
	var result := PackedInt32Array([0, 0, 0])
	if store.held_count == 0:
		return result
	for dense: int in range(store.count):
		if store.alive[dense] != 0 and store.held[dense] != 0:
			result[store.species[dense]] += 1
	return result
