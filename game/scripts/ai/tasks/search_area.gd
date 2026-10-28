extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	var origin: Vector2 = context.position()
	if context.current_tick >= context.wander_until or origin.distance_to(context.wander_destination) < ai.settings.guard_arrival_distance:
		# Stable per-life phase avoids shared RNG state or a scripted outcome.
		var phase: float = float(context.handle.slot * 17 + context.handle.generation * 31 + context.current_tick / ai.settings.wander_ticks) * 2.399963
		var inward: Vector2 = ai.config.world_size * 0.5 - origin
		var direction: Vector2 = (Vector2.from_angle(phase) + inward.normalized() * 0.4).normalized()
		context.wander_destination = (origin + direction * ai.settings.wander_radius).clamp(Vector2.ONE * 20.0, ai.config.world_size - Vector2.ONE * 20.0)
		context.wander_until = context.current_tick + ai.settings.wander_ticks
	var speed: float = ai.settings.wolf_search_speed if context.species == SimTypes.Species.WOLF else ai.settings.sheep_speed
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.SEARCH, context.wander_destination, speed, "Search locally; no global target lookup")
	return RUNNING