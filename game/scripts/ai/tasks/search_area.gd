extends "res://scripts/ai/tasks/context_action.gd"
## Only world bounds and this actor's travel history influence unknown-area search.
const CANDIDATE_COUNT: int = 12
const GOLDEN_ANGLE: float = 2.399963229728653

func _tick(_delta: float) -> Status:
	var settings: AISettings = context.coordinator.settings
	var origin: Vector2 = context.position()
	var arrived: bool = origin.distance_to(context.wander_destination) <= settings.exploration_arrival_distance
	var stalled: bool = false
	if origin.distance_to(context.exploration_progress_position) >= settings.exploration_progress_distance:
		context.exploration_progress_position = origin
		context.exploration_progress_tick = context.current_tick
	elif context.current_tick - context.exploration_progress_tick >= settings.exploration_stall_ticks:
		stalled = true
	if arrived or stalled or context.current_tick >= context.wander_until:
		_choose_leg(origin)
	var speed: float = settings.sheep_speed
	if context.species == SimTypes.Species.WOLF:
		speed = settings.wolf_search_speed
	elif context.species == SimTypes.Species.DOG:
		speed = settings.dog_speed
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.SEARCH, context.wander_destination, speed, "Explore a sustained leg away from recent visits")
	return RUNNING

func _choose_leg(origin: Vector2) -> void:
	var ai: AICoordinator = context.coordinator
	var settings: AISettings = ai.settings
	var previous_direction: Vector2 = (context.wander_destination - context.exploration_progress_position).normalized()
	_remember_visit(origin)
	var margin: Vector2 = Vector2.ONE * ai.config.agent_radius
	var phase: float = float(context.handle.slot * 17 + context.handle.generation * 31 + context.exploration_sequence) * GOLDEN_ANGLE
	var best_score: float = -INF
	var selected: Vector2 = origin
	for index: int in range(CANDIDATE_COUNT):
		var direction: Vector2 = Vector2.from_angle(phase + TAU * float(index) / float(CANDIDATE_COUNT))
		var candidate: Vector2 = (origin + direction * settings.exploration_leg_distance).clamp(margin, ai.config.world_size - margin)
		var distance: float = candidate.distance_to(origin)
		if distance <= settings.exploration_arrival_distance:
			continue
		var closest_visit: float = settings.exploration_leg_distance
		var accumulated_distance: float = 0.0
		for visit: Vector2 in context.exploration_history:
			var visit_distance: float = candidate.distance_to(visit)
			closest_visit = minf(closest_visit, visit_distance)
			accumulated_distance += minf(visit_distance, settings.exploration_leg_distance * 2.0)
		var average_distance: float = accumulated_distance / float(context.exploration_history.size())
		# Prefer coverage, then a useful leg and continuity. These are only ranking
		# weights; none authorizes knowledge about unobserved animals.
		var score: float = closest_visit + average_distance * 0.15 + distance * 0.3
		score += previous_direction.dot((candidate - origin).normalized()) * settings.exploration_leg_distance * 0.15
		if score > best_score:
			best_score = score
			selected = candidate
	context.wander_destination = selected
	context.wander_until = context.current_tick + settings.exploration_timeout_ticks
	context.exploration_progress_position = origin
	context.exploration_progress_tick = context.current_tick
	context.exploration_sequence += 1

func _remember_visit(position: Vector2) -> void:
	var capacity: int = context.coordinator.settings.exploration_history_size
	assert(capacity > 0)
	if context.exploration_history.size() < capacity:
		context.exploration_history.append(position)
	else:
		context.exploration_history[context.exploration_history_cursor] = position
	context.exploration_history_cursor = (context.exploration_history_cursor + 1) % capacity
