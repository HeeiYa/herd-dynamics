class_name PerceptionSystem
extends RefCounted
## Reuses the exact-query scratch buffer; memories retain their original timestamp.
var _neighbors: Array[int] = []
var _expired: Array[int] = []

func update(context: AgentContext, tick: int) -> void:
	var ai: AICoordinator = context.coordinator
	var store: AgentStore = ai.store
	var observations: Dictionary[int, LocalObservation] = context.observations
	# This dense index is used only during this synchronous query. Full identity
	# resolution keeps a stale observer from hiding a new life at its old slot.
	var self_dense: int = store.resolve(context.handle)
	var origin: Vector2 = store.position_current[self_dense] if self_dense >= 0 else context.protection_anchor
	var expires_tick: int = tick + ai.config.memory_ticks
	var query_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	ai.grid.query(origin, ai.config.perception_radius, -1, store, _neighbors)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.QUERY, Time.get_ticks_usec() - query_start)
	var observe_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	for dense: int in _neighbors:
		if dense == self_dense:
			continue
		var target: AgentHandle = store.handle_at(dense)
		var target_slot: int = target.slot
		var sighting: LocalObservation = observations.get(target_slot)
		if sighting == null or not sighting.handle.same_life(target):
			sighting = LocalObservation.new()
			observations[target_slot] = sighting
		sighting.handle = target
		sighting.species = store.species[dense]
		sighting.position = store.position_current[dense]
		sighting.velocity = store.velocity_current[dense]
		sighting.observed_tick = tick
		sighting.last_direct_tick = tick
		sighting.expires_tick = expires_tick
		sighting.source = LocalObservation.Source.DIRECT
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.OBSERVE, Time.get_ticks_usec() - observe_start)
	var prune_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_expired.clear()
	for slot: int in observations:
		var sighting: LocalObservation = observations[slot]
		if tick >= sighting.expires_tick or not store.is_alive(sighting.handle):
			_expired.append(slot)
	for slot: int in _expired:
		observations.erase(slot)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.PRUNE, Time.get_ticks_usec() - prune_start)
	# Direct sensing mutates observation objects in place and may erase entries.
	context.flock_cache_dirty = true
	context.threat_view_dirty = true
	var refresh_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_refresh_local_facts(context, tick)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.REFRESH_DIRECT, Time.get_ticks_usec() - refresh_start)
	context.last_perception_tick = tick

func _refresh_local_facts(context: AgentContext, tick: int) -> void:
	var ai: AICoordinator = context.coordinator
	var refresh_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_refresh_observation_cache(context, tick)
	var origin: Vector2 = context.position()
	var flock_sum: Vector2 = context.remembered_flock_sum
	context.flock_count = context.remembered_flock_count
	if context.species == SimTypes.Species.SHEEP:
		# Match the original summation order: remembered sheep first, self last.
		flock_sum += origin
		context.flock_count += 1
	if context.flock_count > 0:
		context.flock_center = flock_sum / float(context.flock_count)
		if context.species == SimTypes.Species.DOG:
			# No sheep means retain the previous protection anchor.
			context.protection_anchor = context.flock_center
	context.threat = null
	context.dog_threat = null
	var nearest_threat: float = INF
	for sighting: LocalObservation in context.threat_observations:
		# Threat views include stale observations to preserve insertion order when
		# a later report refreshes them. They are validated on every use.
		if tick >= sighting.expires_tick or not ai.store.is_alive(sighting.handle):
			continue
		if context.species == SimTypes.Species.DOG:
			var flock_distance: float = sighting.position.distance_to(context.protection_anchor)
			if flock_distance < ai.settings.protection_radius and flock_distance < nearest_threat:
				nearest_threat = flock_distance
				context.dog_threat = sighting
			continue
		var distance: float = origin.distance_to(sighting.position)
		if context.species == SimTypes.Species.WOLF and distance >= ai.settings.dog_risk_radius:
			continue
		if distance < nearest_threat:
			nearest_threat = distance
			context.threat = sighting
	if context.threat != null:
		context.last_threat_position = context.threat.position
		context.safe_after_tick = maxi(context.safe_after_tick, context.threat.observed_tick + ai.config.safe_ticks)
	if context.prey != null:
		context.prey = context.observation_for(context.prey.handle)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.REFRESH, Time.get_ticks_usec() - refresh_start)

