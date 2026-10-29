extends SceneTree
## Small-snapshot reference checks for the local knowledge reduction.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_snapshot_equivalence()
	_test_ties_and_thresholds()
	_test_shared_refresh_and_reuse()
	_test_cached_shared_updates()
	_test_cached_lifetime_boundaries()
	_test_shared_species_replacement()
	_test_direct_cache_invalidation()
	_test_clear_runtime_cache()
	_test_compact_target_storage()
	_test_compact_sample_lifetime()
	_test_compact_sample_replacement()
	_test_compact_wolf_memory()
	print("PERCEPTION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _make_context(ai: AICoordinator, kind: int, position: Vector2, tick: int, compact: bool = false) -> AgentContext:
	# The small-snapshot oracle describes the legacy individual-memory policy.
	ai.config.compact_flock_knowledge = compact
	var context := AgentContext.new()
	context.coordinator = ai
	context.species = kind
	context.handle = ai.store.create_agent(kind, position)
	context.current_tick = tick
	return context

func _add_sighting(context: AgentContext, kind: int, position: Vector2, tick: int, lifetime: int) -> LocalObservation:
	var sighting := LocalObservation.new()
	sighting.handle = context.coordinator.store.create_agent(kind, position + Vector2(11, 23))
	sighting.species = kind
	sighting.position = position
	sighting.velocity = Vector2(12, -15)
	sighting.observed_tick = tick
	sighting.last_direct_tick = tick
	sighting.expires_tick = tick + lifetime
	context.observations[sighting.handle.slot] = sighting
	return sighting

func _copy_context(source: AgentContext) -> AgentContext:
	var reference := AgentContext.new()
	reference.coordinator = source.coordinator
	reference.handle = source.handle
	reference.species = source.species
	reference.current_tick = source.current_tick
	reference.observations = source.observations.duplicate()
	reference.flock_center = source.flock_center
	reference.flock_count = source.flock_count
	reference.protection_anchor = source.protection_anchor
	reference.last_threat_position = source.last_threat_position
	reference.safe_after_tick = source.safe_after_tick
	reference.threat = source.threat
	reference.dog_threat = source.dog_threat
	reference.prey = source.prey
	return reference

func _compare_refresh(perception: PerceptionSystem, context: AgentContext) -> void:
	var reference: AgentContext = _copy_context(context)
	var count_before: int = context.observations.size()
	_reference_refresh(reference, context.current_tick)
	perception._refresh_local_facts(context, context.current_tick)
	_check(context.flock_count == reference.flock_count and context.flock_center == reference.flock_center, "Local flock count and ordered sum match the reference exactly")
	_check(context.protection_anchor == reference.protection_anchor, "Protected flock anchor matches, including an empty remembered flock")
	_check(context.threat == reference.threat and context.dog_threat == reference.dog_threat, "Threat selection and stable tie order match the reference")
	_check(context.last_threat_position == reference.last_threat_position and context.safe_after_tick == reference.safe_after_tick, "Threat memory and safe deadline match the reference")
	_check(context.prey == reference.prey, "Prey refresh observes identity and TTL exactly")
	_check(context.observations.size() == count_before, "Fact reduction does not mutate the observation collection")
	reference.free()

func _test_snapshot_equivalence() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 528610
	var perception := PerceptionSystem.new()
	for species: int in 3:
		for snapshot: int in 120:
			var ai := AICoordinator.new()
			ai.store = AgentStore.new()
			ai.config = SimulationConfig.new()
			var tick: int = 200 + snapshot
			var context: AgentContext = _make_context(ai, species, Vector2(random.randf_range(0, 1600), random.randf_range(0, 1000)), tick)
			context.flock_center = Vector2(700, 400)
			context.protection_anchor = Vector2(300, 800)
			context.last_threat_position = Vector2(160, 250)
			context.safe_after_tick = tick + 30
			for index: int in random.randi_range(0, 70):
				var kind: int = random.randi_range(0, 2)
				var position := Vector2(random.randf_range(0, 1600), random.randf_range(0, 1000))
				var observation: LocalObservation = _add_sighting(context, kind, position, tick - random.randi_range(0, 140), 120)
				observation.source = LocalObservation.Source.SHARED if index % 2 == 0 else LocalObservation.Source.DIRECT
				if index % 11 == 0:
					ai.store.mark_dead(observation.handle)
				elif index % 7 == 0:
					ai.store.remove_agent(observation.handle)
					ai.store.create_agent(kind, Vector2.ZERO)
				if index == 3:
					context.prey = observation
			_compare_refresh(perception, context)
			# Moving the observer and aging all memories must still rebuild the facts.
			ai.store.position_current[ai.store.resolve(context.handle)] += Vector2(31, -17)
			context.current_tick += 60
			_compare_refresh(perception, context)
			context.free()
			ai.free()

func _test_ties_and_thresholds() -> void:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	var perception := PerceptionSystem.new()
	var sheep: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100)
	var first: LocalObservation = _add_sighting(sheep, SimTypes.Species.WOLF, Vector2(550, 500), 99, 120)
	_add_sighting(sheep, SimTypes.Species.WOLF, Vector2(450, 500), 99, 120)
	_compare_refresh(perception, sheep)
	_check(sheep.threat == first, "Equidistant threats keep insertion-order precedence")
	var wolf: AgentContext = _make_context(ai, SimTypes.Species.WOLF, Vector2(500, 500), 100)
	_add_sighting(wolf, SimTypes.Species.DOG, Vector2(500 + ai.settings.dog_risk_radius, 500), 99, 120)
	_compare_refresh(perception, wolf)
	_check(wolf.threat == null, "Dog at the exact risk threshold does not threaten the wolf")
	var dog: AgentContext = _make_context(ai, SimTypes.Species.DOG, Vector2(900, 900), 100)
	dog.protection_anchor = Vector2(500, 500)
	var attacker: LocalObservation = _add_sighting(dog, SimTypes.Species.WOLF, Vector2(550, 500), 99, 120)
	_compare_refresh(perception, dog)
	_check(dog.dog_threat == attacker and dog.protection_anchor == Vector2(500, 500), "Dog retains its prior anchor without valid sheep memories")
	_add_sighting(dog, SimTypes.Species.SHEEP, Vector2(1500, 800), 99, 120)
	_compare_refresh(perception, dog)
	_check(dog.dog_threat == null and dog.protection_anchor == Vector2(1500, 800), "Dog ranks wolf memories against the newly reduced flock anchor")
	sheep.free()
	wolf.free()
	dog.free()
	ai.free()

