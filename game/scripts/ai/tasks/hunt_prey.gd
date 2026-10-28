extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	var sighting: LocalObservation = context.prey
	if sighting == null or context.observation_for(sighting.handle) == null:
		return FAILURE
	var ai: AICoordinator = context.coordinator
	var origin: Vector2 = context.position()
	ai.coordination.request(context.handle, sighting.handle, CoordinationSystem.Kind.HUNT, token, origin, context.current_tick)
	var lease: CoordinationSystem.Lease = ai.coordination.get_lease(context.handle, context.current_tick)
	var destination: Vector2 = sighting.predicted_position(context.current_tick, ai.config.fixed_dt, ai.settings)
	var behavior: int = SimTypes.Behavior.STALK
	var speed: float = ai.settings.wolf_search_speed
	if lease != null and lease.owner_token == token and lease.target.same_life(sighting.handle):
		# Accepting a lease is explicit; a grant itself never changes the intent.
		context.lease_token = token
		behavior = SimTypes.Behavior.CHASE
		speed = ai.settings.wolf_speed
		if lease.role != CoordinationSystem.Role.MAIN and origin.distance_to(destination) > ai.config.attack_range * 2.0:
			var forward: Vector2 = sighting.velocity.normalized()
			if forward.length_squared() < 0.001:
				forward = (destination - origin).normalized()
			var side: float = -1.0 if lease.role == CoordinationSystem.Role.LEFT else 1.0
			destination += forward.orthogonal() * ai.settings.flank_distance * side
			behavior = SimTypes.Behavior.FLANK
	elif origin.distance_to(destination) < ai.settings.flank_distance:
		destination = origin
	write_intent(SimTypes.IntentMode.MOVE, behavior, destination, speed, "Observed prey; lease chooses main or flank", sighting.handle)
	return RUNNING