class_name IntentBuffer
extends RefCounted
var _intents: Dictionary[int, MotionIntent] = {}
var _publication_records: Dictionary[int, MotionIntent] = {}
var _changed_slots: Dictionary[int, bool] = {}

## A record returned by get_intent is read-only. BT updates publish a new
## record via write. Copy changed records once, then share those immutable
## copies between publications. Each publication owns its dictionary, and no
## publication ever borrows an authoritative MotionIntent.
func publication_copy() -> IntentBuffer:
	for slot: int in _changed_slots:
		var source: MotionIntent = _intents.get(slot)
		if source == null:
			_publication_records.erase(slot)
		else:
			_publication_records[slot] = source.publication_copy()
	_changed_slots.clear()
	var copy := IntentBuffer.new()
	copy._intents = _publication_records.duplicate()
	return copy

func write(handle: AgentHandle, intent: MotionIntent) -> void:
	intent.actor = handle
	var previous: MotionIntent = _intents.get(handle.slot)
	if previous != null and previous.actor.same_life(handle):
		intent.revision = previous.revision + 1
	_intents[handle.slot] = intent
	_changed_slots[handle.slot] = true

func get_intent(handle: AgentHandle, tick: int) -> MotionIntent:
	if handle == null:
		return null
	var intent: MotionIntent = _intents.get(handle.slot)
	if intent == null or not intent.actor.same_life(handle) or tick >= intent.expires_tick:
		return null
	return intent

func clear_owned(handle: AgentHandle, token: int) -> void:
	var intent: MotionIntent = _intents.get(handle.slot)
	if intent != null and intent.actor.same_life(handle) and intent.owner_token == token:
		_intents.erase(handle.slot)
		_changed_slots[handle.slot] = true

func remove(handle: AgentHandle) -> void:
	var intent: MotionIntent = _intents.get(handle.slot)
	if intent != null and intent.actor.same_life(handle):
		_intents.erase(handle.slot)
		_changed_slots[handle.slot] = true

func clear() -> void:
	_intents.clear()
	_publication_records.clear()
	_changed_slots.clear()