func _test_shared_refresh_and_reuse() -> void:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	var perception := PerceptionSystem.new()
	var context: AgentContext = _make_context(ai, SimTypes.Species.WOLF, Vector2(500, 500), 100)
	var prey: LocalObservation = _add_sighting(context, SimTypes.Species.SHEEP, Vector2(550, 500), 99, 120)
	context.prey = prey
	var report: LocalObservation = prey.copy_sighting()
	report.observed_tick = 101
	report.expires_tick = 221
	report.position = Vector2(600, 500)
	_check(perception.merge_shared(context, report, 102), "New shared evidence merges without querying live target positions")
	context.current_tick = 102
	_compare_refresh(perception, context)
	_check(context.prey == report and report.last_direct_tick == 99, "Rebuilt prey uses the new report while retaining the receiver's direct marker")
	context.current_tick = 221
	_compare_refresh(perception, context)
	_check(context.prey == null and context.flock_count == 0, "Exact expiry tick removes remembered prey from derived facts")
	ai.store.remove_agent(prey.handle)
	ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(550, 500))
	context.current_tick = 103
	_compare_refresh(perception, context)
	_check(context.flock_count == 0, "A reused slot does not revive stale flock knowledge")
	context.free()
	ai.free()

func _test_cached_shared_updates() -> void:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	var perception := PerceptionSystem.new()
	var context: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100)
	var flock: LocalObservation = _add_sighting(context, SimTypes.Species.SHEEP, Vector2(600, 500), 99, 120)
	var first: LocalObservation = _add_sighting(context, SimTypes.Species.WOLF, Vector2(550, 500), 99, 120)
	# Allocate before warming the cache so lifecycle invalidation cannot conceal
	# missing shared-insertion invalidation or threat-view maintenance.
	var new_sheep: AgentHandle = ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(900, 900))
	var new_wolf: AgentHandle = ai.store.create_agent(SimTypes.Species.WOLF, Vector2(900, 900))
	_compare_refresh(perception, context)
	var revision: int = ai.store.life_revision
	var report: LocalObservation = flock.copy_sighting()
	report.observed_tick = 101
	report.expires_tick = 221
	report.position = Vector2(800, 500)
	_check(perception.merge_shared(context, report, 102), "Existing sheep report merges into a warm cache")
	_check(context.flock_cache_dirty, "Shared sheep replacement invalidates the ordered flock sum")
	context.current_tick = 102
	_compare_refresh(perception, context)
	var inserted := LocalObservation.new()
	inserted.handle = new_sheep
	inserted.species = SimTypes.Species.SHEEP
	inserted.position = Vector2(700, 500)
	inserted.observed_tick = 102
	inserted.expires_tick = 222
	_check(perception.merge_shared(context, inserted, 102), "New sheep observation merges without changing store lifecycle")
	_compare_refresh(perception, context)
	_check(context.flock_count == 3, "New shared sheep contributes to the next flock sum")
	var second := LocalObservation.new()
	second.handle = new_wolf
	second.species = SimTypes.Species.WOLF
	second.position = Vector2(450, 500)
	second.observed_tick = 102
	second.expires_tick = 222
	_check(perception.merge_shared(context, second, 102), "New threat observation merges into a warm view")
	_check(not context.flock_cache_dirty and not context.threat_view_dirty, "Wolf-only shared insertion reuses the flock sum and updates the view directly")
	_compare_refresh(perception, context)
	_check(context.threat == first, "Appended equal-distance threat retains the first dictionary key's precedence")
	var revised_threat: LocalObservation = first.copy_sighting()
	revised_threat.observed_tick = 103
	revised_threat.expires_tick = 223
	revised_threat.position = Vector2(530, 500)
	_check(perception.merge_shared(context, revised_threat, 103), "Existing threat report replaces its view entry")
	context.current_tick = 103
	_compare_refresh(perception, context)
	_check(context.threat == revised_threat, "Threat view holds the newest observation object")
	_check(ai.store.life_revision == revision, "Shared-cache checks run without lifecycle invalidation")
	# Current self position is excluded from the retained flock sum, and threat
	# ranking must use it even when no observation changes.
	ai.store.position_current[ai.store.resolve(context.handle)] = Vector2(460, 500)
	_compare_refresh(perception, context)
	_check(context.threat == second, "Observer movement reranks threats without dirtying observations")
	context.free()
	ai.free()

