extends SceneTree
## CPU measurement/control fixtures. Manual contexts and movement below validate
## the observer; they are never autonomous withdrawal behavior evidence.
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
	_check_modes_and_legacy()
	_check_service_and_motion_evidence()
	_check_failed_fixture()
	print("DOG_WITHDRAWAL_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _arguments_error(arguments: PackedStringArray, behavior_case: String, count: int, seed_value: int) -> String:
	var error: String = ProductionDogProtectionGeometry.argument_error(arguments, behavior_case, count, seed_value)
	if not error.is_empty():
		return error
	return ProductionDogWithdrawal.argument_error(arguments, behavior_case, count, seed_value)

func _check_arguments() -> void:
	for seed_value: int in [43, 44]:
		for mode: String in ["remove-dogs", "keep-all"]:
			var arguments := PackedStringArray(["--dog-geometry=anchor-oblique", "--dog-withdrawal=" + mode, "--sheep=80", "--seed=" + str(seed_value)])
			_check(_arguments_error(arguments, "dog-withdrawal", 80, seed_value).is_empty(), "Exactly the four declared combinations are accepted")
			_check(ProductionDogWithdrawal.mode_name(ProductionDogWithdrawal.from_arguments(arguments)) == mode, "Mode is explicit and survives parsing")
	var valid := PackedStringArray(["--dog-geometry=anchor-oblique", "--dog-withdrawal=remove-dogs"])
	_check(not _arguments_error(valid, "dog-protection", 80, 43).is_empty(), "Old case cannot silently enable withdrawal")
	_check(not _arguments_error(valid, "dog-withdrawal", 1000, 43).is_empty(), "Undeclared1000 withdrawal is rejected")
	_check(not _arguments_error(valid, "dog-withdrawal", 80, 42).is_empty(), "Undeclaredseed42 is rejected")
	_check(not _arguments_error(PackedStringArray(["--dog-geometry=anchor-oblique"]), "dog-withdrawal", 80, 43).is_empty(), "New case requires an explicit mode")
	for extra: String in ["--dog-withdrawal=keep-all", "--seed=43oops", "--sheep=80junk", "--dog-withdrawl=remove-dogs"]:
		var arguments: PackedStringArray = valid.duplicate()
		arguments.append(extra)
		_check(not _arguments_error(arguments, "dog-withdrawal", 80, 43).is_empty(), "Duplicate/malformed flags cannot choose an implicit experiment")
	_check(not _arguments_error(PackedStringArray(["--dog-geometry=anchor-oblique", "--dog-withdrawal=unknown"]), "dog-withdrawal", 80, 43).is_empty(), "Unknown mode fails")
	_check(_arguments_error(PackedStringArray(), "dog-protection", 80, 42).is_empty(), "Original default keeps its legacy600 removal")
	_check(ProductionDogWithdrawal.from_arguments(PackedStringArray()) == ProductionDogWithdrawal.Mode.ORIGINAL, "Missing mode preserves old configuration")

func _new_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var scenario := ScenarioConfig.new()
	scenario.random_seed = 43
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	return world

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _registered_probe(world: SimulationWorld, mode: ProductionDogWithdrawal.Mode) -> ProductionDogProtectionProbe:
	var probe := ProductionDogProtectionProbe.new()
	probe.geometry_variant = ProductionDogProtectionGeometry.Variant.ANCHOR_OBLIQUE
	probe.withdrawal_mode = mode
	probe.setup(world, 80, 43)
	world._apply_commands()
	probe.observe_step_start(world)
	# This test sets an already-validated registration fixture without pretending
	# to run the240tick natural protection preflight covered by the other suite.
	world.tick = 240
	probe._requested_wolves = [Vector2(100, 100), Vector2(2300, 1300)]
	for position: Vector2 in probe._requested_wolves:
		world.queue_place(SimTypes.Species.WOLF, position)
	world._apply_commands()
	probe.observe_step_start(world)
	return probe

func _check_modes_and_legacy() -> void:
	for mode: ProductionDogWithdrawal.Mode in [ProductionDogWithdrawal.Mode.ORIGINAL, ProductionDogWithdrawal.Mode.REMOVE_DOGS, ProductionDogWithdrawal.Mode.KEEP_ALL]:
		var world: SimulationWorld = _new_world()
		var probe: ProductionDogProtectionProbe = _registered_probe(world, mode)
		var dogs: Array[AgentHandle] = probe._dogs.duplicate()
		var wolves: Array[AgentHandle] = probe._wolves.duplicate()
		world.tick = 299
		probe.before_step(world)
		probe.observe_step_start(world)
		_check(world.counts() == PackedInt32Array([80, 2, 4]), "Nothing is removed before the declared300 boundary")
		world.tick = 300
		probe.before_step(world)
		_check(world.counts()[SimTypes.Species.DOG] == 4, "Queueing removal does not bypass stage0")
		world._apply_commands()
		probe.observe_step_start(world)
		var expected_dogs: int = 0 if mode == ProductionDogWithdrawal.Mode.REMOVE_DOGS else 4
		_check(world.counts() == PackedInt32Array([80, 2, expected_dogs]), "Mode changes only the four declared dog lives at300")
		if mode != ProductionDogWithdrawal.Mode.ORIGINAL:
			var report: Dictionary = probe._withdrawal.report()
			_check(report["withdrawal_pre299"].size() == 2 and report["withdrawal_boundary"].size() == 2, "Both pre299 and pre-control300 full wolf states survive")
			_check(report["boundary_prepared"] and report["control_observed"] and report["withdrawal_dog_controls"].size() == 4, "Each original dog has a measured stage0 result")
			_check(report["control_submitted"] == (mode == ProductionDogWithdrawal.Mode.REMOVE_DOGS), "KEEP_ALL never claims it submitted a control")
			for index: int in 4:
				var row: Dictionary = report["withdrawal_dog_controls"][index]
				_check(row["dog"] == dogs[index].key() and row["post_stage0_observed"], "Control result retains exact original identity")
				_check(row["actual_removed"] == (mode == ProductionDogWithdrawal.Mode.REMOVE_DOGS), "An attempted control is not confused with actual removal")
				if mode == ProductionDogWithdrawal.Mode.REMOVE_DOGS:
					_check(not row["context_after"] and not row["intent_after"], "Normal removal clears original context and intent")
		world.tick = 600
		probe.before_step(world)
		world._apply_commands()
		_check(world.counts()[SimTypes.Species.WOLF] == (0 if mode == ProductionDogWithdrawal.Mode.ORIGINAL else 2), "Only the old protocol removes wolves at600")
		if mode != ProductionDogWithdrawal.Mode.ORIGINAL:
			for wolf: AgentHandle in wolves:
				_check(world.store.is_alive(wolf), "Original wolves survive the omitted600 intervention")
		var result: Dictionary = probe.finish_report()
		_check(result["remove_wolves_tick"] == (600 if mode == ProductionDogWithdrawal.Mode.ORIGINAL else -1), "Report distinguishes actual intervention schedules")
		_check(result["protocol"] == (ProductionDogProtectionGeometry.ANCHOR_VERSION if mode == ProductionDogWithdrawal.Mode.ORIGINAL else ProductionDogWithdrawal.VERSION), "Legacy and withdrawal report versions remain separate")
		_close(world)

func _intent(world: SimulationWorld, actor: AgentHandle, behavior: int, mode: int, destination: Vector2, token: int, expiry: int) -> void:
	var intent := MotionIntent.new()
	intent.behavior = behavior
	intent.mode = mode
	intent.owner_token = token
	intent.expires_tick = expiry
	intent.destination = destination
	world.intents.write(actor, intent)

func _check_service_and_motion_evidence() -> void:
	var world: SimulationWorld = _new_world()
	var probe: ProductionDogProtectionProbe = _registered_probe(world, ProductionDogWithdrawal.Mode.REMOVE_DOGS)
	var helper: ProductionDogWithdrawal = probe._withdrawal
	var wolf: AgentHandle = probe._wolves[0]
	var unserved: AgentHandle = probe._wolves[1]
	for actor: AgentHandle in probe._wolves:
		var context: AgentContext = world.ai.inspect(actor)
		context.retreating = true
		context.task_name = &"flee_threat"
		context.safe_after_tick = 390
		context.last_decision_tick = 295
		var sighting := LocalObservation.new()
		sighting.handle = probe._dogs[0]
		sighting.species = SimTypes.Species.DOG
		sighting.observed_tick = 290
		sighting.expires_tick = 410
		context.observations[sighting.handle.slot] = sighting
		context.threat = sighting
		_intent(world, actor, SimTypes.Behavior.RETREAT, SimTypes.IntentMode.FLEE, Vector2(1500, 100), context.task_token, 390)
	world.tick = 299
	helper.observe_step_start(world)
	world.tick = 300
	helper.after_step(world, Time.get_ticks_usec())
	helper.before_step(world, Time.get_ticks_usec())
	world._apply_commands()
	helper.observe_step_start(world)
	_check(helper.records[0].retreat_at_boundary and helper.records[1].retreat_at_boundary, "Both original retreating lives enter the denominator before removal")
	_check(helper.records[0].before["threat_reference"] != "" and not helper.records[0].before["threat_valid"], "Removed full-life threat becomes invalid without rewriting historical context")
	_check(helper.records[0].before["safe_after_tick"] == 390 and helper.records[0].before["decision_tick"] == 295, "Read-only observation does not refresh a clock or run a tree")
	for actor: AgentHandle in probe._wolves:
		var context: AgentContext = world.ai.inspect(actor)
		context.retreating = false
		context.task_name = &"search_area"
		var position: Vector2 = world.store.position_current[world.store.resolve(actor)]
		_intent(world, actor, SimTypes.Behavior.SEARCH, SimTypes.IntentMode.MOVE, position + Vector2(100, 0), context.task_token, 400)
	world.ai.inspect(wolf).last_decision_tick = 300
	world.store.relocate(wolf, Vector2(100.5, 100))
	world.store.relocate(unserved, Vector2(2320, 1300))
	world.tick = 301
	helper.after_step(world, Time.get_ticks_usec())
	_check(helper.records[0].first_service_tick == 300 and helper.records[0].left_retreat_tick == 300, "A genuine clock advance with an existing tree records service and exit without a fabricated90tick hold")
	_check(helper.records[0].first_nonretreat_intent_tick == 300 and helper.records[0].motion_tick < 0, "Valid SEARCH is allowed, but0.5px does not pass the1px movement gate")
	_check(helper.records[1].first_service_tick < 0 and helper.records[1].motion_tick < 0, "Changed task labels and20px alone cannot manufacture a real service response")
	helper.observe_step_start(world)
	world.store.relocate(wolf, Vector2(101.1, 100))
	world.tick = 302
	helper.after_step(world, Time.get_ticks_usec())
	_check(helper.records[0].motion_tick == 302 and helper.records[0].intended_progress_pixels >= 1.0, "Only valid positive step projections accumulate to the unchanged1px gate")
	var progress: float = helper.records[0].intended_progress_pixels
	helper.observe_step_start(world)
	_intent(world, wolf, SimTypes.Behavior.SEARCH, SimTypes.IntentMode.MOVE, Vector2(1500, 100), 999, 400)
	world.store.relocate(wolf, Vector2(111.1, 100))
	world.tick = 303
	helper.after_step(world, Time.get_ticks_usec())
	_check(helper.records[0].post_unowned_intent_steps == 1 and helper.records[0].intended_progress_pixels == progress, "Unowned moving intent remains a failed sample")
	helper.observe_step_start(world)
	_intent(world, wolf, SimTypes.Behavior.SEARCH, SimTypes.IntentMode.MOVE, Vector2(1500, 100), world.ai.inspect(wolf).task_token, 303)
	world.store.relocate(wolf, Vector2(121.1, 100))
	world.tick = 304
	helper.after_step(world, Time.get_ticks_usec())
	_check(helper.records[0].post_missing_intent_steps == 1 and helper.records[0].intended_progress_pixels == progress, "Expired intent cannot make inertial displacement into effective motion")
	var report: Dictionary = helper.report()
	_check(report["withdrawal_outcomes"]["retreat_at_boundary"] == 2 and report["withdrawal_outcomes"]["retreat_eligible_not_exited"] == 1, "Unserved retreat life remains in the original denominator")
	_check(report["withdrawal_outcomes"]["registered_without_effective_motion"] == 1 and report["withdrawal_records"].size() == 2, "Motion failure does not remove its life from the summary")
	var retained_pre299: Dictionary = helper.pre299[0]
	_check(retained_pre299["retreating"] and retained_pre299["decision_tick"] == 295 and retained_pre299["threat_valid"], "Later changes cannot mutate retained299 evidence")
	world.queue_remove(wolf)
	world._apply_commands()
	var replacement: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(800, 800))
	_check(replacement.slot == wolf.slot and not replacement.same_life(wolf), "Fixture creates a real slot-reuse counterexample")
	helper.observe_step_start(world)
	world.tick = 305
	helper.after_step(world, Time.get_ticks_usec())
	_check(not helper.records[0].terminal["alive"] and helper.records[0].terminal["x"] == null, "Old wolf record never adopts a replacement's live position or context")
	_close(world)

func _check_failed_fixture() -> void:
	var world: SimulationWorld = _new_world()
	var probe := ProductionDogProtectionProbe.new()
	probe.withdrawal_mode = ProductionDogWithdrawal.Mode.REMOVE_DOGS
	probe.geometry_variant = ProductionDogProtectionGeometry.Variant.ANCHOR_OBLIQUE
	probe.setup(world, 80, 43)
	world._apply_commands()
	probe.observe_step_start(world)
	world.tick = 240
	probe.before_step(world)
	var report: Dictionary = probe.finish_report()
	_check(probe.finished and not report["fixture_valid"] and report["registered_wolves"] == 0, "A missing natural protection sample remains a rejected fixture")
	_check(report["withdrawal_records"].is_empty() and not report["control_submitted"], "Rejected stimulus cannot claim a later withdrawal response")
	_check(world.counts() == PackedInt32Array([80, 0, 4]), "Failure neither generates wolves nor prematurely removes dogs")
	_close(world)