func _refresh_observation_cache(context: AgentContext, tick: int) -> void:
	var store: AgentStore = context.coordinator.store
	if context.fact_cache_life_revision != store.life_revision:
		# Birth/death/removal/reset may invalidate any full handle. This is a
		# conservative invalidation signal, not a substitute for lifetime checks.
		context.flock_cache_dirty = true
		context.threat_view_dirty = true
	if tick >= context.flock_cache_expires_tick:
		context.flock_cache_dirty = true
	if not context.flock_cache_dirty and not context.threat_view_dirty:
		return
	var rebuild_flock: bool = context.flock_cache_dirty
	var rebuild_threats: bool = context.threat_view_dirty
	var flock_sum := Vector2.ZERO
	var flock_count: int = 0
	var expires_tick: int = 9223372036854775807
	if rebuild_threats:
		context.threat_observations.clear()
		context.threat_view_indices.clear()
	var threat_species: int = SimTypes.Species.DOG if context.species == SimTypes.Species.WOLF else SimTypes.Species.WOLF
	# Full rebuilds follow Dictionary insertion order, including equal-distance
	# candidates. Never incrementally subtract sheep positions: that changes sums.
	for slot: int in context.observations:
		var sighting: LocalObservation = context.observations[slot]
		if rebuild_threats and sighting.species == threat_species:
			context.threat_view_indices[slot] = context.threat_observations.size()
			context.threat_observations.append(sighting)
		if not rebuild_flock or sighting.species != SimTypes.Species.SHEEP:
			continue
		if tick >= sighting.expires_tick or not store.is_alive(sighting.handle):
			continue
		flock_sum += sighting.position
		flock_count += 1
		expires_tick = mini(expires_tick, sighting.expires_tick)
	if rebuild_flock:
		context.remembered_flock_sum = flock_sum
		context.remembered_flock_count = flock_count
		context.flock_cache_expires_tick = expires_tick
	context.flock_cache_dirty = false
	context.threat_view_dirty = false
	context.fact_cache_life_revision = store.life_revision

func _cache_shared_sighting(context: AgentContext, previous: LocalObservation, sighting: LocalObservation) -> void:
	if sighting.species == SimTypes.Species.SHEEP or (previous != null and previous.species == SimTypes.Species.SHEEP):
		context.flock_cache_dirty = true
	if previous != null and previous.species != sighting.species:
		# Replacing a different species at an existing key must retain that key's
		# original position relative to every other observation in the dictionary.
		context.threat_view_dirty = true
	if context.threat_view_dirty:
		return
	var threat_species: int = SimTypes.Species.DOG if context.species == SimTypes.Species.WOLF else SimTypes.Species.WOLF
	if sighting.species != threat_species:
		return
	var index: int = context.threat_view_indices.get(sighting.handle.slot, -1)
	if index >= 0:
		context.threat_observations[index] = sighting
	else:
		# Only a newly inserted observation reaches here for a valid view.
		assert(previous == null, "Threat view is missing an existing observation")
		context.threat_view_indices[sighting.handle.slot] = context.threat_observations.size()
		context.threat_observations.append(sighting)

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
	_cache_shared_sighting(context, existing, sighting)
	return true

func refresh_shared_facts(context: AgentContext, tick: int) -> void:
	context.current_tick = tick
	var ai: AICoordinator = context.coordinator
	var refresh_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_refresh_local_facts(context, tick)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.REFRESH_SHARED, Time.get_ticks_usec() - refresh_start)
	# Sharing never updates last_perception_tick or promotes a report to DIRECT.
