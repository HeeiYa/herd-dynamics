extends "res://scripts/ai/tasks/context_action.gd"
## The tree's satiety guard ends rest; resting never consumes resources.

func _tick(_delta: float) -> Status:
	write_intent(SimTypes.IntentMode.STOP, SimTypes.Behavior.IDLE, context.position(), 0.0, "Satiated; rest until hunger or higher-priority duty")
	return RUNNING
