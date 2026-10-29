extends "res://scripts/ai/tasks/context_action.gd"
var _requested_target: AgentHandle
var _request_started_tick: int = 0

func _enter() -> void:
	super._enter()
	_requested_target = null

func _tick(_delta: float) -> Status:
	var sighting: LocalObservation = context.prey
	if sighting == null or context.observation_for(sighting.handle) == null:
		return FAILURE
	var ai: AICoordinator = context.coordinator
	var origin: Vector2 = context.position()
	if _requested_target == null or not _requested_target.same_life(sighting.handle):
		ai.coordination.release(context.handle, token)
		_requested_target = sighting.handle
		_request_started_tick = context.current_tick
		ai.coordination.request(context.handle, sighting.handle, CoordinationSystem.Kind.HUNT, token, origin, context.current_tick)
	var status: CoordinationSystem.RequestStatus = ai.coordination.request_status(context.handle, sighting.handle, token, context.current_tick)
	if status == CoordinationSystem.RequestStatus.REJECTED or status == CoordinationSystem.RequestStatus.INVALID:
		return _reject_target(sighting.handle)
	if status == CoordinationSystem.RequestStatus.PENDING and context.current_tick - _request_started_tick >= ai.settings.hunt_request_wait_ticks:
		return _reject_target(sighting.handle)
	var lease: CoordinationSystem.Lease = ai.coordination.get_lease(context.handle, context.current_tick)
	var destination: Vector2 = sighting.predicted_position(context.current_tick, ai.config.fixed_dt, ai.settings)
	var behavior: int = SimTypes.Behavior.STALK
	var speed: float = ai.settings.wolf_search_speed
	if status == CoordinationSystem.RequestStatus.ACCEPTED and lease != null:
		context.lease_token = token
		ai.coordination.request(context.handle, sighting.handle, CoordinationSystem.Kind.HUNT, token, origin, context.current_tick)
		behavior = SimTypes.Behavior.CHASE
		speed = ai.settings.wolf_speed
		if lease.role != CoordinationSystem.Role.MAIN and origin.distance_to(destination) > ai.config.attack_range * 2.0:
			var forward: Vector2 = sighting.velocity.normalized()
			if forward.length_squared() < 0.001:
				forward = (destination - origin).normalized()
			var side: float = -1.0 if lease.role == CoordinationSystem.Role.LEFT else 1.0
			destination += forward.orthogonal() * ai.settings.flank_distance * side
			behavior = SimTypes.Behavior.FLANK
	write_intent(SimTypes.IntentMode.MOVE, behavior, destination, speed, "Observed prey; bounded request wait or accepted hunt role", sighting.handle)
	return RUNNING

func _reject_target(target: AgentHandle) -> Status:
	context.rejected_prey = target
	context.rejected_prey_until = context.current_tick + context.coordinator.settings.hunt_retry_ticks
	context.committed_target = null
	context.prey = null
	return FAILURE
