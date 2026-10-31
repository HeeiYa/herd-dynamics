class_name AgentStore
extends RefCounted
## Only lifecycle entry points change mappings. Dense indices never escape a phase.
var count: int = 0
var capacity: int = 0
var epoch: int = 1
# Monotonic within this store, including resets. Derived caches use it only to
# invalidate lifecycle-dependent summaries; full handles still define identity.
var life_revision: int = 0
var position_current: PackedVector2Array = PackedVector2Array()
var position_next: PackedVector2Array = PackedVector2Array()
var position_previous: PackedVector2Array = PackedVector2Array()
var velocity_current: PackedVector2Array = PackedVector2Array()
var velocity_next: PackedVector2Array = PackedVector2Array()
var facing: PackedVector2Array = PackedVector2Array()
var radius: PackedFloat32Array = PackedFloat32Array()
var species: PackedInt32Array = PackedInt32Array()
var alive: PackedByteArray = PackedByteArray()
var hunger: PackedFloat32Array = PackedFloat32Array()
# Nonzero while an observer intervention holds the body outside the pasture.
# SimulationWorld writes it only at the stage-0 safe point (see set_held).
var held: PackedByteArray = PackedByteArray()
var held_count: int = 0
var slot_to_dense: PackedInt32Array = PackedInt32Array()
var dense_to_slot: PackedInt32Array = PackedInt32Array()
var generations: PackedInt64Array = PackedInt64Array()
var _handles: Array[AgentHandle] = []
# Canonical handles are reused by all runtime references. This membership index
# answers liveness without resolving dense rows; lifecycle methods are its only writers.
var _live_handles: Dictionary[AgentHandle, bool] = {}
var _free_slots: Array[int] = []
var _next_slot: int = 0

func _grow_capacity(required: int) -> void:
	if required <= capacity:
		return
	var old_capacity: int = capacity
	capacity = maxi(128, maxi(required, capacity * 2))
	position_current.resize(capacity)
	position_next.resize(capacity)
	position_previous.resize(capacity)
	velocity_current.resize(capacity)
	velocity_next.resize(capacity)
	facing.resize(capacity)
	radius.resize(capacity)
	species.resize(capacity)
	alive.resize(capacity)
	hunger.resize(capacity)
	held.resize(capacity)
	slot_to_dense.resize(capacity)
	dense_to_slot.resize(capacity)
	generations.resize(capacity)
	_handles.resize(capacity)
	for slot: int in range(old_capacity, capacity):
		slot_to_dense[slot] = -1
		generations[slot] = 1

func create_agent(kind: int, position: Vector2, body_radius: float = 8.0) -> AgentHandle:
	var required_slots: int = _next_slot + 1 if _free_slots.is_empty() else _next_slot
	_grow_capacity(maxi(count + 1, required_slots))
	var slot: int
	if _free_slots.is_empty():
		slot = _next_slot
		_next_slot += 1
	else:
		slot = _free_slots.pop_back()
	var handle := AgentHandle.new(slot, generations[slot], epoch)
	var dense: int = count
	count += 1
	slot_to_dense[slot] = dense
	dense_to_slot[dense] = slot
	_handles[dense] = handle
	_live_handles[handle] = true
	position_current[dense] = position
	position_next[dense] = position
	position_previous[dense] = position
	velocity_current[dense] = Vector2.ZERO
	velocity_next[dense] = Vector2.ZERO
	facing[dense] = Vector2.RIGHT
	radius[dense] = body_radius
	species[dense] = kind
	alive[dense] = 1
	hunger[dense] = 0.65
	held[dense] = 0
	life_revision += 1
	return handle

func _find_life(handle: AgentHandle) -> int:
	if handle == null or handle.world_epoch != epoch or handle.slot < 0 or handle.slot >= _next_slot:
		return -1
	if generations[handle.slot] != handle.generation:
		return -1
	return slot_to_dense[handle.slot]

func resolve(handle: AgentHandle) -> int:
	var dense: int = _find_life(handle)
	if dense < 0 or alive[dense] == 0:
		return -1
	assert(dense_to_slot[dense] == handle.slot, "Identity mapping corrupted")
	return dense

func is_alive(handle: AgentHandle) -> bool:
	# Equal-value handles from callers still follow the full identity lookup below.
	# Never cache a dense index: swap deletion moves rows but not life identities.
	if _live_handles.has(handle):
		return true
	return resolve(handle) >= 0

