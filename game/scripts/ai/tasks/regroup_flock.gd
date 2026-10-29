extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	if context.flock_count <= 1:
		context.regrouping = false
		return FAILURE
	if context.position().distance_to(context.flock_center) <= context.coordinator.settings.regroup_exit_distance:
		context.regrouping = false
		return SUCCESS
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.REGROUP, context.flock_center, context.coordinator.settings.sheep_speed, "Return to locally observed flock")
	return RUNNING
