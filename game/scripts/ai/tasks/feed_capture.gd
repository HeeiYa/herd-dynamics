extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	write_intent(SimTypes.IntentMode.STOP, SimTypes.Behavior.FEED, context.feeding_position, 0.0, "Capture permit; independent of the dead prey handle")
	return RUNNING