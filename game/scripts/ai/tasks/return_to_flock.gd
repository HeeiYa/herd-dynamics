extends "res://scripts/ai/tasks/context_action.gd"

func _enter() -> void:
	super._enter()
	context.returning_to_flock = true
	context.pursuit_until = 0

func _tick(_delta: float) -> Status:
	var settings: AISettings = context.coordinator.settings
	if context.position().distance_to(context.protection_anchor) <= settings.guard_arrival_distance:
		context.returning_to_flock = false
		context.intercept_rest_until = context.current_tick + settings.dog_rest_ticks
		write_intent(SimTypes.IntentMode.STOP, SimTypes.Behavior.GUARD, context.position(), 0.0, "Returned to flock anchor; begin rest")
		return RUNNING
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.RETURN, context.protection_anchor, context.coordinator.settings.dog_speed, "Pursuit limit reached; return to local flock")
	return RUNNING