func _test_cached_lifetime_boundaries() -> void:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	var perception := PerceptionSystem.new()
	var context: AgentContext = _make_context(ai, SimTypes.Species.DOG, Vector2(900, 900), 100)
	var flock: LocalObservation = _add_sighting(context, SimTypes.Species.SHEEP, Vector2(500, 500), 99, 3)
	var first: LocalObservation = _add_sighting(context, SimTypes.Species.WOLF, Vector2(550, 500), 99, 2)
	var second: LocalObservation = _add_sighting(context, SimTypes.Species.WOLF, Vector2(450, 500), 99, 120)
	_compare_refresh(perception, context)
	context.current_tick = 101
	_compare_refresh(perception, context)
	_check(context.dog_threat == second, "An expired first threat is excluded from a cached ordered view")
	var renewed: LocalObservation = first.copy_sighting()
	renewed.observed_tick = 101
	renewed.expires_tick = 221
	_check(perception.merge_shared(context, renewed, 101), "Expired threat can receive a newer report at its existing key")
	_compare_refresh(perception, context)
	_check(context.dog_threat == renewed, "Renewed equal-distance threat preserves its original dictionary precedence")
	context.current_tick = 102
	_compare_refresh(perception, context)
	_check(context.flock_count == 0 and context.protection_anchor == Vector2(500, 500), "Earliest sheep expiration rebuilds count but preserves an empty flock's dog anchor")
	var refreshed_flock: LocalObservation = flock.copy_sighting()
	refreshed_flock.observed_tick = 102
	refreshed_flock.expires_tick = 222
	refreshed_flock.position = Vector2(1000, 500)
	_check(perception.merge_shared(context, refreshed_flock, 102), "Expired flock evidence can become valid again through a shared report")
	_compare_refresh(perception, context)
	_check(context.protection_anchor == Vector2(1000, 500), "Dog threat distances use the refreshed flock anchor")
	ai.store.mark_dead(flock.handle)
	_compare_refresh(perception, context)
	_check(context.flock_count == 0, "Death invalidates cached sheep before its evidence expires")
	ai.store.mark_dead(first.handle)
	_compare_refresh(perception, context)
	context.free()
	ai.free()

