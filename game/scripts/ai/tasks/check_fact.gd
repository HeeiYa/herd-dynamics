extends BTCondition
## Conditions read local facts and maintain small policy hysteresis latches.
## Priorities and interruption remain visible in the .tres trees.
# Tree resources serialize these values, so append facts rather than reordering.
enum Fact {
	THREAT,
	UNSAFE,
	FEEDING,
	HAS_PREY,
	ATTACK_RANGE,
	NEEDS_REGROUP,
	HAS_GRASS,
	MUST_RETURN,
	DOG_THREAT,
	VISIBLE_PREY,
	HAS_FLOCK,
	HAS_FLOCK_MEMORY,
	HARD_REGROUP,
	HUNGRY,
	SATIATED,
}
@export var fact: Fact = Fact.THREAT
var context: AgentContext

func _setup() -> void:
	context = blackboard.get_var(AIBlackboard.CONTEXT) as AgentContext

func _tick(_delta: float) -> Status:
	return SUCCESS if _holds() else FAILURE

func _holds() -> bool:
	var ai: AICoordinator = context.coordinator
	match fact:
		Fact.THREAT:
			return context.threat != null and context.observation_for(context.threat.handle) != null
		Fact.UNSAFE:
			return (context.threat != null and context.observation_for(context.threat.handle) != null) or context.current_tick < context.safe_after_tick
		Fact.FEEDING:
			return context.current_tick < context.feeding_until
		Fact.HAS_PREY:
			for slot: int in context.observations:
				var sighting: LocalObservation = context.observations[slot]
				if sighting.species == SimTypes.Species.SHEEP and context.observation_for(sighting.handle) != null:
					return true
			return false
		Fact.VISIBLE_PREY:
			for slot: int in context.observations:
				var sighting: LocalObservation = context.observations[slot]
				if sighting.species == SimTypes.Species.SHEEP and _directly_visible(sighting):
					return true
			return false
		Fact.ATTACK_RANGE:
			if context.prey == null or context.observation_for(context.prey.handle) == null:
				return false
			return _directly_visible(context.prey) and context.position().distance_to(context.prey.position) <= ai.config.attack_range + ai.settings.attack_approach_margin
		Fact.NEEDS_REGROUP:
			if context.flock_count <= 1:
				context.regrouping = false
				return false
			var flock_distance: float = context.position().distance_to(context.flock_center)
			if flock_distance > ai.settings.regroup_distance:
				context.regrouping = true
			elif flock_distance <= ai.settings.regroup_exit_distance:
				context.regrouping = false
			return context.regrouping
		Fact.HARD_REGROUP:
			return context.flock_count > 1 and context.position().distance_to(context.flock_center) > ai.settings.hard_regroup_distance
		Fact.HUNGRY:
			var hunger: float = _hunger()
			if hunger <= ai.settings.satiated_threshold:
				context.grazing_committed = false
			elif hunger >= ai.settings.hungry_threshold:
				context.grazing_committed = true
			return context.grazing_committed and context.current_tick >= context.grazing_retry_after_tick
		Fact.SATIATED:
			return _hunger() < ai.settings.hungry_threshold and not context.grazing_committed
		Fact.HAS_GRASS:
			return ai.resources.best_cell(context.position(), ai.config.perception_radius, context.current_tick) >= 0
		Fact.MUST_RETURN:
			var far_from_flock: bool = context.flock_count > 0 and context.position().distance_to(context.protection_anchor) > ai.config.dog_leash_radius
			var time_up: bool = context.pursuit_until > 0 and context.current_tick >= context.pursuit_until
			return far_from_flock or time_up or context.returning_to_flock
		Fact.DOG_THREAT:
			return context.flock_count > 0 and context.dog_threat != null and context.current_tick >= context.intercept_rest_until and context.observation_for(context.dog_threat.handle) != null
		Fact.HAS_FLOCK:
			return context.flock_count > 0
		Fact.HAS_FLOCK_MEMORY:
			return context.last_flock_seen_tick > context.last_flock_searched_tick
	return false

func _hunger() -> float:
	var dense: int = context.coordinator.store.resolve(context.handle)
	assert(dense >= 0, "A running behavior must belong to a live agent")
	return context.coordinator.store.hunger[dense]

func _directly_visible(sighting: LocalObservation) -> bool:
	return sighting.was_visible_at_scan(context.last_perception_tick, context.current_tick, context.coordinator.config.memory_ticks) and context.observation_for(sighting.handle) != null
