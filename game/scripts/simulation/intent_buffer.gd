class_name IntentBuffer
extends RefCounted
var _intents: Dictionary[int, MotionIntent] = {}

func write(handle: AgentHandle, intent: MotionIntent) -> void:
	intent.actor = handle
	var previous: MotionIntent = _intents.get(handle.slot)
	if previous != null and previous.actor.same_life(handle):
		intent.revision = previous.revision + 1
	_intents[handle.slot] = intent

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

func remove(handle: AgentHandle) -> void:
	var intent: MotionIntent = _intents.get(handle.slot)
	if intent != null and intent.actor.same_life(handle):
		_intents.erase(handle.slot)

func clear() -> void:
	_intents.clear()
