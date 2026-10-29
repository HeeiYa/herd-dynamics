class_name PerceptionSystem
extends RefCounted
## Retains exact action targets and an optional flock sample with its own lifetime.
const NO_EXPIRY_TICK: int = 9223372036854775807

var _neighbors: Array[int] = []
var _secondary_neighbors: Array[int] = []
var _expired: Array[int] = []
var _flock_query: SpatialGrid.FlockSample = SpatialGrid.FlockSample.new()

func update(context: AgentContext, tick: int) -> void:
	context.current_tick = tick
	var ai: AICoordinator = context.coordinator
	var store: AgentStore = ai.store
	var observations: Dictionary[int, LocalObservation] = context.observations
	# This dense index is used only during this synchronous query. Full identity
	# resolution keeps a stale observer from hiding a new life at its old slot.
	var self_dense: int = store.resolve(context.handle)
	var origin: Vector2 = store.position_current[self_dense] if self_dense >= 0 else context.protection_anchor
	var expires_tick: int = tick + ai.config.memory_ticks
	var query_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_query_targets(context, origin)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.QUERY, Time.get_ticks_usec() - query_start)
	if _uses_flock_sample(context):
		var flock_query_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
		if context.species == SimTypes.Species.DOG:
			ai.grid.query_protection_flock(origin, ai.config.perception_radius, context.protection_anchor, context.last_flock_seen_tick >= 0, store, _flock_query, ai.settings.protection_commit_bonus)
		else:
			ai.grid.query_flock(origin, ai.config.perception_radius, store, _flock_query)
		context.flock_sample_count = _flock_query.count
		context.flock_sample_center = _flock_query.position_sum / float(_flock_query.count) if _flock_query.count > 0 else origin
		context.flock_sample_observed_tick = tick
		context.flock_sample_expires_tick = expires_tick
		if ai.probes.enabled:
			ai.probes.record(Probes.Tag.FLOCK_QUERY, Time.get_ticks_usec() - flock_query_start)
	var observe_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	for dense: int in _neighbors:
		if dense == self_dense:
			continue
		var target: AgentHandle = store.handle_at(dense)
		var target_slot: int = target.slot
		var sighting: LocalObservation = observations.get(target_slot)
		if sighting == null or not sighting.handle.same_life(target):
			sighting = LocalObservation.new()
			sighting.handle = target
			sighting.species = store.species[dense]
			observations[target_slot] = sighting
		sighting.position = store.position_current[dense]
		sighting.velocity = store.velocity_current[dense]
		sighting.observed_tick = tick
		sighting.last_direct_tick = tick
		sighting.expires_tick = expires_tick
		sighting.source = LocalObservation.Source.DIRECT
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.OBSERVE, Time.get_ticks_usec() - observe_start)
	var prune_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	# One ordered pass prunes memories and rebuilds both derived caches. The
	# PRUNE probe includes this fused maintenance; REFRESH covers derived facts.
	context.flock_cache_dirty = true
	context.threat_view_dirty = true
	_reduce_observations(context, tick, true)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.PRUNE, Time.get_ticks_usec() - prune_start)
	var refresh_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_refresh_local_facts(context, tick)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.REFRESH_DIRECT, Time.get_ticks_usec() - refresh_start)
	context.last_perception_tick = tick

func _query_targets(context: AgentContext, origin: Vector2) -> void:
	var ai: AICoordinator = context.coordinator
	if not ai.config.compact_flock_knowledge:
		_query_candidates(ai, origin, -1, _neighbors)
		return
	if context.species == SimTypes.Species.WOLF:
		_query_candidates(ai, origin, SimTypes.Species.SHEEP, _neighbors)
		_query_candidates(ai, origin, SimTypes.Species.DOG, _secondary_neighbors)
		_neighbors.append_array(_secondary_neighbors)
		return
	_query_candidates(ai, origin, SimTypes.Species.WOLF, _neighbors)

func _query_candidates(ai: AICoordinator, origin: Vector2, species_filter: int, output: Array[int]) -> void:
	if ai.config.shared_cell_candidates:
		ai.grid.query_shared(origin, ai.config.perception_radius, species_filter, ai.store, output)
	else:
		ai.grid.query(origin, ai.config.perception_radius, species_filter, ai.store, output)

func _uses_flock_sample(context: AgentContext) -> bool:
	return context.coordinator.config.compact_flock_knowledge and context.species != SimTypes.Species.WOLF

func _retains_individual(context: AgentContext, species: int) -> bool:
	if not context.coordinator.config.compact_flock_knowledge:
		return true
	if context.species == SimTypes.Species.WOLF:
		return species == SimTypes.Species.SHEEP or species == SimTypes.Species.DOG
	return species == SimTypes.Species.WOLF

func prepare_decision(context: AgentContext, tick: int) -> void:
	# A delayed decision consumes current local facts, never a new spatial query.
	context.current_tick = tick
	var knowledge_changed: bool = context.facts_dirty or context.flock_cache_dirty or context.threat_view_dirty
	var life_changed: bool = context.fact_cache_life_revision != context.coordinator.store.life_revision
	# Individual flock memory adds the sheep's live self-position to remembered
	# peers. Compact samples instead keep their original observation-time center.
	var flock_includes_live_observer: bool = context.species == SimTypes.Species.SHEEP and not _uses_flock_sample(context)
	var position_affects_facts: bool = flock_includes_live_observer or not context.threat_observations.is_empty()
	var observer_moved: bool = position_affects_facts and context.position() != context.facts_origin
	if knowledge_changed or life_changed or observer_moved or tick >= context.facts_expire_tick:
		_refresh_local_facts(context, tick)
	elif _uses_flock_sample(context) and context.species == SimTypes.Species.SHEEP and tick >= context.flock_sample_expires_tick:
		# Once a sample expires, the only known member is this moving observer.
		context.flock_center = context.position()

