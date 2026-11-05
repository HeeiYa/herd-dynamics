extends SceneTree
## Fixture evidence contracts only; these CPU states are not behavior trials.
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
	_check_geometry()
	_check_registration_and_fixed_depletion()
	_check_background_evidence_and_identity()
	print("FORAGE_FIXED_COHORT_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_arguments() -> void:
	var option := PackedStringArray(["--forage-layout=fixed-cohort80"])
	_check(ProductionForageCohort.from_arguments(PackedStringArray()) == ProductionForageCohort.Layout.ORIGINAL, "Absent option preserves the old protocol")
	_check(ProductionForageCohort.argument_error(PackedStringArray(), "forage-empty", 8, 44).is_empty(), "Old cases, counts and seeds are not restricted by the new experiment")
	for total: int in [80, 1000]:
		_check(ProductionForageCohort.argument_error(option, "forage-migration", total, 42).is_empty(), "The two declared totals are explicit valid cases")
	_check(ProductionForageCohort.from_arguments(option) == ProductionForageCohort.Layout.FIXED_COHORT80, "Explicit fixed cohort survives parsing")
	_check(not ProductionForageCohort.argument_error(option, "forage-empty", 80, 42).is_empty(), "Empty control cannot silently receive a different geometry")
	_check(not ProductionForageCohort.argument_error(option, "hunt-cooperation", 80, 42).is_empty(), "Unrelated protocol rejects forage options")
	_check(not ProductionForageCohort.argument_error(option, "forage-migration", 81, 42).is_empty(), "Population is not silently clamped to the declared matrix")
	_check(not ProductionForageCohort.argument_error(option, "forage-migration", 80, 43).is_empty(), "The fixed seed is part of this experiment's scope")
	_check(not ProductionForageCohort.argument_error(PackedStringArray(["--forage-layout=unknown"]), "forage-migration", 80, 42).is_empty(), "Unknown values fail instead of using default")
	_check(not ProductionForageCohort.argument_error(PackedStringArray(["--forage-layuot=fixed-cohort80"]), "forage-migration", 80, 42).is_empty(), "Unknown forage keys are not ignored")
	_check(not ProductionForageCohort.argument_error(PackedStringArray([option[0], option[0]]), "forage-migration", 80, 42).is_empty(), "Duplicate flags fail even when equal")
	_check(not ProductionForageCohort.argument_error(PackedStringArray([option[0], "--seed=42oops"]), "forage-migration", 80, 42).is_empty(), "Numeric conversion cannot disguise an invalid raw seed")
	_check(not ProductionForageCohort.argument_error(PackedStringArray([option[0], "--sheep=80", "--sheep=1000"]), "forage-migration", 1000, 42).is_empty(), "Duplicate population arguments cannot silently select the last one")

func _new_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	config.grass_recovery_rate = 0.0
	var scenario := ScenarioConfig.new()
	scenario.random_seed = 42
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	return world

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_geometry() -> void:
	var small := ProductionForageCohort.new()
	var large := ProductionForageCohort.new()
	small.prepare(80, 42)
	large.prepare(1000, 42)
	_check(small.requested_positions.size() == 80 and large.requested_positions.size() == 1000, "Requested totals do not change the fixed80 size")
	_check(small.requested_positions == large.requested_positions.slice(0, 80), "Additional population never consumes the original cohort RNG prefix")
	var world: SimulationWorld = _new_world()
	_check(small.placement_error(world).is_empty() and large.placement_error(world).is_empty(), "All declared bodies, grass and pair distances satisfy the real world")
	_check(large.requested_positions[80] == Vector2(56, 220) and large.requested_positions[540] == Vector2(1896, 220), "Background groups use the declared two distinct origins")
	var saved: Vector2 = large.requested_positions[80]
	large.requested_positions[80] = Vector2(NAN, 100)
	_check(not large.placement_error(world).is_empty(), "Nonfinite geometry fails")
	large.requested_positions[80] = Vector2(12, 100)
	_check(not large.placement_error(world).is_empty(), "Whole bodies must fit without stage0 clamp")
	large.requested_positions[80] = large.requested_positions[81]
	_check(not large.placement_error(world).is_empty(), "Overlapping background sheep fail the fixture")
	large.requested_positions[80] = Vector2(730, 300)
	_check(not large.placement_error(world).is_empty(), "Background bodies cannot begin inside the fixed dry rectangle")
	large.requested_positions[80] = saved
	var cell: int = world.resources.cell_at(saved)
	world.resources.consume(cell, world.resources.food_capacity(cell), world.tick)
	world.tick += 1
	_check(not large.placement_error(world).is_empty(), "A grassless initial background position cannot masquerade as reachable control")
	_close(world)

func _registered_probe(world: SimulationWorld, total: int) -> ProductionForageProbe:
	var probe := ProductionForageProbe.new()
	probe.layout = ProductionForageCohort.Layout.FIXED_COHORT80
	probe.setup(world, total, 42)
	world._apply_commands()
	probe.observe_step_start(world)
	return probe

func _check_registration_and_fixed_depletion() -> void:
	var original_world: SimulationWorld = _new_world()
	var original := ProductionForageProbe.new()
	original.setup(original_world, 80, 42)
	original_world._apply_commands()
	original.observe_step_start(original_world)
	var reference: PackedVector2Array = original_world.store.position_current.duplicate()
	_check(original._fixed_cohort == null and original._records.size() == 80, "Default probe still records its original whole population")
	_close(original_world)
	var first_initial: Array[Dictionary] = []
	for total: int in [80, 1000]:
		var world: SimulationWorld = _new_world()
		var probe: ProductionForageProbe = _registered_probe(world, total)
		_check(not probe.finished and probe._records.size() == 80 and world.store.count == total, "Only80 records accompany the actual full population")
		var equal_positions: bool = true
		for index: int in 80:
			equal_positions = equal_positions and world.store.position_current[index] == reference[index]
		_check(equal_positions, "Real stage0 positions match the original80 formula exactly")
		if total == 80:
			first_initial.assign(probe._fixed_cohort.initial_cohort)
		else:
			_check(probe._fixed_cohort.initial_cohort == first_initial, "Both totals have identical complete initial cohort scalars and identities")
		# Deliberately relocate after registration: drought must stay declared.
		world.store.relocate(probe._records[0].handle, Vector2(100, 100))
		world.tick = 240
		probe.before_step(world)
		_check(probe._dry_region == Rect2(720, 240, 960, 960) and probe._depleted_cells.size() == 144, "Later positions and total population cannot enlarge the dry rectangle")
		var inside: int = world.resources.cell_at(Vector2(800, 400))
		var outside: int = world.resources.cell_at(Vector2(100, 100))
		_check(world.resources.get_effective_amount(inside, 240) > 0.0 and world.resources.get_effective_amount(inside, 241) == 0.0, "Environmental depletion retains the original n to n+1 boundary")
		_check(world.resources.get_effective_amount(outside, 241) > 0.0, "The outside resource remains reachable rather than being globally depleted")
		probe.finished = true
		var report: Dictionary = probe.finish_report()
		_check(report["protocol"] == ProductionForageCohort.VERSION and report["requested_sheep"] == total and report["outcomes"][0]["cohort"] == 80, "New protocol identity separates fixed cohort denominator from total load")
		_check(report["records"].size() == 80 and report["initial_background"].size() == total - 80, "Background initial evidence never enters migration response rows")
		_close(world)

func _check_background_evidence_and_identity() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionForageProbe = _registered_probe(world, 1000)
	var cohort: ProductionForageCohort = probe._fixed_cohort
	world.tick = 60
	_check(cohort.sample_background(world, 0).is_empty(), "Unchanged real registered background can be sampled without altering it")
	var sample: Dictionary = cohort.background_samples.back()
	_check(sample["active"] == 920 and sample["perception_advanced_since_sample"] == 0 and sample["decision_advanced_since_sample"] == 0, "Birth decision tick is not falsely counted as a serviced job")
	_check(sample["moved_net_ge_1px_since_sample"] == 0, "Existence and active AI contexts do not fabricate motion")
	for index: int in 40:
		world.store.relocate(cohort.background_handles[index], Vector2(800 + index, 400))
	world.tick = 61
	_check(cohort.observe_intrusions(world, 0).is_empty(), "Exact endpoint intrusion accepts genuine same-life movement")
	var intrusion: Dictionary = cohort.report()["background_intrusion"]
	_check(intrusion["unique_lives"] == 40 and intrusion["life_steps"] == 40 and intrusion["peak"] == 40, "Intrusion denominator retains all entrants independently of detail cap")
	_check(intrusion["events_retained"] == 32 and intrusion["events_omitted"] == 8 and intrusion["first_input_tick"] == 61, "First-entry detail is bounded while exact omission and clock remain")
	world.tick = 62
	cohort.observe_intrusions(world, 0)
	_check(cohort.intrusion_unique_lives == 40 and cohort.intrusion_life_steps == 80, "Repeated residence adds life-steps but does not duplicate entrants")
	for index: int in 40:
		world.store.relocate(cohort.background_handles[index], cohort.requested_positions[80 + index])
	world.tick = 63
	cohort.observe_intrusions(world, 0)
	_check(cohort.intrusion_life_steps == 80, "A short entry and exit between1Hz samples remain observable")
	var actor: AgentHandle = cohort.background_handles[0]
	world.ai.inspect(actor).last_perception_tick = 64
	world.ai.inspect(actor).last_decision_tick = 65
	world.store.relocate(actor, cohort.requested_positions[80] + Vector2(2, 0))
	world.tick = 120
	cohort.sample_background(world, 0)
	sample = cohort.background_samples.back()
	_check(sample["moved_net_ge_1px_since_sample"] == 1 and sample["perception_advanced_since_sample"] == 1 and sample["decision_advanced_since_sample"] == 1, "Actual changes have distinct motion and service evidence")
	world._remove(actor)
	var replacement: AgentHandle = world.create_at(SimTypes.Species.SHEEP, cohort.requested_positions[80])
	_check(replacement.slot == actor.slot and not replacement.same_life(actor), "Identity regression uses actual same-slot replacement")
	probe.observe_step_start(world)
	_check(probe.finished and not probe.finish_report()["fixture_valid"], "A replacement cannot silently repair the background life denominator")
	_close(world)