func _test_shared_species_replacement() -> void:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	var perception := PerceptionSystem.new()
	var context: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100)
	var old_sheep: LocalObservation = _add_sighting(context, SimTypes.Species.SHEEP, Vector2(550, 500), 99, 120)
	var old_wolf: LocalObservation = _add_sighting(context, SimTypes.Species.WOLF, Vector2(450, 500), 99, 120)
	_compare_refresh(perception, context)
	ai.store.remove_agent(old_sheep.handle)
	var replacement := LocalObservation.new()
	replacement.handle = ai.store.create_agent(SimTypes.Species.WOLF, Vector2(900, 900))
	replacement.species = SimTypes.Species.WOLF
	replacement.position = Vector2(550, 500)
	replacement.observed_tick = 101
	replacement.expires_tick = 221
	_check(replacement.handle.slot == old_sheep.handle.slot, "Cross-species fixture reuses the original slot")
	_check(perception.merge_shared(context, replacement, 101), "Sheep slot can be replaced by a new wolf life")
	context.current_tick = 101
	_compare_refresh(perception, context)
	_check(context.flock_count == 1 and context.threat == replacement, "Sheep-to-wolf replacement changes both caches while preserving original key order")
	ai.store.remove_agent(replacement.handle)
	var sheep_again: LocalObservation = replacement.copy_sighting()
	sheep_again.handle = ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(900, 900))
	sheep_again.species = SimTypes.Species.SHEEP
	sheep_again.observed_tick = 102
	sheep_again.expires_tick = 222
	_check(perception.merge_shared(context, sheep_again, 102), "Wolf slot can be replaced by a new sheep life")
	context.current_tick = 102
	_compare_refresh(perception, context)
	_check(context.flock_count == 2 and context.threat == old_wolf, "Wolf-to-sheep replacement removes the threat and restores its flock contribution")
	context.free()
	ai.free()

