extends SceneTree
## Deterministic diagnostic contracts. Relocations below are test fixtures,
## not autonomous behavior evidence or alternate production policies.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _run() -> void:
	_check_arguments()
	_check_positions()
	_check_registration_and_identity()
	_check_initial_rejection()
	_check_runtime_rejection()
	_check_successful_atomic_registration()
	print("HUNT_COHORT_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _argument_error(arguments: PackedStringArray, behavior_case: String, total: int, seed_value: int) -> String:
	var error: String = ProductionHuntGeometry.argument_error(arguments, behavior_case, total)
	if not error.is_empty():
		return error
	return ProductionHuntCohort.argument_error(arguments, behavior_case, total, seed_value)

func _check_arguments() -> void:
	_check(ProductionHuntCohort.from_arguments(PackedStringArray()) == ProductionHuntCohort.Layout.ORIGINAL, "Missing layout keeps the old protocol")
	for total: int in [80, 1000]:
		for geometry: String in ["north", "oblique"]:
			var arguments := PackedStringArray(["--hunt-layout=fixed-cohort80", "--hunt-geometry=" + geometry, "--sheep=" + str(total), "--seed=42"])
			_check(_argument_error(arguments, "hunt-cooperation", total, 42).is_empty(), "Every preregistered population/geometry pair is accepted")
			_check(ProductionHuntCohort.from_arguments(arguments) == ProductionHuntCohort.Layout.FIXED_COHORT80, "Fixed layout survives parsing")
	var valid := PackedStringArray(["--hunt-layout=fixed-cohort80", "--hunt-geometry=north"])
	_check(not _argument_error(valid, "two-flocks", 80, 42).is_empty(), "Layout cannot leak to another protocol")
	_check(not _argument_error(valid, "hunt-cooperation", 81, 42).is_empty(), "Undeclared population fails")
	_check(not _argument_error(valid, "hunt-cooperation", 80, 43).is_empty(), "Undeclared seed fails")
	for extra: String in ["--hunt-layout=fixed-cohort80", "--hunt-geometry=oblique", "--sheep=1000junk", "--seed=42junk", "--hunt-layot=fixed-cohort80"]:
		var arguments: PackedStringArray = valid.duplicate()
		arguments.append(extra)
		_check(not _argument_error(arguments, "hunt-cooperation", 80, 42).is_empty(), "Duplicate or malformed exact options cannot silently change the matrix")
	for geometry: String in ["baseline", "unknown"]:
		_check(not _argument_error(PackedStringArray(["--hunt-layout=fixed-cohort80", "--hunt-geometry=" + geometry]), "hunt-cooperation", 80, 42).is_empty(), "Only declared changed geometries belong to the new protocol")
	_check(not _argument_error(PackedStringArray(["--hunt-layout=fixed-cohort80"]), "hunt-cooperation", 80, 42).is_empty(), "Geometry is explicit in the new protocol")
	_check(not _argument_error(PackedStringArray(["--hunt-layout=other", "--hunt-geometry=north"]), "hunt-cooperation", 80, 42).is_empty(), "Unknown layout cannot fall back")
	_check(not _argument_error(PackedStringArray(["--hunt-geometry=north"]), "hunt-cooperation", 1000, 42).is_empty(), "Old north still rejects an undeclared1000 layout")
	_check(_argument_error(PackedStringArray(["--hunt-geometry=baseline"]), "hunt-cooperation", 1000, 43).is_empty(), "Old baseline population/seed range remains available")

func _check_positions() -> void:
	var small := ProductionHuntCohort.new()
	var large := ProductionHuntCohort.new()
	small.prepare(80, 42)
	large.prepare(1000, 42)
	_check(small.requested_positions.size() == 80 and large.requested_positions.size() == 1000, "Population split is exactly80+0/920")
	_check(large.requested_positions.slice(0, 80) == small.requested_positions, "Additional background never changes the first80 coordinates")
	# Independent frozen formula for the original 80-life registration prefix.
	var random := RandomNumberGenerator.new()
	random.seed = 42
	_check(small.requested_positions[0] == Vector2(600, 700), "Declared prey remains first")
	for index: int in 79:
		var expected := Vector2(1800, 700) + Vector2(index % 9 - 4, index / 9 - 4) * 32.0
		expected += Vector2(random.randf_range(-2, 2), random.randf_range(-2, 2))
		_check(small.requested_positions[index + 1] == expected, "Original coordinates and random-call prefix remain exact")
	_check(large.requested_positions[80] == Vector2(32, 32), "Fixed grid begins at its declared corner")
	_check(large.requested_positions[999] == Vector2(2048, 1088), "Fixed edge-alternating traversal retains its declared920th position")
	for index: int in range(80, 1000):
		var position: Vector2 = large.requested_positions[index]
		_check(position.distance_to(Vector2(600, 700)) >= 650.0 and position.distance_to(Vector2(1800, 700)) >= 300.0, "All background centers satisfy initial fixed clearances")
	var world: SimulationWorld = _new_world()
	_check(large.placement_error(world).is_empty(), "All1000 initial bodies pass full bounds and pairwise checks")
	_check(large.initial_pairs_checked == 499500, "Initial preflight retains the complete pair denominator")
	large.requested_positions[999] = large.requested_positions[0]
	_check(not large.placement_error(world).is_empty() and large.fixture_error_details["index"] == 999, "An overlap in the final background body is not ignored")
	_close(world)

func _new_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var scenario := ScenarioConfig.new()
	scenario.random_seed = 42
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	return world

func _probe(world: SimulationWorld, count: int) -> ProductionHuntProbe:
	var probe := ProductionHuntProbe.new()
	probe.layout = ProductionHuntCohort.Layout.FIXED_COHORT80
	probe.geometry_variant = ProductionHuntGeometry.Variant.NORTH
	probe.setup(world, count, 42)
	return probe

func _register(world: SimulationWorld, probe: ProductionHuntProbe) -> void:
	world._apply_commands()
	probe.observe_step_start(world)

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_registration_and_identity() -> void:
	var original_world: SimulationWorld = _new_world()
	var original := ProductionHuntProbe.new()
	original.setup(original_world, 80, 42)
	_register(original_world, original)
	var reference: Array[Dictionary] = []
	var recorder := ProductionHuntCohort.new()
	for index: int in 80:
		reference.append(recorder._life_record(original_world, original_world.store.handle_at(index), index))
	_check(original._protocol_version() == "production-hunt-cooperation-v1", "Existing protocol identity is unchanged")
	_close(original_world)
	for count: int in [80, 1000]:
		var world: SimulationWorld = _new_world()
		var probe: ProductionHuntProbe = _probe(world, count)
		_check(world.store.count == 0 and world.has_pending_observer_commands(), "All initial lives wait for normal stage0")
		_register(world, probe)
		var cohort: ProductionHuntCohort = probe._fixed_cohort
		_check(not probe.finished and cohort.initial_cohort == reference, "Actual first80 identities and every recorded initial scalar match the old80 fixture")
		_check(cohort.background_handles.size() == count - 80 and world.counts()[SimTypes.Species.SHEEP] == count, "Additional lives are ordinary registered sheep")
		_check(probe._protocol_version() == ProductionHuntCohort.VERSION, "New geometry/load matrix has its own version")
		if count == 1000:
			_check_background_identity(world, cohort)
		_close(world)

func _check_background_identity(world: SimulationWorld, cohort: ProductionHuntCohort) -> void:
	var removed: AgentHandle = cohort.background_handles[0]
	var held: AgentHandle = cohort.background_handles[1]
	world.queue_remove(removed)
	world.queue_hold(held)
	world._apply_commands()
	world.queue_place(SimTypes.Species.SHEEP, Vector2(32, 32))
	world._apply_commands()
	var replacement: AgentHandle = world.store.handle_at(world.store.count - 1)
	_check(replacement.slot == removed.slot and not replacement.same_life(removed), "Fixture reuses a slot with a distinct life")
	var actor: AgentHandle = cohort.background_handles[2]
	var context: AgentContext = world.ai.inspect(actor)
	var intent := MotionIntent.new()
	intent.actor = actor
	intent.owner_token = context.task_token
	intent.expires_tick = 100
	world.intents.write(actor, intent)
	world.store.relocate(actor, Vector2(600, 700))
	context.last_perception_tick = 20
	context.last_decision_tick = 21
	world.tick = 60
	cohort.sample_background(world, Time.get_ticks_usec())
	var sample: Dictionary = cohort.background_samples[0]
	_check(sample["registered_background"] == 920 and sample["alive"] == 919 and sample["active"] == 918, "Removed and held lives remain distinct from the active denominator")
	_check(sample["valid_intents"] == 1 and sample["owned_intents"] == 1 and sample["missing_intents"] == 917, "TTL-valid and owned intents use current declared active lives")
	_check(sample["perception_advanced_since_sample"] == 1 and sample["decision_advanced_since_sample"] == 1, "Sampled AI progress uses production context clocks")
	_check(sample["moved_net_ge_1px_since_sample"] == 1 and sample["inside_initial_prey_region"] == 1, "Sampled physical progress and region entries are measured independently")
	var report: Dictionary = cohort.report(world)
	_check(report["sheep_terminal"].size() == 1000 and not report["sheep_terminal"][80]["alive"], "Full-life terminal record cannot resolve a replacement into its removed predecessor")
	_check(report["sheep_terminal"][80]["position_x"] == null and report["sheep_terminal"][81]["alive"] and not report["sheep_terminal"][81]["active"], "Removed coordinates are null while held life remains alive")
	_check(report["initial_background"].size() == 920, "Initial roster remains complete after lifecycle changes")

func _check_initial_rejection() -> void:
	var world: SimulationWorld = _new_world()
	world.config.agent_radius = 20.0
	var probe: ProductionHuntProbe = _probe(world, 1000)
	var report: Dictionary = probe.finish_report()
	_check(probe.finished and not report["fixture_valid"] and report["requested_initial_positions"].size() == 1000, "Failed initial body validation retains the declared complete geometry")
	_check(world.store.count == 0 and not world.has_pending_observer_commands(), "Initial failure cannot enqueue a partial sheep roster")
	_close(world)
	world = _new_world()
	probe = ProductionHuntProbe.new()
	probe.layout = ProductionHuntCohort.Layout.FIXED_COHORT80
	probe.geometry_variant = ProductionHuntGeometry.Variant.NORTH
	probe.setup(world, 80, 43)
	_check(probe.finished and not world.has_pending_observer_commands(), "Direct probe setup also rejects an undeclared seed")
	_close(world)

func _check_runtime_rejection() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionHuntProbe = _probe(world, 1000)
	_register(world, probe)
	var blocker: AgentHandle = probe._fixed_cohort.background_handles[919]
	var requested := Vector2(600, 700) + ProductionHuntGeometry.offsets(ProductionHuntGeometry.Variant.NORTH)[2]
	world.store.relocate(blocker, requested)
	world.tick = 240
	probe.before_step(world)
	var report: Dictionary = probe.finish_report()
	_check(probe.finished and not report["fixture_valid"], "A non-prey background body can reject the runtime geometry")
	_check(report["hunter_body_preflight"].size() == 3, "All three candidates are retained in atomic preflight")
	for row: Dictionary in report["hunter_body_preflight"]:
		_check(row["active_bodies_checked"] == 1000, "Every candidate checks the entire actual active roster")
	_check(report["fixture_error_details"]["blocker"] == blocker.key() and report["fixture_error_details"]["distance"] == 0.0, "Failure retains the actual full-life blocker and measured separation")
	_check(world.counts()[SimTypes.Species.WOLF] == 0 and not world.has_pending_observer_commands(), "Third-candidate failure does not register the first two")
	_check(report["initial_cohort"].size() == 80 and report["initial_background"].size() == 920 and report["sheep_terminal"].size() == 1000, "Failed runtime report still preserves full initial and current denominators")
	_close(world)

func _check_successful_atomic_registration() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionHuntProbe = _probe(world, 80)
	_register(world, probe)
	var held: AgentHandle = probe._fixed_cohort.cohort_handles[1]
	world.store.relocate(held, Vector2(600, 590))
	world.queue_hold(held)
	world._apply_commands()
	world.tick = 240
	probe.before_step(world)
	_check(not probe.finished and world.counts()[SimTypes.Species.WOLF] == 0, "Held bodies do not participate in the all-active-body birth gate")
	_register(world, probe)
	_check(not probe.finished and world.counts()[SimTypes.Species.WOLF] == 3 and probe._records.size() == 3, "All candidates enter via normal stage0 only after whole-batch preflight")
	for record: ProductionHuntTrace in probe._records:
		_check(record.eligible_tick == 240 and record.cooperation_eligible_tick == 240, "Existing perception/cooperation denominator survives the new layout")
		_check(world.intents.get_intent(record.handle, 240) == null and world.ai.coordination.get_lease(record.handle, 240) == null, "Fixture assigns no intent or hunt role")
	_close(world)
