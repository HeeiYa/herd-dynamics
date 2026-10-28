extends "res://scripts/ai/tasks/context_action.gd"

func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	var threat: LocalObservation = _choose_unreserved_threat()
	if threat == null:
		return FAILURE
	ai.coordination.request(context.handle, threat.handle, CoordinationSystem.Kind.DEFEND, token, context.position(), context.current_tick)
	var lease: CoordinationSystem.Lease = ai.coordination.get_lease(context.handle, context.current_tick)
	if lease == null or lease.owner_token != token or not lease.target.same_life(threat.handle):
		write_intent(SimTypes.IntentMode.STOP, SimTypes.Behavior.GUARD, context.position(), 0.0, "Await next-step defense assignment")
		return RUNNING
	context.lease_token = token
	if context.pursuit_until == 0:
		context.pursuit_until = context.current_tick + ai.settings.dog_intercept_ticks
	var destination: Vector2 = threat.predicted_position(context.current_tick, ai.config.fixed_dt, ai.settings)
	# Lead the last observation, while staying in the local flock's leash.
	var lead: Vector2 = (threat.velocity * ai.settings.prediction_seconds).limit_length(ai.settings.max_prediction_distance)
	destination += lead
	destination = context.protection_anchor + (destination - context.protection_anchor).limit_length(ai.config.dog_leash_radius)
	write_intent(SimTypes.IntentMode.PRESSURE, SimTypes.Behavior.INTERCEPT, destination, ai.settings.dog_speed, "Assigned threat near local flock; bounded prediction", threat.handle)
	return RUNNING

func _choose_unreserved_threat() -> LocalObservation:
	var ai: AICoordinator = context.coordinator
	var selected: LocalObservation
	var best_distance: float = ai.settings.protection_radius
	for slot: int in context.observations:
		var sighting: LocalObservation = context.observations[slot]
		if sighting.species != SimTypes.Species.WOLF or context.observation_for(sighting.handle) == null:
			continue
		var distance: float = sighting.position.distance_to(context.protection_anchor)
		if distance >= best_distance:
			continue
		var reserved: bool = false
		for actor_slot: int in ai.coordination.leases:
			var lease: CoordinationSystem.Lease = ai.coordination.leases[actor_slot]
			if lease.actor_position.distance_to(context.position()) > ai.settings.cooperation_radius:
				continue
			if lease.kind == CoordinationSystem.Kind.DEFEND and lease.target.same_life(sighting.handle) and not lease.actor.same_life(context.handle):
				reserved = true
				break
		if not reserved:
			best_distance = distance
			selected = sighting
	return selected

func _exit() -> void:
	super._exit()
	# A guard or return branch starts a new pursuit on its next acceptance.
	context.pursuit_until = 0