func _test_direct_cache_invalidation() -> void:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	ai.grid = SpatialGrid.new()
	var perception := PerceptionSystem.new()
	var context: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100)
	var first: LocalObservation = _add_sighting(context, SimTypes.Species.WOLF, Vector2(550, 500), 99, 2)
	var second: LocalObservation = _add_sighting(context, SimTypes.Species.WOLF, Vector2(450, 500), 99, 120)
	var flock: LocalObservation = _add_sighting(context, SimTypes.Species.SHEEP, Vector2(520, 500), 99, 120)
	_compare_refresh(perception, context)
	ai.store.position_current[ai.store.resolve(first.handle)] = Vector2(1300, 900)
	ai.store.position_current[ai.store.resolve(second.handle)] = Vector2(450, 500)
	ai.store.position_current[ai.store.resolve(flock.handle)] = Vector2(600, 500)
	ai.grid.rebuild(ai.store)
	context.current_tick = 101
	perception.update(context, 101)
	_compare_refresh(perception, context)
	_check(not context.observations.has(first.handle.slot), "Direct prune removes an expired threat outside the current query")
	_check(context.flock_center == Vector2(550, 500), "Direct in-place sheep mutation rebuilds the cached ordered sum")
	_check(context.observations[flock.handle.slot] == flock, "Direct sensing retains and mutates an existing observation object")
	ai.store.position_current[ai.store.resolve(first.handle)] = Vector2(550, 500)
	ai.grid.rebuild(ai.store)
	context.current_tick = 102
	perception.update(context, 102)
	_compare_refresh(perception, context)
	_check(context.threat == second, "A pruned then reinserted threat follows the remaining dictionary keys")
	context.free()
	ai.free()

func _test_clear_runtime_cache() -> void:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	var perception := PerceptionSystem.new()
	var context: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100)
	_add_sighting(context, SimTypes.Species.SHEEP, Vector2(600, 500), 99, 120)
	_add_sighting(context, SimTypes.Species.WOLF, Vector2(550, 500), 99, 120)
	_compare_refresh(perception, context)
	context.clear_runtime()
	_check(context.remembered_flock_sum == Vector2.ZERO and context.remembered_flock_count == 0, "Clearing context removes the retained flock summary")
	_check(context.flock_cache_dirty and context.flock_cache_expires_tick == 0 and context.fact_cache_life_revision == -1, "Clearing context resets cache validity boundaries")
	_check(context.threat_view_dirty and context.threat_observations.is_empty() and context.threat_view_indices.is_empty(), "Clearing context releases ordered threat references")
	_check(context.facts_dirty and context.facts_expire_tick == 0, "Clearing context invalidates decision facts")
	_compare_refresh(perception, context)
	_check(context.flock_count == 1 and context.threat == null, "A reused empty context retains no prior knowledge")
	context.free()
	ai.free()

func _compact_ai() -> AICoordinator:
	var ai := AICoordinator.new()
	ai.store = AgentStore.new()
	ai.config = SimulationConfig.new()
	ai.config.compact_flock_knowledge = true
	ai.config.perception_radius = 180.0
	ai.config.memory_ticks = 120
	ai.grid = SpatialGrid.new()
	return ai

func _test_compact_target_storage() -> void:
	var ai: AICoordinator = _compact_ai()
	var perception := PerceptionSystem.new()
	var sheep: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100, true)
	var dog: AgentContext = _make_context(ai, SimTypes.Species.DOG, Vector2(510, 500), 100, true)
	var wolf: AgentContext = _make_context(ai, SimTypes.Species.WOLF, Vector2(520, 500), 100, true)
	for index: int in 80:
		ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(530 + index % 10, 480 + index / 10))
	ai.store.create_agent(SimTypes.Species.WOLF, Vector2(540, 500))
	ai.store.create_agent(SimTypes.Species.DOG, Vector2(550, 500))
	ai.grid.rebuild(ai.store)
	perception.update(sheep, 100)
	perception.update(dog, 100)
	perception.update(wolf, 100)
	_check(sheep.observations.size() == 2 and dog.observations.size() == 2, "Dense sheep and dog knowledge retains exact wolf targets only")
	_check(sheep.flock_count == 81 and dog.flock_count == 81, "Compact flock statistics include the sheep observer exactly once")
	_check(wolf.observations.size() == 83 and wolf.flock_count == 81, "Wolf keeps individual sheep and dog knowledge without packmate copies")
	_check(sheep.last_perception_tick == 100 and dog.last_perception_tick == 100 and wolf.last_perception_tick == 100, "Target scans retain one direct visibility timestamp")
	for sighting: LocalObservation in sheep.observations.values():
		_check(sighting.species == SimTypes.Species.WOLF, "Sheep target knowledge excludes flock identities")
	for sighting: LocalObservation in wolf.observations.values():
		_check(sighting.species != SimTypes.Species.WOLF and sighting.last_direct_tick == 100, "Wolf action targets retain direct provenance")
	sheep.free()
	dog.free()
	wolf.free()
	ai.free()

