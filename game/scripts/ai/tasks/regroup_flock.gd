extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.REGROUP, context.flock_center, context.coordinator.settings.sheep_speed, "Return to locally observed flock")
	return RUNNING