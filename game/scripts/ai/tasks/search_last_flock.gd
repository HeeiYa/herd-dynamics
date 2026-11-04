extends "res://scripts/ai/tasks/context_action.gd"
## Reacquire a lost protection flock near its last genuinely observed anchor.
## Finite historical search precedes the tree's unrestricted exploration branch.
const WAYPOINT_COUNT: int = 4

func _tick(_delta: float) -> Status:
	_begin_episode_if_needed()
	if context.current_tick >= context.flock_search_deadline_tick:
		return _finish_episode()
	var settings: AISettings = context.coordinator.settings
	var position: Vector2 = context.position()
	if context.flock_search_phase == AgentContext.FlockSearchPhase.TO_ANCHOR:
		if position.distance_to(context.flock_search_anchor) > settings.guard_arrival_distance:
			write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.SEARCH, context.flock_search_anchor, settings.dog_speed, "Lost flock: return to its historical protection anchor")
			return RUNNING
		context.flock_search_phase = AgentContext.FlockSearchPhase.LOCAL_SWEEP
	return _search_near_anchor(position)

func _begin_episode_if_needed() -> void:
	if context.flock_search_observed_tick == context.last_flock_seen_tick:
		return
	context.flock_search_observed_tick = context.last_flock_seen_tick
	context.flock_search_phase = AgentContext.FlockSearchPhase.TO_ANCHOR
	context.flock_search_anchor = context.protection_anchor
	# Continue toward the historical flock's side first. Slot parity spreads
	# nearby dogs' sweep order without reading peers or invisible flock members.
	var toward_anchor: Vector2 = context.flock_search_anchor - context.position()
	context.flock_search_direction = toward_anchor.normalized() if not toward_anchor.is_zero_approx() else Vector2.RIGHT
	context.flock_search_waypoint = 0
	context.flock_search_deadline_tick = context.current_tick + context.coordinator.settings.dog_flock_search_ticks

func _search_near_anchor(position: Vector2) -> Status:
	var settings: AISettings = context.coordinator.settings
	while context.flock_search_waypoint < WAYPOINT_COUNT:
		var destination: Vector2 = _waypoint(context.flock_search_waypoint)
		if _repeats_visited_region(destination) or position.distance_to(destination) <= settings.guard_arrival_distance:
			context.flock_search_waypoint += 1
			continue
		write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.SEARCH, destination, settings.dog_speed, "Lost flock: bounded search around its historical protection anchor")
		return RUNNING
	return _finish_episode()

func _waypoint(index: int) -> Vector2:
	var ai: AICoordinator = context.coordinator
	var turn_sign: float = 1.0 if context.handle.slot % 2 == 0 else -1.0
	var direction: Vector2 = context.flock_search_direction.rotated(turn_sign * index * TAU / WAYPOINT_COUNT)
	var destination: Vector2 = context.flock_search_anchor + direction * ai.settings.dog_flock_search_radius
	var margin: Vector2 = Vector2.ONE * ai.config.agent_radius
	return destination.clamp(margin, ai.config.world_size - margin)

func _repeats_visited_region(destination: Vector2) -> bool:
	var arrival_squared: float = context.coordinator.settings.guard_arrival_distance ** 2
	if destination.distance_squared_to(context.flock_search_anchor) <= arrival_squared:
		return true
	# At a corner or in a narrow world, clipping can collapse several waypoints.
	# The four-point bound keeps skipping deterministic and finite.
	for previous: int in context.flock_search_waypoint:
		if destination.distance_squared_to(_waypoint(previous)) <= arrival_squared:
			return true
	return false

func _finish_episode() -> Status:
	context.last_flock_searched_tick = context.flock_search_observed_tick
	context.flock_search_phase = AgentContext.FlockSearchPhase.FINISHED
	return FAILURE
