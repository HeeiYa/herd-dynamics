extends "res://scripts/ai/tasks/context_action.gd"
## Visit a historical anchor once, then let the explicit exploration branch run.
func _tick(_delta: float) -> Status:
	var settings: AISettings = context.coordinator.settings
	if context.position().distance_to(context.protection_anchor) <= settings.guard_arrival_distance:
		context.last_flock_searched_tick = context.last_flock_seen_tick
		return FAILURE
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.SEARCH, context.protection_anchor, settings.dog_speed, "Lost flock: visit its last observed location")
	return RUNNING
