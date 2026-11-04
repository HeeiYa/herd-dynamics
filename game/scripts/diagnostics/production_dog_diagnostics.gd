class_name ProductionDogDiagnostics
extends RefCounted
## Worker-only explanation samples for the four dogs in the behavior protocol.
## These scalar rows never influence a tree, lease, or geometric denominator.
const SAMPLE_PERIOD_TICKS: int = 3
var contexts: Array[Dictionary] = []
var threats: Array[Dictionary] = []

func sample(world: SimulationWorld, record: ProductionBehaviorTrace, context: AgentContext, intent: MotionIntent, position: Vector2, tick: int, elapsed_usec: int, wolves: Array[AgentHandle]) -> void:
	var lease: CoordinationSystem.Lease = world.ai.coordination.get_lease(record.handle, tick)
	contexts.append({
		"handle": record.handle.key(), "tick": tick, "elapsed_usec": elapsed_usec,
		"position_x": position.x, "position_y": position.y,
		"anchor_x": context.protection_anchor.x, "anchor_y": context.protection_anchor.y,
		"anchor_distance": position.distance_to(context.protection_anchor), "flock_count": context.flock_count,
		"flock_observed_tick": context.flock_sample_observed_tick, "flock_expires_tick": context.flock_sample_expires_tick,
		"context_tick": context.current_tick, "perception_tick": context.last_perception_tick,
		"decision_tick": context.last_decision_tick, "next_perception_tick": context.next_perception_tick,
		"next_decision_tick": context.next_decision_tick, "perception_queued": context.perception_queued,
		"decision_queued": context.decision_queued, "urgent_queued": context.urgent_queued,
		"task": str(context.task_name), "task_token": context.task_token,
		"returning_to_flock": context.returning_to_flock, "pursuit_until": context.pursuit_until,
		"intercept_rest_until": context.intercept_rest_until,
		"fact_dog_threat": context.dog_threat.handle.key() if context.dog_threat != null else "",
		"fact_dog_threat_valid": context.dog_threat != null and context.observation_for(context.dog_threat.handle, tick) != null,
		"intent_present": intent != null, "intent_owned": intent != null and intent.owner_token == context.task_token,
		"behavior": SimTypes.Behavior.keys()[intent.behavior] if intent != null else "NONE",
		"intent_token": intent.owner_token if intent != null else -1,
		"intent_expires_tick": intent.expires_tick if intent != null else -1,
		"intent_target": intent.target.key() if intent != null and intent.target != null else "",
		"intent_reason": intent.reason if intent != null else "",
		"lease_target": lease.target.key() if lease != null else "",
		"lease_token": lease.owner_token if lease != null else -1,
		"lease_expires_tick": lease.expires_tick if lease != null else -1,
	})
	for wolf: AgentHandle in wolves:
		_sample_threat(world, record.handle, context, position, wolf, tick, elapsed_usec)

func _sample_threat(world: SimulationWorld, dog: AgentHandle, context: AgentContext, position: Vector2, wolf: AgentHandle, tick: int, elapsed_usec: int) -> void:
	var sighting: LocalObservation = context.observations.get(wolf.slot)
	if sighting != null and not sighting.handle.same_life(wolf):
		sighting = null
	var dense: int = world.store.resolve(wolf)
	var actual_distance: float = -1.0
	if dense >= 0:
		actual_distance = position.distance_to(world.store.position_current[dense])
	threats.append({
		"dog": dog.key(), "wolf": wolf.key(), "tick": tick, "elapsed_usec": elapsed_usec,
		"actual_distance": actual_distance, "active": world.store.is_active(wolf),
		"observation_present": sighting != null, "observation_valid": context.observation_for(wolf, tick) != null,
		"observed_tick": sighting.observed_tick if sighting != null else -1,
		"expires_tick": sighting.expires_tick if sighting != null else -1,
		"last_direct_tick": sighting.last_direct_tick if sighting != null else -1,
		"source": LocalObservation.Source.keys()[sighting.source] if sighting != null else "NONE",
		"observed_distance": position.distance_to(sighting.position) if sighting != null else -1.0,
		"observed_anchor_distance": context.protection_anchor.distance_to(sighting.position) if sighting != null else -1.0,
	})
