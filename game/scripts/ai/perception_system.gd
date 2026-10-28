class_name PerceptionSystem
extends RefCounted
## Reuses the exact-query scratch buffer; memories retain their original timestamp.
var _neighbors: Array[int] = []
var _expired: Array[int] = []

func update(context: AgentContext, tick: int) -> void:
	var ai: AICoordinator = context.coordinator
	var origin: Vector2 = context.position()
	ai.grid.query(origin, ai.config.perception_radius, -1, ai.store, _neighbors)
	for dense: int in _neighbors:
		var target: AgentHandle = ai.store.handle_at(dense)
		if target.same_life(context.handle):
			continue
		var sighting: LocalObservation = context.observations.get(target.slot)
		if sighting == null or not sighting.handle.same_life(target):
			sighting = LocalObservation.new()
			context.observations[target.slot] = sighting
		sighting.handle = target
		sighting.species = ai.store.species[dense]
		sighting.position = ai.store.position_current[dense]
		sighting.velocity = ai.store.velocity_current[dense]
		sighting.observed_tick = tick
		sighting.last_direct_tick = tick
		sighting.expires_tick = tick + ai.config.memory_ticks
		sighting.source = LocalObservation.Source.DIRECT
	_expired.clear()
	for slot: int in context.observations:
		var sighting: LocalObservation = context.observations[slot]
		if tick >= sighting.expires_tick or not ai.store.is_alive(sighting.handle):
			_expired.append(slot)
	for slot: int in _expired:
		context.observations.erase(slot)
	_refresh_local_facts(context, tick)
	context.last_perception_tick = tick

func _refresh_local_facts(context: AgentContext, tick: int) -> void:
	var ai: AICoordinator = context.coordinator
	var origin: Vector2 = context.position()
	var flock_sum := Vector2.ZERO
	context.flock_count = 0
	context.threat = null
	context.dog_threat = null
	var nearest_threat: float = INF
	var nearest_dog_threat: float = INF
	for slot: int in context.observations:
		var sighting: LocalObservation = context.observations[slot]
		if tick >= sighting.expires_tick or not ai.store.is_alive(sighting.handle):
			continue
		if sighting.species == SimTypes.Species.SHEEP:
			flock_sum += sighting.position
			context.flock_count += 1
	if context.species == SimTypes.Species.SHEEP:
		flock_sum += origin
		context.flock_count += 1
	if context.flock_count > 0:
		context.flock_center = flock_sum / float(context.flock_count)
		if context.species == SimTypes.Species.DOG:
			# The last local flock anchor survives an empty perception query.
			context.protection_anchor = context.flock_center
	for slot: int in context.observations:
		var sighting: LocalObservation = context.observations[slot]
		if tick >= sighting.expires_tick or not ai.store.is_alive(sighting.handle):
			continue
		var distance: float = origin.distance_to(sighting.position)
		var threatens_self: bool = context.species == SimTypes.Species.SHEEP and sighting.species == SimTypes.Species.WOLF
		if context.species == SimTypes.Species.WOLF and sighting.species == SimTypes.Species.DOG:
			threatens_self = distance < ai.settings.dog_risk_radius
		if threatens_self and distance < nearest_threat:
			nearest_threat = distance
			context.threat = sighting
		if context.species == SimTypes.Species.DOG and sighting.species == SimTypes.Species.WOLF:
			var flock_distance: float = sighting.position.distance_to(context.protection_anchor)
			if flock_distance < ai.settings.protection_radius and flock_distance < nearest_dog_threat:
				nearest_dog_threat = flock_distance
				context.dog_threat = sighting
	if context.threat != null:
		context.last_threat_position = context.threat.position
		context.safe_after_tick = maxi(context.safe_after_tick, context.threat.observed_tick + ai.config.safe_ticks)
	if context.prey != null:
		context.prey = context.observation_for(context.prey.handle)
func merge_shared(context: AgentContext, sighting: LocalObservation, tick: int) -> bool:
	# Merge only: the broker refreshes facts once after this phase's complete batch.
	# Checking life here also makes direct callers obey the same stale-slot boundary.
	if tick >= sighting.expires_tick or not context.coordinator.store.is_alive(sighting.handle):
		return false
	var existing: LocalObservation = context.observations.get(sighting.handle.slot)
	if existing != null and existing.handle.same_life(sighting.handle) and existing.observed_tick >= sighting.observed_tick:
		return false
	# Latest evidence and this receiver's direct visibility are independent facts.
	sighting.last_direct_tick = -1
	if existing != null and existing.handle.same_life(sighting.handle):
		sighting.last_direct_tick = existing.last_direct_tick
	context.observations[sighting.handle.slot] = sighting
	return true

func refresh_shared_facts(context: AgentContext, tick: int) -> void:
	context.current_tick = tick
	_refresh_local_facts(context, tick)
	# Sharing never updates last_perception_tick or promotes a report to DIRECT.
