class_name IntentBuffer
extends RefCounted
## Slot-aligned storage. Every lookup still validates the complete life and TTL.
var _intents: Array[MotionIntent] = []
var _publication_records: Array[MotionIntent] = []
var _changed_slots: Array[int] = []
var _changed_flags := PackedByteArray()
# Internal owner-thread mutation ledger. MotionIntent.revision may restart after
# removal, so derived caches must use this monotonic stamp and complete life.
var _mutation_serial: int = 0
var _mutation_versions := PackedInt64Array()

func _ensure_slot(slot: int) -> void:
	assert(slot >= 0)
	if slot < _intents.size():
		return
	var capacity: int = maxi(128, maxi(slot + 1, _intents.size() * 2))
	_intents.resize(capacity)
	_publication_records.resize(capacity)
	_changed_flags.resize(capacity)
	if _mutation_versions.size() < capacity:
		_mutation_versions.resize(capacity)

func _mark_changed(slot: int) -> void:
	if _changed_flags[slot] == 0:
		_changed_flags[slot] = 1
		_changed_slots.append(slot)
	_mutation_serial += 1
	_mutation_versions[slot] = _mutation_serial

## Read only during a fixed owner-thread phase. The caller must not write or
## retain this column after that phase, or expose it in a publication. Do not
## infer independent ownership from returning a Packed array. This ledger is
## independent of publication_copy's drain.
func mutation_versions_for_slots(slot_capacity: int) -> PackedInt64Array:
	if _mutation_versions.size() < slot_capacity:
		_mutation_versions.resize(slot_capacity)
	return _mutation_versions

## Copies own their index array; changed records are cloned once and then shared
## read-only. The authoritative MotionIntent is never borrowed by the UI.
func publication_copy() -> IntentBuffer:
	for slot: int in _changed_slots:
		var source: MotionIntent = _intents[slot]
		_publication_records[slot] = source.publication_copy() if source != null else null
		_changed_flags[slot] = 0
	_changed_slots.clear()
	var copy := IntentBuffer.new()
	copy._intents = _publication_records.duplicate()
	return copy

func write(handle: AgentHandle, intent: MotionIntent) -> void:
	var slot: int = handle.slot
	_ensure_slot(slot)
	intent.actor = handle
	var previous: MotionIntent = _intents[slot]
	if previous != null and previous.actor.same_life(handle):
		intent.revision = previous.revision + 1
	_intents[slot] = intent
	_mark_changed(slot)

func _record_for(handle: AgentHandle) -> MotionIntent:
	if handle == null:
		return null
	var slot: int = handle.slot
	if slot < 0 or slot >= _intents.size():
		return null
	var intent: MotionIntent = _intents[slot]
	if intent == null:
		return null
	if intent.actor != handle and not intent.actor.same_life(handle):
		return null
	return intent

func get_intent(handle: AgentHandle, tick: int) -> MotionIntent:
	# Keep this hot lookup direct; cold removal uses the TTL-independent helper.
	if handle == null:
		return null
	var slot: int = handle.slot
	if slot < 0 or slot >= _intents.size():
		return null
	var intent: MotionIntent = _intents[slot]
	if intent == null:
		return null
	# Store handles are immutable and canonical for the entire life. The same
	# object already carries the same slot/generation/epoch; reconstructed
	# external handles still take the complete identity comparison.
	if intent.actor != handle and not intent.actor.same_life(handle):
		return null
	if tick >= intent.expires_tick:
		return null
	return intent

func clear_owned(handle: AgentHandle, token: int) -> void:
	var intent: MotionIntent = _record_for(handle)
	if intent != null and intent.owner_token == token:
		remove(handle)

func remove(handle: AgentHandle) -> void:
	if _record_for(handle) != null:
		_intents[handle.slot] = null
		_mark_changed(handle.slot)

func clear() -> void:
	_mutation_serial += 1
	_mutation_versions.fill(_mutation_serial)
	_intents.clear()
	_publication_records.clear()
	_changed_slots.clear()
	_changed_flags.clear()
