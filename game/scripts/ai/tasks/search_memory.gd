extends "res://scripts/ai/tasks/context_action.gd"
## No hunt lease is held while searching stale or relayed evidence.
func _tick(_delta: float) -> Status:
	var sighting: LocalObservation = context.prey
	if sighting == null or context.observation_for(sighting.handle) == null:
		return FAILURE
	var ai: AICoordinator = context.coordinator
	var destination: Vector2 = sighting.predicted_position(context.current_tick, ai.config.fixed_dt, ai.settings)
	if context.position().distance_to(destination) < ai.settings.guard_arrival_distance:
		var phase: float = float(context.handle.slot + context.current_tick / ai.settings.calm_decision_ticks) * 2.399963
		destination += Vector2.from_angle(phase) * ai.settings.max_prediction_distance
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.SEARCH, destination, ai.settings.wolf_search_speed, "Lost sight: search last observation until its original expiry", sighting.handle)
	return RUNNING