func _test_compact_sample_lifetime() -> void:
	var ai: AICoordinator = _compact_ai()
	var perception := PerceptionSystem.new()
	var sheep: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100, true)
	var dog: AgentContext = _make_context(ai, SimTypes.Species.DOG, Vector2(500, 520), 100, true)
	var companion: AgentHandle = ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(600, 500))
	var attacker: AgentHandle = ai.store.create_agent(SimTypes.Species.WOLF, Vector2(530, 500))
	ai.grid.rebuild(ai.store)
	perception.update(sheep, 100)
	perception.update(dog, 100)
	_check(sheep.flock_sample_center == Vector2(550, 500) and dog.protection_anchor == Vector2(500, 500), "Sheep retain the whole local center while the dog selects one occupied visible region")
	ai.store.position_current[ai.store.resolve(sheep.handle)] = Vector2(510, 500)
	ai.store.position_current[ai.store.resolve(companion)] = Vector2(1400, 900)
	var candidates_before: int = ai.grid.candidate_count
	var merges_before: int = ai.grid.aggregated_cell_count
	perception.prepare_decision(sheep, 101)
	_check(sheep.flock_center == Vector2(550, 500), "Observer and hidden member movement cannot rewrite a live historical sample")
	ai.store.mark_dead(companion)
	perception.prepare_decision(sheep, 102)
	_check(sheep.flock_count == 2 and sheep.flock_center == Vector2(550, 500), "A lifecycle revision does not resample hidden flock membership")
	var report: LocalObservation = sheep.observations[attacker.slot].copy_sighting()
	report.observed_tick = 110
	report.expires_tick = 230
	report.position = Vector2(540, 500)
	_check(perception.merge_shared(sheep, report, 110), "Compact threat sharing updates exact target evidence")
	perception.refresh_shared_facts(sheep, 110)
	_check(sheep.flock_sample_observed_tick == 100 and sheep.flock_sample_expires_tick == 220, "Threat sharing cannot extend or rewrite the flock sample lifetime")
	perception.prepare_decision(sheep, 219)
	_check(sheep.flock_count == 2, "The flock sample remains usable immediately before its deadline")
	perception.prepare_decision(sheep, 220)
	perception.prepare_decision(dog, 220)
	_check(sheep.flock_count == 1 and sheep.flock_center == Vector2(510, 500), "At exact expiry a sheep knows only its own current position")
	_check(dog.flock_count == 0 and dog.protection_anchor == Vector2(500, 500), "At exact expiry a dog retains its last protection anchor without a live flock count")
	_check(sheep.threat == report and sheep.last_perception_tick == 100, "Flock expiry preserves independently valid threat knowledge and its scan marker")
	ai.store.position_current[ai.store.resolve(sheep.handle)] = Vector2(515, 500)
	perception.prepare_decision(sheep, 221)
	_check(sheep.flock_center == Vector2(515, 500), "An expired sheep sample follows only the observer on subsequent decisions")
	_check(ai.grid.candidate_count == candidates_before and ai.grid.aggregated_cell_count == merges_before, "Decision freshness and shared evidence perform no spatial queries")
	sheep.clear_runtime()
	_check(sheep.flock_sample_count == 0 and sheep.flock_sample_center == Vector2.ZERO and sheep.flock_sample_observed_tick == -1 and sheep.flock_sample_expires_tick == 0, "Runtime recycling clears every flock sample field")
	sheep.free()
	dog.free()
	ai.free()

