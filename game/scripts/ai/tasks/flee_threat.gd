extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	var origin: Vector2 = context.position()
	var direction: Vector2 = origin - context.last_threat_position
	if direction.length_squared() < 0.001:
		direction = Vector2.from_angle(float(context.handle.slot) * 2.399963)
	var destination: Vector2 = origin + direction.normalized() * ai.config.perception_radius
	var retreat: bool = context.species == SimTypes.Species.WOLF
	var behavior: int = SimTypes.Behavior.RETREAT if retreat else SimTypes.Behavior.FLEE
	var speed: float = ai.settings.wolf_speed if retreat else ai.settings.sheep_flee_speed
	var target: AgentHandle = context.threat.handle if context.threat != null else null
	write_intent(SimTypes.IntentMode.FLEE, behavior, destination, speed, "Observed threat; safety hysteresis", target)
	return RUNNING