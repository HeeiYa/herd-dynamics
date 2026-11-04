class_name AgentInspection
extends RefCounted
## Selected-life read model. No Blackboard, BT instance or live Node crosses
## the executor boundary; sightings belong to this life's intent or lease target.
var handle: AgentHandle
var task_name: StringName
var observation_count: int = 0
var last_perception_tick: int = -1
var last_decision_tick: int = 0
var next_perception_tick: int = 0
var next_decision_tick: int = 0
var perception_queued: bool = false
var decision_queued: bool = false
var urgent_queued: bool = false
var protection_anchor: Vector2
var flock_count: int = 0
var flock_evidence_count: int = 0
var flock_is_direct_sample: bool = false
var flock_observed_tick: int = -1
var flock_expires_tick: int = 0
var last_flock_seen_tick: int = -1
var last_flock_searched_tick: int = -1
var flock_search_observed_tick: int = -1
var flock_search_phase: AgentContext.FlockSearchPhase = AgentContext.FlockSearchPhase.FINISHED
var flock_search_deadline_tick: int = 0
var sighting: LocalObservation
var lease_sighting: LocalObservation
var attack: AttackRequest
var lease: CoordinationSystem.Lease

static func capture(world: SimulationWorld, selected: AgentHandle) -> AgentInspection:
	var context: AgentContext = world.ai.inspect(selected)
	if context == null:
		return null
	var result := AgentInspection.new()
	result.handle = selected
	result.task_name = context.task_name
	result.observation_count = context.observations.size()
	result.last_perception_tick = context.last_perception_tick
	result.last_decision_tick = context.last_decision_tick
	result.next_perception_tick = context.next_perception_tick
	result.next_decision_tick = context.next_decision_tick
	result.perception_queued = context.perception_queued
	result.decision_queued = context.decision_queued
	result.urgent_queued = context.urgent_queued
	result.protection_anchor = context.protection_anchor
	result.flock_count = context.flock_count
	# Copy the evidence itself, not a derived count that may await the next AI job.
	# The presenter can expire this one local sample without scanning live sheep.
	result.flock_is_direct_sample = world.config.compact_flock_knowledge and context.species != SimTypes.Species.WOLF
	if result.flock_is_direct_sample:
		result.flock_evidence_count = context.flock_sample_count
		result.flock_observed_tick = context.flock_sample_observed_tick
		result.flock_expires_tick = context.flock_sample_expires_tick
	else:
		result.flock_evidence_count = context.flock_count
		result.flock_observed_tick = context.last_perception_tick
		result.flock_expires_tick = context.flock_cache_expires_tick
	result.last_flock_seen_tick = context.last_flock_seen_tick
	result.last_flock_searched_tick = context.last_flock_searched_tick
	result.flock_search_observed_tick = context.flock_search_observed_tick
	result.flock_search_phase = context.flock_search_phase
	result.flock_search_deadline_tick = context.flock_search_deadline_tick
	var intent: MotionIntent = world.intents.get_intent(selected, world.tick)
	var observation: LocalObservation = context.observation_for(intent.target, world.tick) if intent != null else null
	result.sighting = _copy_observation(observation)
	var source_attack: AttackRequest = world.interaction.get_attack(selected)
	if source_attack != null:
		result.attack = AttackRequest.new()
		result.attack.actor = source_attack.actor
		result.attack.target = source_attack.target
		result.attack.owner_token = source_attack.owner_token
		result.attack.accepted_tick = source_attack.accepted_tick
		result.attack.active_start_tick = source_attack.active_start_tick
		result.attack.active_end_tick = source_attack.active_end_tick
		result.attack.cooldown_until_tick = source_attack.cooldown_until_tick
		result.attack.status = source_attack.status
		result.attack.contact_fraction = source_attack.contact_fraction
	var source_lease: CoordinationSystem.Lease = world.ai.coordination.get_lease(selected, world.tick)
	if source_lease != null:
		result.lease = CoordinationSystem.Lease.new()
		result.lease.actor = source_lease.actor
		result.lease.target = source_lease.target
		result.lease.kind = source_lease.kind
		result.lease.role = source_lease.role
		result.lease.owner_token = source_lease.owner_token
		result.lease.expires_tick = source_lease.expires_tick
		result.lease.actor_position = source_lease.actor_position
		result.lease_sighting = _copy_observation(context.observation_for(source_lease.target, world.tick))
	return result

static func _copy_observation(observation: LocalObservation) -> LocalObservation:
	if observation == null:
		return null
	var copy: LocalObservation = observation.copy_sighting()
	# A UI copy preserves the observer's provenance; it is not a shared report.
	copy.last_direct_tick = observation.last_direct_tick
	copy.source = observation.source
	return copy

func observation_for(target: AgentHandle, tick: int) -> LocalObservation:
	if target == null or sighting == null or not sighting.handle.same_life(target) or tick >= sighting.expires_tick:
		return null
	return sighting

func lease_observation_for(target: AgentHandle, tick: int) -> LocalObservation:
	if target == null or lease_sighting == null or not lease_sighting.handle.same_life(target) or tick >= lease_sighting.expires_tick:
		return null
	return lease_sighting