func _test_compact_sample_replacement() -> void:
	var ai: AICoordinator = _compact_ai()
	var perception := PerceptionSystem.new()
	var near_sheep: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(500, 500), 100, true)
	var far_sheep: AgentContext = _make_context(ai, SimTypes.Species.SHEEP, Vector2(1100, 500), 100, true)
	var companion: AgentHandle = ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(600, 500))
	ai.grid.rebuild(ai.store)
	perception.update(near_sheep, 100)
	perception.update(far_sheep, 100)
	_check(near_sheep.flock_sample_count == 2 and near_sheep.flock_sample_center == Vector2(550, 500), "A second observer cannot mutate the first observer's copied sample")
	_check(far_sheep.flock_sample_count == 1 and far_sheep.flock_sample_center == Vector2(1100, 500), "Each observer owns its own local flock sample")
	ai.store.position_current[ai.store.resolve(companion)] = Vector2(1150, 500)
	ai.grid.rebuild(ai.store)
	perception.update(near_sheep, 101)
	_check(near_sheep.flock_count == 1 and near_sheep.flock_center == Vector2(500, 500), "A new scan replaces the whole flock sample instead of merging past members")
	_check(far_sheep.flock_sample_count == 1 and far_sheep.flock_sample_observed_tick == 100, "Other observers keep their prior sample until they scan")
	var unsupported := LocalObservation.new()
	unsupported.handle = companion
	unsupported.species = SimTypes.Species.SHEEP
	unsupported.position = Vector2(600, 500)
	unsupported.observed_tick = 101
	unsupported.expires_tick = 221
	_check(not perception.merge_shared(near_sheep, unsupported, 101) and near_sheep.observations.is_empty(), "Compact flock reports cannot rebuild individual companion memories")
	near_sheep.free()
	far_sheep.free()
	ai.free()

func _test_compact_wolf_memory() -> void:
	var ai: AICoordinator = _compact_ai()
	var perception := PerceptionSystem.new()
	var wolf: AgentContext = _make_context(ai, SimTypes.Species.WOLF, Vector2(500, 500), 100, true)
	var sheep: AgentHandle = ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(550, 500))
	ai.store.create_agent(SimTypes.Species.DOG, Vector2(530, 500))
	ai.grid.rebuild(ai.store)
	perception.update(wolf, 100)
	var prey: LocalObservation = wolf.observations[sheep.slot]
	wolf.prey = prey
	ai.store.position_current[ai.store.resolve(sheep)] = Vector2(1300, 900)
	ai.grid.rebuild(ai.store)
	perception.update(wolf, 101)
	_check(wolf.prey == prey and wolf.flock_center == Vector2(550, 500) and wolf.flock_count == 1, "Wolf retains exact remembered prey after it leaves current sight")
	var report: LocalObservation = prey.copy_sighting()
	report.observed_tick = 102
	report.expires_tick = 222
	report.position = Vector2(600, 500)
	_check(perception.merge_shared(wolf, report, 102), "Compact wolves continue accepting shared prey identities")
	perception.prepare_decision(wolf, 102)
	_check(wolf.prey == report and wolf.flock_center == Vector2(600, 500) and report.last_direct_tick == 100, "Shared prey refreshes wolf facts without revealing hidden current positions")
	perception.prepare_decision(wolf, 222)
	_check(wolf.prey == null and wolf.flock_count == 0, "Wolf memory-derived flock facts expire on their original target deadlines")
	wolf.free()
	ai.free()

# Snapshot oracle retained only in tests; production has a single reducer.
func _reference_refresh(context: AgentContext, tick: int) -> void:
	var ai: AICoordinator = context.coordinator
	var refresh_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
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
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.REFRESH, Time.get_ticks_usec() - refresh_start)

