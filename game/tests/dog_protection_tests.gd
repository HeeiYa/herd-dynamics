extends SceneTree
## Diagnostic geometry and evidence contracts. Manually constructed CPU states
## below are fixtures, never evidence that an autonomous production dog passed.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)

func _run() -> void:
	_check_arguments()
	_check_layouts()
	_check_opportunity_boundaries()
	_check_registration_and_preflight()
	_check_actual_risk_boundary()
	_check_authoritative_evidence()
	_check_progress_and_denominators()
	_check_recovery_summary()
	_check_anchor_arguments_and_geometry()
	_check_anchor_subjects_and_peer_evidence()
	_check_anchor_atomic_peer_risk()
	print("DOG_PROTECTION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_arguments() -> void:
	var runs: Array[Dictionary] = ProductionDogProtectionGeometry.first_runs()
	_check(runs.size() == 5, "The first batch contains exactly five predeclared configurations")
	for run: Dictionary in runs:
		var arguments := PackedStringArray(["--dog-geometry=" + run["geometry"], "--sheep=" + str(run["sheep"]), "--seed=" + str(run["seed"])])
		_check(ProductionDogProtectionGeometry.argument_error(arguments, "dog-protection", run["sheep"], run["seed"]).is_empty(), "Each declared run passes exact CLI validation")
		_check(ProductionDogProtectionGeometry.variant_name(ProductionDogProtectionGeometry.from_arguments(arguments)) == run["geometry"], "Geometry survives parsing without an implicit fallback")
	_check(ProductionDogProtectionGeometry.argument_error(PackedStringArray(), "two-flocks", 300, 123).is_empty(), "Existing protocols keep their original count and seed scope")
	_check(ProductionDogProtectionGeometry.argument_error(PackedStringArray(), "dog-protection", 80, 42).is_empty(), "The default is the declared small normal control")
	var invalid: Array[PackedStringArray] = [
		PackedStringArray(["--dog-geometry=unknown"]),
		PackedStringArray(["--dog-geometry=normal", "--dog-geometry=normal"]),
		PackedStringArray(["--dog-geometery=normal"]),
		PackedStringArray(["--sheep=80junk"]),
		PackedStringArray(["--seed=42oops"]),
		PackedStringArray(["--seed=42", "--seed=42"]),
		PackedStringArray(["--sheep=80", "--sheep=80"]),
	]
	for arguments: PackedStringArray in invalid:
		_check(not ProductionDogProtectionGeometry.argument_error(arguments, "dog-protection", 80, 42).is_empty(), "Malformed or duplicate options cannot silently select a valid run")
	_check(not ProductionDogProtectionGeometry.argument_error(PackedStringArray(["--dog-geometry=normal"]), "two-flocks", 80, 42).is_empty(), "Another case cannot silently ignore the new flag")
	_check(not ProductionDogProtectionGeometry.argument_error(PackedStringArray(), "dog-protection", 1000, 42).is_empty(), "The unplanned thousand-sheep normal case is rejected")
	_check(not ProductionDogProtectionGeometry.argument_error(PackedStringArray(["--dog-geometry=oblique"]), "dog-protection", 1000, 43).is_empty(), "The first batch does not silently expand its thousand-sheep seed matrix")

func _check_layouts() -> void:
	var small := ProductionDogProtectionGeometry.new()
	var large := ProductionDogProtectionGeometry.new()
	small.prepare(80, 42)
	large.prepare(1000, 42)
	_check(small.positions.size() == 84 and large.positions.size() == 1004, "Total sheep counts include the fixed80 and exclude the four dogs")
	_check(small.positions == large.positions.slice(0, 84), "Adding background preserves every foreground coordinate and RNG prefix")
	_check(small.species == large.species.slice(0, 84), "Foreground creation order and species remain fixed across populations")
	var settings := SimulationConfig.new()
	settings.world_size = Vector2(2400, 1400)
	for run: Dictionary in ProductionDogProtectionGeometry.first_runs():
		var layout := ProductionDogProtectionGeometry.new()
		layout.prepare(run["sheep"], run["seed"])
		_check(layout.initial_error(settings.agent_radius, settings.world_size).is_empty(), "Every declared initial layout has full in-bounds nonoverlapping bodies")
	var background_outside: bool = true
	for index: int in range(84, large.positions.size()):
		background_outside = background_outside and not ProductionDogProtectionGeometry.inside_foreground_region(large.positions[index])
	_check(background_outside, "Every extra sheep starts outside the declared foreground regions")
	var original: Vector2 = small.positions[0]
	small.positions[0] = Vector2(12, 700)
	_check(not small.initial_error(13.0, settings.world_size).is_empty(), "Initial body clipping is an invalid fixture, not a silent stage0 clamp")
	small.positions[0] = small.positions[1]
	_check(not small.initial_error(13.0, settings.world_size).is_empty(), "Initial overlap is rejected")
	small.positions[0] = Vector2(NAN, 700)
	_check(not small.initial_error(13.0, settings.world_size).is_empty(), "Nonfinite initial geometry fails")
	small.positions[0] = original

func _check_opportunity_boundaries() -> void:
	var dogs: Array[Vector2] = [Vector2(570, 560), Vector2(630, 560)]
	var anchors: Array[Vector2] = dogs.duplicate()
	for variant: ProductionDogProtectionGeometry.Variant in [ProductionDogProtectionGeometry.Variant.NORMAL, ProductionDogProtectionGeometry.Variant.OBLIQUE]:
		var wolf: Vector2 = ProductionDogProtectionGeometry.wolf_position(dogs[0], dogs[1], variant)
		_check(is_equal_approx(wolf.distance_to(Vector2(600, 560)), 140.0), "Both declared directions use the same finite midpoint distance")
		_check(ProductionDogProtectionGeometry.opportunity_error(wolf, dogs, anchors, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "Reference geometry starts beyond passive risk but inside true perception and protection")
	var coincident: Array[Vector2] = [Vector2(600, 560), Vector2(600, 560)]
	_check(not ProductionDogProtectionGeometry.opportunity_error(Vector2(705, 560), coincident, coincident, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "Exact risk radius is excluded from stimulus eligibility")
	_check(ProductionDogProtectionGeometry.opportunity_error(Vector2(780, 560), coincident, coincident, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "Exact perception radius remains included")
	var far_anchors: Array[Vector2] = [Vector2(580, 560), Vector2(580, 560)]
	_check(not ProductionDogProtectionGeometry.opportunity_error(Vector2(780, 560), coincident, far_anchors, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "Exact protection radius is excluded, matching the actual task")
	_check(not ProductionDogProtectionGeometry.opportunity_error(Vector2(12, 560), dogs, anchors, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "Whole wolf bodies must fit before registration")
	_check(not ProductionDogProtectionGeometry.opportunity_error(Vector2(NAN, 560), dogs, anchors, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "Nonfinite stimulus positions fail before world commands")

func _new_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	return world

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _registered(world: SimulationWorld, variant: ProductionDogProtectionGeometry.Variant = ProductionDogProtectionGeometry.Variant.NORMAL) -> ProductionDogProtectionProbe:
	var probe := ProductionDogProtectionProbe.new()
	probe.geometry_variant = variant
	probe.setup(world, 80, 42)
	_check(world.store.count == 0, "Setup queues ordinary stage0 placements")
	world._apply_commands()
	probe.observe_step_start(world)
	return probe

## Test-only knowledge construction isolates preflight rules. No production
## protocol calls this, and these states are not autonomous behavior evidence.
func _fixture_flock_samples(world: SimulationWorld, probe: ProductionDogProtectionProbe) -> void:
	for dog: AgentHandle in probe._dogs:
		var context: AgentContext = world.ai.inspect(dog)
		context.flock_count = 2
		context.flock_sample_count = 2
		context.flock_sample_observed_tick = 239
		context.flock_sample_expires_tick = 269
		context.protection_anchor = world.store.position_current[world.store.resolve(dog)]

func _check_registration_and_preflight() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionDogProtectionProbe = _registered(world)
	_check(probe._cohort.size() == 80 and probe._dogs.size() == 4 and probe._wolves.is_empty(), "Only the declared foreground sheep and dogs exist before the stimulus")
	_check(world.counts() == PackedInt32Array([80, 0, 4]), "Stage0 preserves exact species totals")
	world.tick = 240
	probe.before_step(world)
	_check(probe.finished and not probe.finish_report()["fixture_valid"], "Without genuine prior sample evidence preflight fails rather than forcing dog knowledge")
	var missing_sample: Dictionary = probe.finish_report()["fixture_error_details"]
	_check(missing_sample["dog"] == probe._dogs[0].key() and missing_sample["current_sample_observed_tick"] == -1 and missing_sample["input_tick"] == 240, "Missing-sample rejection identifies the exact dog and its unmodified observation provenance")
	_check(world.counts()[SimTypes.Species.WOLF] == 0 and not world.has_pending_observer_commands(), "A failed preflight cannot enqueue a partial wolf batch")
	_close(world)
	world = _new_world()
	probe = _registered(world)
	_fixture_flock_samples(world, probe)
	world.tick = 240
	probe.before_step(world)
	_check(not probe.finished and world.counts()[SimTypes.Species.WOLF] == 0, "Successful preflight still defers actual spawning to stage0")
	world._apply_commands()
	probe.observe_step_start(world)
	_check(probe._wolves.size() == 2 and probe._records.size() == 6, "Two independent wolves register with complete lives")
	var dog_exposed: int = 0
	var wolf_risk_exposed: int = 0
	for record: ProductionDogProtectionTrace in probe._records:
		if record.species == SimTypes.Species.DOG:
			dog_exposed += int(record.eligible_tick == 240 and record.protected_geometry_ticks == 1)
		else:
			wolf_risk_exposed += int(record.eligible_tick >= 0)
	_check(dog_exposed == 4 and wolf_risk_exposed == 0, "All four dogs have geometric opportunity without manufacturing passive-risk exposure for wolves")
	world.tick = 600
	probe.before_step(world)
	_check(world.counts()[SimTypes.Species.WOLF] == 2, "Threat removal also waits for normal stage0")
	world._apply_commands()
	_check(world.counts() == PackedInt32Array([80, 0, 4]), "Removing wolves preserves the fixed sheep and all dogs")
	_close(world)
	world = _new_world()
	probe = _registered(world)
	_fixture_flock_samples(world, probe)
	world.queue_place(SimTypes.Species.SHEEP, Vector2(600, 420))
	world._apply_commands()
	var blocker: AgentHandle = world.store.handle_at(world.store.count - 1)
	world.tick = 240
	probe.before_step(world)
	_check(probe.finished and probe.finish_report()["fixture_error"] == "A requested wolf overlaps a real active body", "Runtime overlap checks include real animals outside the observed cohort")
	var conflict: Dictionary = probe.finish_report()["fixture_error_details"]
	_check(conflict["blocker"] == blocker.key() and conflict["blocker_x"] == 600 and conflict["blocker_y"] == 420 and conflict["distance"] == 0.0, "Collision failure keeps the complete blocker life and actual geometry even outside the detailed cohort")
	_check(not world.has_pending_observer_commands(), "The second-stage batch validation is atomic even after both wolf positions were computed")
	_close(world)

func _check_authoritative_evidence() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionDogProtectionProbe = _registered(world)
	_fixture_flock_samples(world, probe)
	world.tick = 240
	probe.before_step(world)
	world._apply_commands()
	probe.observe_step_start(world)
	var dog: AgentHandle = probe._dogs[0]
	var wolf: AgentHandle = probe._wolves[0]
	var context: AgentContext = world.ai.inspect(dog)
	context.task_token = 17
	var sighting := LocalObservation.new()
	sighting.handle = wolf
	sighting.species = SimTypes.Species.WOLF
	sighting.position = world.store.position_current[world.store.resolve(wolf)]
	sighting.observed_tick = 240
	sighting.expires_tick = 260
	context.observations[wolf.slot] = sighting
	var lease := CoordinationSystem.Lease.new()
	lease.actor = dog
	lease.target = wolf
	lease.kind = CoordinationSystem.Kind.DEFEND
	lease.owner_token = 17
	lease.expires_tick = 270
	var intent := MotionIntent.new()
	intent.actor = dog
	intent.target = wolf
	intent.owner_token = 17
	intent.expires_tick = 250
	intent.behavior = SimTypes.Behavior.INTERCEPT
	_check(ProductionDogProtectionProbe.valid_defend_evidence(world, context, intent, lease, 249), "Matching complete life, owner, lease and historical knowledge qualify")
	_check(not ProductionDogProtectionProbe.valid_defend_evidence(world, context, intent, lease, 250), "An intent expiring exactly now cannot count toward qualified motion")
	var wrong_owner: MotionIntent = intent.publication_copy()
	wrong_owner.owner_token = 16
	_check(not ProductionDogProtectionProbe.valid_defend_evidence(world, context, wrong_owner, lease, 240), "Old owner motion cannot be relabeled as current intercept evidence")
	var wrong_life: MotionIntent = intent.publication_copy()
	wrong_life.target = AgentHandle.new(wolf.slot, wolf.generation + 1, wolf.world_epoch)
	_check(not ProductionDogProtectionProbe.valid_defend_evidence(world, context, wrong_life, lease, 240), "Same slot with a different generation is not the declared wolf")
	var guard: MotionIntent = intent.publication_copy()
	guard.behavior = SimTypes.Behavior.GUARD
	_check(not ProductionDogProtectionProbe.valid_defend_evidence(world, context, guard, lease, 240), "Guarding under a lease is not active intercept progress")
	context.protection_anchor += Vector2(0, 400)
	_check(not ProductionDogProtectionProbe.valid_defend_evidence(world, context, intent, lease, 240), "A valid old wolf observation outside the new local protection region is visible as lost opportunity")
	context.protection_anchor -= Vector2(0, 400)
	world.queue_remove(wolf)
	world._apply_commands()
	world.queue_place(SimTypes.Species.WOLF, Vector2(600, 420))
	world._apply_commands()
	_check(not ProductionDogProtectionProbe.valid_defend_evidence(world, context, intent, lease, 240), "A reused slot cannot revive the old target, lease or recorded knowledge")
	_close(world)

func _check_actual_risk_boundary() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionDogProtectionProbe = _registered(world)
	world.queue_place(SimTypes.Species.WOLF, Vector2(570, 455))
	world._apply_commands()
	var wolf: AgentHandle = world.store.handle_at(world.store.count - 1)
	probe._wolves.append(wolf)
	probe._add_record(wolf, SimTypes.Species.WOLF, 0)
	world.tick = 240
	var wolf_record: ProductionDogProtectionTrace = probe._records.back()
	wolf_record.previous_position = Vector2(570, 455)
	probe._observe_geometry(wolf_record, world.ai.inspect(wolf))
	_check(wolf_record.eligible_tick < 0 and wolf_record.start_nearest_target == null, "Actual wolf-risk denominator excludes exactly105px, matching production perception")
	world.store.relocate(wolf, Vector2(570, 455.001))
	wolf_record.previous_position = Vector2(570, 455.001)
	probe._observe_geometry(wolf_record, world.ai.inspect(wolf))
	_check(wolf_record.eligible_tick == 240 and wolf_record.start_nearest_target.same_life(probe._dogs[0]), "A point strictly inside risk range enters the real geometric denominator")
	world.store.relocate(wolf, Vector2(570, 380))
	var dog_record: ProductionDogProtectionTrace = probe._records[0]
	dog_record.previous_position = Vector2(570, 560)
	probe._observe_geometry(dog_record, world.ai.inspect(dog_record.handle))
	_check(dog_record.eligible_tick == 240 and dog_record.start_nearest_target.same_life(wolf), "Actual dog exposure still includes exactly180px")
	world.store.relocate(wolf, Vector2(570, 379.999))
	world.tick = 241
	probe._observe_geometry(dog_record, world.ai.inspect(dog_record.handle))
	_check(dog_record.start_nearest_target == null and dog_record.exposure_last_end_tick == 241, "Outside dog perception closes the original exposure episode")
	_close(world)

func _check_progress_and_denominators() -> void:
	var record := ProductionDogProtectionTrace.new()
	record.handle = AgentHandle.new(0, 1, 2)
	record.species = SimTypes.Species.DOG
	var intent := MotionIntent.new()
	intent.destination = Vector2(100, 0)
	intent.behavior = SimTypes.Behavior.INTERCEPT
	var position := Vector2.ZERO
	for step: int in 4:
		record.previous_position = position
		position += Vector2((step + 1) * 4.0 / 60.0, 0)
		record.record_motion(intent, position, 388 + step, step * 10000, true)
	_check(is_equal_approx(record.intended_progress, 2.0 / 3.0), "Four acceleration steps retain their actual fractional displacement")
	_check(record.motion_tick < 0 and record.lease_motion_tick < 0, "0.667px remains below the unchanged 1px threshold")
	_check(record.decision_tick == 388 and record.qualified_intercept_ticks == 4, "Decision and finite qualified opportunity remain visible despite no threshold success")
	record.previous_position = position
	record.record_motion(intent, position - Vector2(2, 0), 392, 50000, true)
	_check(is_equal_approx(record.intended_progress, 2.0 / 3.0), "Opposite displacement does not count as intended progress")
	record.previous_position = position
	record.record_motion(intent, position + Vector2(0.4, 0), 393, 60000, false)
	_check(record.motion_tick == 394 and record.lease_motion_tick < 0, "Broad motion and the narrower matching-lease result are not silently conflated")
	var rows: Array[Dictionary] = []
	for index: int in 4:
		var dog := ProductionDogProtectionTrace.new()
		dog.handle = AgentHandle.new(index, 1, 2)
		dog.species = SimTypes.Species.DOG
		dog.eligible_tick = 240
		if index < 2:
			dog.decision_tick = 245
			dog.motion_tick = 250
		else:
			dog.guard_without_lease_ticks = 300
		rows.append(dog.to_dictionary())
	var summary: Dictionary = ProductionBehaviorTrace.summarize(rows, "dog_intercept")
	_check(summary["cohort"] == 4 and summary["eligible"] == 4 and summary["responded"] == 2 and summary["unresponded_alive"] == 2, "Two correct reserve-free guards remain in the broad denominator; they are not deleted to manufacture a 2/2 success rate")
	_check(rows[2]["guard_without_lease_ticks"] == 300, "The same nonchaser retains separate positive guard evidence")

func _check_recovery_summary() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionDogProtectionProbe = _registered(world)
	var record: ProductionDogProtectionTrace = probe._records[0]
	var context: AgentContext = world.ai.inspect(record.handle)
	var position: Vector2 = world.store.position_current[world.store.resolve(record.handle)]
	context.task_token = 17
	context.flock_count = 2
	context.flock_sample_count = 2
	context.flock_sample_observed_tick = 599
	context.flock_sample_expires_tick = 630
	context.protection_anchor = position
	record.start_anchor = position
	record.previous_position = position
	record.start_current_flock = true
	var intent := MotionIntent.new()
	intent.actor = record.handle
	intent.owner_token = 17
	intent.expires_tick = 690
	intent.behavior = SimTypes.Behavior.GUARD
	intent.destination = position
	probe._observe_dog(record, context, intent, position, 600, 1000, false)
	var rows: Array[Dictionary] = [record.to_dictionary()]
	var summary: Dictionary = ProductionBehaviorTrace.summarize(rows, "dog_intercept")
	_check(record.recovery_tick == 601 and record.recovery_v2_tick == 601 and record.recovery_v2_kind == "DOG_GUARD", "The actual local GUARD endpoint updates both published recovery definitions")
	_check(summary["recovery_eligible"] == 1 and summary["recovered"] == 1 and summary["recovered_v2"] == 1 and summary["unrecovered_alive_v2"] == 0, "One recovered dog cannot also be counted as alive-but-unrecovered by the reused summary")
	_check(not record.return_needed and record.return_motion_pixels == 0.0, "Already guarding is valid recovery without manufactured return movement")
	var expired := ProductionDogProtectionTrace.new()
	expired.handle = record.handle
	expired.species = SimTypes.Species.DOG
	expired.previous_position = position
	expired.start_anchor = position
	probe._observe_dog(expired, context, intent, position, 630, 2000, false)
	_check(expired.recovery_tick < 0 and expired.recovery_v2_tick < 0, "Expired protection knowledge cannot manufacture either recovery result")
	var unowned := ProductionDogProtectionTrace.new()
	unowned.handle = record.handle
	unowned.species = SimTypes.Species.DOG
	unowned.previous_position = position
	unowned.start_anchor = position
	var old_intent: MotionIntent = intent.publication_copy()
	old_intent.owner_token = 16
	probe._observe_dog(unowned, context, old_intent, position, 600, 3000, false)
	_check(unowned.recovery_tick < 0 and unowned.recovery_v2_tick < 0, "An old owner cannot supply a current recovery endpoint")
	_close(world)

func _check_anchor_arguments_and_geometry() -> void:
	var runs: Array[Dictionary] = ProductionDogProtectionGeometry.anchor_runs()
	_check(runs.size() == 5 and ProductionDogProtectionGeometry.first_runs().size() == 5, "The second predeclared matrix supplements rather than replaces the five original runs")
	for run: Dictionary in runs:
		var arguments := PackedStringArray(["--dog-geometry=" + run["geometry"], "--sheep=" + str(run["sheep"]), "--seed=" + str(run["seed"])])
		var variant: ProductionDogProtectionGeometry.Variant = ProductionDogProtectionGeometry.from_arguments(arguments)
		_check(ProductionDogProtectionGeometry.argument_error(arguments, "dog-protection", run["sheep"], run["seed"]).is_empty(), "Each of the five anchor combinations is explicit and valid")
		_check(ProductionDogProtectionGeometry.variant_name(variant) == run["geometry"] and ProductionDogProtectionGeometry.protocol_version(variant) == ProductionDogProtectionGeometry.ANCHOR_VERSION, "Anchor variants keep their own v2 protocol identity")
	_check(ProductionDogProtectionGeometry.from_arguments(PackedStringArray()) == ProductionDogProtectionGeometry.Variant.NORMAL, "Omitting geometry still chooses the original paired protocol")
	_check(ProductionDogProtectionGeometry.protocol_version(ProductionDogProtectionGeometry.Variant.OBLIQUE) == ProductionDogProtectionGeometry.VERSION, "Original oblique evidence still names v1")
	_check(not ProductionDogProtectionGeometry.argument_error(PackedStringArray(["--dog-geometry=anchor-normal"]), "dog-protection", 80, 43).is_empty(), "New geometry cannot silently expand its declared seed matrix")
	_check(not ProductionDogProtectionGeometry.argument_error(PackedStringArray(["--dog-geometry=anchor-oblique", "--dog-geometry=anchor-normal"]), "dog-protection", 80, 42).is_empty(), "Conflicting new variants are rejected without last-value wins")
	var subject := Vector2(600, 600)
	var anchor := Vector2(700, 600)
	var normal: Vector2 = ProductionDogProtectionGeometry.anchor_wolf_position(subject, anchor, ProductionDogProtectionGeometry.Variant.ANCHOR_NORMAL)
	var oblique: Vector2 = ProductionDogProtectionGeometry.anchor_wolf_position(subject, anchor, ProductionDogProtectionGeometry.Variant.ANCHOR_OBLIQUE)
	_check(normal == Vector2(740, 600), "Anchor-normal is exactly140px toward the one declared historical anchor")
	_check(oblique.is_equal_approx(subject + Vector2(140, 0).rotated(PI / 9.0)), "Anchor-oblique applies the one predeclared positive20degree rotation")
	_check(ProductionDogProtectionGeometry.anchor_wolf_position(subject, subject, ProductionDogProtectionGeometry.Variant.ANCHOR_NORMAL) == Vector2(600, 460), "A zero reference direction uses fixedUP without searching")
	_check(ProductionDogProtectionGeometry.anchor_wolf_position(subject, subject, ProductionDogProtectionGeometry.Variant.ANCHOR_OBLIQUE).is_equal_approx(subject + Vector2.UP.rotated(PI / 9.0) * 140.0), "The zero-direction oblique fallback also keeps the exact declared rotation")
	_check(ProductionDogProtectionGeometry.subject_opportunity_error(normal, subject, anchor, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "The fixed subject has real unchanged perception and protection opportunity")
	var dogs: Array[Vector2] = [subject, Vector2(600, 620)]
	var anchors: Array[Vector2] = [anchor, Vector2(1000, 1000)]
	_check(not ProductionDogProtectionGeometry.opportunity_error(normal, dogs, anchors, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "The same different-anchor peer remains invalid under the original paired contract")
	_check(not ProductionDogProtectionGeometry.subject_opportunity_error(Vector2(705, 600), subject, anchor, 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "The new subject preflight does not relax the105px exclusion")
	_check(not ProductionDogProtectionGeometry.subject_opportunity_error(Vector2(740, 600), subject, Vector2(940, 600), 13, Vector2(2400, 1400), 105, 180, 200).is_empty(), "The new subject preflight does not relax the200px strict protection boundary")

func _check_anchor_subjects_and_peer_evidence() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionDogProtectionProbe = _registered(world, ProductionDogProtectionGeometry.Variant.ANCHOR_NORMAL)
	_fixture_flock_samples(world, probe)
	_check(probe._subjects.size() == 2 and probe._peers.size() == 2 and probe._subjects[0].same_life(probe._dogs[0]) and probe._subjects[1].same_life(probe._dogs[2]), "Opportunity identities are fixed by original registration order before outcomes")
	for peer: AgentHandle in probe._peers:
		var context: AgentContext = world.ai.inspect(peer)
		context.flock_count = 0
		context.flock_sample_count = 0
		context.flock_sample_expires_tick = 1
	world.tick = 240
	probe.before_step(world)
	_check(not probe.finished and world.counts()[SimTypes.Species.WOLF] == 0, "Peers need not share a current protection sample, and a passing batch still waits for stage0")
	world._apply_commands()
	probe.observe_step_start(world)
	var report: Dictionary = probe.finish_report()
	_check(report["fixture_valid"] and report["protocol"] == ProductionDogProtectionGeometry.ANCHOR_VERSION and report["registered_wolves"] == 2, "The actual two-wolf registration is separately labeled v2")
	_check(report["outcomes"][0]["cohort"] == 4 and report["subject_outcomes"]["cohort"] == 2 and report["peer_outcomes"]["cohort"] == 2, "Four-dog, fixed-subject and peer denominators coexist without removing nonchasers")
	_check(report["registered_opportunity_subjects"] == [probe._dogs[0].key(), probe._dogs[2].key()], "The report transfers the exact predeclared subject lives")
	_check(report["preflight"][1]["declared_role"] == "peer" and not report["preflight"][1]["current_sample_required"] and not report["preflight"][1]["current_sample_valid"], "A peer's missing sample is retained as evidence instead of being hidden or rewritten")
	_close(world)
	world = _new_world()
	probe = _registered(world, ProductionDogProtectionGeometry.Variant.ANCHOR_NORMAL)
	_fixture_flock_samples(world, probe)
	var subject_context: AgentContext = world.ai.inspect(probe._dogs[0])
	subject_context.flock_sample_expires_tick = 240
	world.tick = 240
	probe.before_step(world)
	report = probe.finish_report()
	_check(not report["fixture_valid"] and report["fixture_error_details"]["dog"] == probe._dogs[0].key(), "A missing subject sample cannot silently transfer opportunity to the valid peer")
	_check(not world.has_pending_observer_commands(), "Subject failure leaves no partial stimulus batch")
	_close(world)

func _check_anchor_atomic_peer_risk() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionDogProtectionProbe = _registered(world, ProductionDogProtectionGeometry.Variant.ANCHOR_NORMAL)
	_fixture_flock_samples(world, probe)
	var peer: AgentHandle = probe._peers[0]
	world.store.relocate(peer, Vector2(620, 420))
	world.tick = 240
	probe.before_step(world)
	var report: Dictionary = probe.finish_report()
	_check(not report["fixture_valid"] and report["fixture_error"] == "A requested wolf starts inside another dog's risk radius", "A subject-valid point still fails when it starts within a peer's105px risk circle")
	_check(report["fixture_error_details"]["blocker"] == peer.key() and report["fixture_error_details"]["distance"] == 50.0, "The retained peer is the exact blocker, not a missing-subject or arbitrary overlap diagnosis")
	_check(report["requested_wolf_positions"].size() == 2 and world.counts()[SimTypes.Species.WOLF] == 0 and not world.has_pending_observer_commands(), "Both positions are checked atomically; one peer conflict never launches the other wolf alone")
	_close(world)
