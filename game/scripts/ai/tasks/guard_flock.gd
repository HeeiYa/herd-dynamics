extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	var destination: Vector2 = context.protection_anchor
	var far_from_anchor: bool = context.position().distance_to(destination) > ai.settings.guard_arrival_distance
	var mode: int = SimTypes.IntentMode.MOVE if far_from_anchor else SimTypes.IntentMode.STOP
	var behavior: int = SimTypes.Behavior.RETURN if far_from_anchor else SimTypes.Behavior.GUARD
	write_intent(mode, behavior, destination, ai.settings.guard_speed, "Guard the last observed local flock anchor")
	return RUNNING