func _refresh_local_facts(context: AgentContext, tick: int) -> void:
	var ai: AICoordinator = context.coordinator
	var refresh_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_refresh_observation_cache(context, tick)
	var origin: Vector2 = context.position()
	var facts_expire_tick: int = _refresh_flock_fact(context, tick, origin)
	context.threat = null
	context.dog_threat = null
	var nearest_threat: float = INF
	for sighting: LocalObservation in context.threat_observations:
		# Threat views include stale observations to preserve insertion order when
		# a later report refreshes them. They are validated on every use.
		if tick >= sighting.expires_tick or not ai.store.is_alive(sighting.handle):
			continue
		# Every valid candidate can become the next selection when an earlier
		# candidate expires, including candidates outside today's risk threshold.
		facts_expire_tick = mini(facts_expire_tick, sighting.expires_tick)
		if context.species == SimTypes.Species.DOG:
			var flock_distance: float = sighting.position.distance_to(context.protection_anchor)
			if flock_distance < ai.settings.protection_radius and flock_distance < nearest_threat:
				nearest_threat = flock_distance
				context.dog_threat = sighting
			continue
		var distance: float = origin.distance_to(sighting.position)
		if context.species == SimTypes.Species.WOLF:
			var risk_radius: float = ai.settings.dog_risk_exit_radius if context.retreating else ai.settings.dog_risk_radius
			if distance >= risk_radius:
				continue
		if distance < nearest_threat:
			nearest_threat = distance
			context.threat = sighting
	if context.threat != null:
		context.last_threat_position = context.threat.position
		context.safe_after_tick = maxi(context.safe_after_tick, context.threat.observed_tick + ai.config.safe_ticks)
	if context.prey != null:
		context.prey = context.observation_for(context.prey.handle)
		if context.prey != null:
			facts_expire_tick = mini(facts_expire_tick, context.prey.expires_tick)
	context.facts_expire_tick = facts_expire_tick
	context.facts_origin = origin
	context.facts_dirty = false
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.REFRESH, Time.get_ticks_usec() - refresh_start)

func _refresh_flock_fact(context: AgentContext, tick: int, origin: Vector2) -> int:
	if _uses_flock_sample(context):
		if context.flock_sample_observed_tick >= 0 and tick < context.flock_sample_expires_tick:
			context.flock_count = context.flock_sample_count
			if context.flock_count > 0:
				context.flock_center = context.flock_sample_center
				if context.species == SimTypes.Species.DOG:
					context.protection_anchor = context.flock_center
					context.last_flock_seen_tick = context.flock_sample_observed_tick
			return context.flock_sample_expires_tick
		context.flock_count = 0
		if context.species == SimTypes.Species.SHEEP:
			context.flock_count = 1
			context.flock_center = origin
		# An expired dog sample retains only its last protection anchor.
		return NO_EXPIRY_TICK
	var flock_sum: Vector2 = context.remembered_flock_sum
	context.flock_count = context.remembered_flock_count
	if context.species == SimTypes.Species.SHEEP:
		# Match the legacy summation order: remembered sheep first, self last.
		flock_sum += origin
		context.flock_count += 1
	if context.flock_count > 0:
		context.flock_center = flock_sum / float(context.flock_count)
		if context.species == SimTypes.Species.DOG:
			context.protection_anchor = context.flock_center
			context.last_flock_seen_tick = tick
	return context.flock_cache_expires_tick

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
	_reduce_observations(context, tick, false)

func _reduce_observations(context: AgentContext, tick: int, prune_expired: bool) -> void:
	var store: AgentStore = context.coordinator.store
	var rebuild_flock: bool = context.flock_cache_dirty
	var collect_flock: bool = rebuild_flock and not _uses_flock_sample(context)
	var rebuild_threats: bool = context.threat_view_dirty
	var flock_sum := Vector2.ZERO
	var flock_count: int = 0
	var expires_tick: int = NO_EXPIRY_TICK
	_expired.clear()
	if rebuild_threats:
		context.threat_observations.clear()
		context.threat_view_indices.clear()
	var threat_species: int = SimTypes.Species.DOG if context.species == SimTypes.Species.WOLF else SimTypes.Species.WOLF
	# Full rebuilds follow Dictionary insertion order, including equal-distance
	# candidates. Never incrementally subtract sheep positions: that changes sums.
	for slot: int in context.observations:
		var sighting: LocalObservation = context.observations[slot]
		if prune_expired:
			if tick >= sighting.expires_tick or not store.is_alive(sighting.handle) or not _retains_individual(context, sighting.species):
				_expired.append(slot)
				continue
		if rebuild_threats and sighting.species == threat_species:
			context.threat_view_indices[slot] = context.threat_observations.size()
			context.threat_observations.append(sighting)
		if not collect_flock or sighting.species != SimTypes.Species.SHEEP:
			continue
		if not prune_expired and (tick >= sighting.expires_tick or not store.is_alive(sighting.handle)):
			continue
		flock_sum += sighting.position
		flock_count += 1
		expires_tick = mini(expires_tick, sighting.expires_tick)
	for slot: int in _expired:
		context.observations.erase(slot)
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
	if not _retains_individual(context, sighting.species) or tick >= sighting.expires_tick or not context.coordinator.store.is_alive(sighting.handle):
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
	context.facts_dirty = true
	return true

func refresh_shared_facts(context: AgentContext, tick: int) -> void:
	context.current_tick = tick
	var ai: AICoordinator = context.coordinator
	var refresh_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_refresh_local_facts(context, tick)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.REFRESH_SHARED, Time.get_ticks_usec() - refresh_start)
	# Sharing never updates last_perception_tick or promotes a report to DIRECT.
