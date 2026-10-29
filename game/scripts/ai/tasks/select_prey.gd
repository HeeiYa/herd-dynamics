extends BTAction
## Target scoring and commitment are strategy, so they live in this named BT leaf.
@export var require_direct_sighting: bool = true
var context: AgentContext
var _defenders: Array[LocalObservation] = []

func _setup() -> void:
	context = blackboard.get_var(AIBlackboard.CONTEXT) as AgentContext

func _tick(_delta: float) -> Status:
	_defenders.clear()
	for slot: int in context.observations:
		var observation: LocalObservation = context.observations[slot]
		if observation.species == SimTypes.Species.DOG and context.observation_for(observation.handle) != null:
			_defenders.append(observation)
	var best: LocalObservation
	var best_score: float = INF
	for slot: int in context.observations:
		var candidate: LocalObservation = context.observations[slot]
		if not _eligible(candidate):
			continue
		var score: float = _score(candidate)
		if score < best_score:
			best = candidate
			best_score = score
	if best == null:
		context.prey = null
		return FAILURE
	var committed: LocalObservation = context.observation_for(context.committed_target)
	if committed != null and _eligible(committed) and context.current_tick < context.commit_until:
		if best_score >= _score(committed) * context.coordinator.settings.target_switch_ratio:
			best = committed
	if context.committed_target == null or not context.committed_target.same_life(best.handle):
		context.committed_target = best.handle
		context.commit_until = context.current_tick + context.coordinator.settings.wolf_commit_ticks
	context.prey = best
	return SUCCESS

func _score(candidate: LocalObservation) -> float:
	var settings: AISettings = context.coordinator.settings
	var score: float = context.position().distance_to(candidate.position)
	# Distance from the local flock center is a cheap isolation estimate, not exact neighbor counting.
	score -= minf(candidate.position.distance_to(context.flock_center), settings.isolation_radius) * settings.isolation_penalty / settings.isolation_radius
	for defender: LocalObservation in _defenders:
		if defender.position.distance_to(candidate.position) < settings.dog_risk_radius:
			score += settings.guarded_prey_penalty
			break
	return maxf(1.0, score)
func _eligible(sighting: LocalObservation) -> bool:
	if sighting.species != SimTypes.Species.SHEEP or context.observation_for(sighting.handle) == null:
		return false
	if context.rejected_prey != null and context.current_tick < context.rejected_prey_until and context.rejected_prey.same_life(sighting.handle):
		return false
	if not require_direct_sighting:
		return true
	return sighting.was_visible_at_scan(context.last_perception_tick, context.current_tick, context.coordinator.config.memory_ticks)
