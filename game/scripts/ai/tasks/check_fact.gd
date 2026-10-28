extends BTCondition
## Conditions read facts; priorities and interruption are visible in the .tres trees.
enum Fact { THREAT, UNSAFE, FEEDING, HAS_PREY, ATTACK_RANGE, NEEDS_REGROUP, HAS_GRASS, MUST_RETURN, DOG_THREAT, VISIBLE_PREY }
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
			return context.flock_count > 1 and context.position().distance_to(context.flock_center) > ai.settings.regroup_distance
		Fact.HAS_GRASS:
			return ai.resources.best_cell(context.position(), ai.config.perception_radius, context.current_tick) >= 0
		Fact.MUST_RETURN:
			var far_from_flock: bool = context.position().distance_to(context.protection_anchor) > ai.config.dog_leash_radius
			var time_up: bool = context.pursuit_until > 0 and context.current_tick >= context.pursuit_until
			var returning: bool = context.current_tick < context.intercept_rest_until and context.position().distance_to(context.protection_anchor) > ai.settings.guard_arrival_distance
			return far_from_flock or time_up or returning
		Fact.DOG_THREAT:
			return context.dog_threat != null and context.current_tick >= context.intercept_rest_until and context.observation_for(context.dog_threat.handle) != null
	return false
func _directly_visible(sighting: LocalObservation) -> bool:
	return sighting.was_visible_at_scan(context.last_perception_tick, context.current_tick, context.coordinator.config.memory_ticks) and context.observation_for(sighting.handle) != null
