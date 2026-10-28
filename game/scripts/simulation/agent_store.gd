class_name AgentStore
extends RefCounted
## Only lifecycle entry points change mappings. Dense indices never escape a phase.
var count: int = 0
var capacity: int = 0
var epoch: int = 1
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
var slot_to_dense: PackedInt32Array = PackedInt32Array()
var dense_to_slot: PackedInt32Array = PackedInt32Array()
var generations: PackedInt64Array = PackedInt64Array()
var _handles: Array[AgentHandle] = []
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
	return resolve(handle) >= 0

func handle_at(dense: int) -> AgentHandle:
	assert(dense >= 0 and dense < count)
	return _handles[dense]

func mark_dead(handle: AgentHandle) -> void:
	var dense: int = resolve(handle)
	if dense >= 0:
		alive[dense] = 0

func remove_agent(handle: AgentHandle) -> bool:
	var dense: int = _find_life(handle)
	if dense < 0:
		return false
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
	count = 0
	_next_slot = 0
	_free_slots.clear()
	slot_to_dense.fill(-1)
	alive.fill(0)
	_handles.fill(null)
