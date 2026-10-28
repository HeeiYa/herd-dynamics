extends "res://scripts/ai/tasks/context_action.gd"

func _enter() -> void:
	super._enter()
	context.intercept_rest_until = context.current_tick + context.coordinator.settings.dog_rest_ticks
	context.pursuit_until = 0

func _tick(_delta: float) -> Status:
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.RETURN, context.protection_anchor, context.coordinator.settings.dog_speed, "Pursuit limit reached; return to local flock")
	return RUNNING