## True for a live body that takes part in the pasture: not dead and not held.
## Spatial indexes, leases and attacks use this instead of bare liveness.
func is_active(handle: AgentHandle) -> bool:
	if not is_alive(handle):
		return false
	if held_count == 0:
		return true
	return held[resolve(handle)] == 0

func is_held(handle: AgentHandle) -> bool:
	var dense: int = resolve(handle)
	return dense >= 0 and held[dense] != 0

## Stage 0 only. Holding keeps identity, species and hunger; it removes the body
## from spatial indexes and interactions until the matching drop command.
func set_held(handle: AgentHandle, value: bool) -> bool:
	var dense: int = resolve(handle)
	if dense < 0:
		return false
	var flag: int = 1 if value else 0
	if held[dense] == flag:
		return true
	held[dense] = flag
	held_count += 1 if value else -1
	# Grid and fact caches treat holding like a lifecycle change.
	life_revision += 1
	return true

## Stage 0 only: a dropped body starts the next step at rest at the new place.
## All three position buffers agree so presentation cannot interpolate a jump.
func relocate(handle: AgentHandle, position: Vector2) -> bool:
	var dense: int = resolve(handle)
	if dense < 0:
		return false
	position_current[dense] = position
	position_next[dense] = position
	position_previous[dense] = position
	velocity_current[dense] = Vector2.ZERO
	velocity_next[dense] = Vector2.ZERO
	return true

func handle_at(dense: int) -> AgentHandle:
	assert(dense >= 0 and dense < count)
	return _handles[dense]

## Own every mutable column. Only immutable life handles may be shared with a
## reader on another thread. This projection is never returned to simulation.
func publication_copy() -> AgentStore:
	var copy := AgentStore.new()
	copy.count = count
	copy.capacity = capacity
	copy.epoch = epoch
	copy.life_revision = life_revision
	copy.held_count = held_count
	copy._next_slot = _next_slot
	copy.position_current = position_current.duplicate()
	copy.position_previous = position_previous.duplicate()
	copy.velocity_current = velocity_current.duplicate()
	copy.facing = facing.duplicate()
	copy.radius = radius.duplicate()
	copy.species = species.duplicate()
	copy.alive = alive.duplicate()
	copy.held = held.duplicate()
	copy.hunger = hunger.duplicate()
	copy.slot_to_dense = slot_to_dense.duplicate()
	copy.dense_to_slot = dense_to_slot.duplicate()
	copy.generations = generations.duplicate()
	copy._handles = _handles.duplicate()
	copy._live_handles = _live_handles.duplicate()
	return copy

func mark_dead(handle: AgentHandle) -> void:
	var dense: int = resolve(handle)
	if dense >= 0:
		_live_handles.erase(_handles[dense])
		alive[dense] = 0
		life_revision += 1

func remove_agent(handle: AgentHandle) -> bool:
	var dense: int = _find_life(handle)
	if dense < 0:
		return false
	_live_handles.erase(_handles[dense])
	if held[dense] != 0:
		held_count -= 1
	var last: int = count - 1
	if dense != last:
		_copy_row(last, dense)
		slot_to_dense[dense_to_slot[dense]] = dense
	_handles[last] = null
	alive[last] = 0
	count -= 1
	slot_to_dense[handle.slot] = -1
	generations[handle.slot] += 1
	_free_slots.append(handle.slot)
	life_revision += 1
	return true

func _copy_row(source: int, destination: int) -> void:
	position_current[destination] = position_current[source]
	position_next[destination] = position_next[source]
	position_previous[destination] = position_previous[source]
	velocity_current[destination] = velocity_current[source]
	velocity_next[destination] = velocity_next[source]
	facing[destination] = facing[source]
	radius[destination] = radius[source]
	species[destination] = species[source]
	alive[destination] = alive[source]
	hunger[destination] = hunger[source]
	held[destination] = held[source]
	dense_to_slot[destination] = dense_to_slot[source]
	_handles[destination] = _handles[source]

func publish_motion() -> void:
	var old_previous: PackedVector2Array = position_previous
	position_previous = position_current
	position_current = position_next
	position_next = old_previous
	var old_velocity: PackedVector2Array = velocity_current
	velocity_current = velocity_next
	velocity_next = old_velocity

func reset() -> void:
	epoch += 1
	life_revision += 1
	_live_handles.clear()
	count = 0
	_next_slot = 0
	_free_slots.clear()
	slot_to_dense.fill(-1)
	alive.fill(0)
	held.fill(0)
	held_count = 0
	_handles.fill(null)
