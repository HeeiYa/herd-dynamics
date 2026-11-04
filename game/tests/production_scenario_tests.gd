extends SceneTree
## CPU contract fixtures validate diagnostic semantics, not production capacity.
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
	_check_migration_chain()
	_check_hunt_protocol()
	_check_forage_protocol(false)
	_check_forage_protocol(true)
	print("PRODUCTION_SCENARIO_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _new_world(no_recovery: bool = false) -> SimulationWorld:
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	if no_recovery:
		config.grass_recovery_rate = 0.0
	var initial := ScenarioConfig.new()
	initial.sheep_count = 0
	initial.wolf_count = 0
	initial.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, initial)
	return world

func _step(world: SimulationWorld, probe: ProductionBehaviorProtocol) -> void:
	probe.before_step(world)
	world.ai.begin_frame()
	world.step()
	probe.after_step(world)

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_migration_chain() -> void:
	var trace := ProductionForageTrace.new()
	trace.handle = AgentHandle.new(0, 1, 2)
	trace.eligible_tick = 10
	trace.search_tick = 11
	_check(not trace.to_dictionary(26.0)["migration_completed"], "SEARCH decision alone is not successful migration")
	trace.search_motion_tick = 12
	trace.maximum_net_pixels = 50.0
	trace.exit_dry_region_tick = 20
	_check(not trace.to_dictionary(26.0)["migration_completed"], "Leaving dry ground without real intake is not successful migration")
	trace.eating_tick = 25
	_check(trace.to_dictionary(26.0)["migration_completed"], "Complete migration requires motion, geometric exit and intake")
	trace.maximum_net_pixels = 0.5
	_check(not trace.to_dictionary(26.0)["migration_completed"], "Small boundary jitter cannot satisfy the net displacement condition")

func _check_hunt_protocol() -> void:
	var world: SimulationWorld = _new_world()
	var probe := ProductionHuntProbe.new()
	probe.setup(world, 8, 42)
	_check(world.store.count == 0, "Hunt setup queues ordinary stage0 registration")
	for step: int in ProductionHuntProbe.END_TICK:
		_step(world, probe)
		if world.tick == 1:
			_check(world.store.count == 8 and world.ai.contexts.size() == 8, "Isolated and background sheep are all normal registered trees")
		if world.tick == ProductionHuntProbe.HUNTER_TICK + 1:
			_check(world.counts()[SimTypes.Species.WOLF] == 3, "Three hunters are introduced through normal stage0 commands")
	var report: Dictionary = probe.finish_report()
	var outcome: Dictionary = report["outcomes"][0]
	_check(report["protocol"] == "production-hunt-cooperation-v1" and report["motion_backend"] == "cpu", "CPU diagnostic validation cannot claim GPU production acceptance")
	_check(report["observed_steps"] == 1200 and report["ai_budget_usec"] == 6000, "Hunt protocol retains finite horizon and normal allowance")
	_check(outcome["cohort"] == 3 and outcome["eligible"] == 3 and outcome["cooperation_eligible"] == 3, "Hunt denominators come from actual geometric opportunity")
	_check(outcome["hunt_decision"] + outcome["eligible_without_hunt"] == outcome["eligible"], "Hunt nonresponses remain explicit")
	_check(report["roles"].size() == 9 and report["terminal"].size() == 3, "Role evidence retains every hunter and all three roles, including unused roles")
	_check(report["samples"].size() == 963, "Three hunters have bounded periodic context samples and final endpoints")
	_check(outcome["duplicate_captures"] == 0, "Each prey life can produce only one actual capture event")
	for role: Dictionary in report["roles"]:
		_check(role["target"] == report["declared_target"], "Role metrics never mix different target lives")
		if int(role["matching_intent_ticks"]) > 0:
			_check(int(role["first_lease_tick"]) >= ProductionHuntProbe.HUNTER_TICK, "Executed role evidence follows a real lease in the declared opportunity window")
		if int(role["physical_role_tick"]) >= 0:
			_check(role["intended_progress_pixels"] >= 1.0 and role["role_direction_progress_pixels"] >= 1.0, "Physical role evidence requires actual progress in both directions")
	_close(world)

func _check_forage_protocol(empty_control: bool) -> void:
	var world: SimulationWorld = _new_world(true)
	var probe := ProductionForageProbe.new()
	probe.empty_control = empty_control
	probe.setup(world, 8, 42)
	for step: int in ProductionForageProbe.END_TICK:
		_step(world, probe)
		if world.tick == 1:
			_check(world.store.count == 8 and world.ai.contexts.size() == 8, "Forage actors are real registered trees")
		if world.tick == ProductionForageProbe.DROUGHT_EFFECTIVE_TICK:
			_check(probe._depleted_food > 0.0 and not probe._depleted_cells.is_empty(), "External drought records actual removed food and cells")
			for cell: int in probe._depleted_cells:
				_check(world.resources.get_effective_amount(cell, world.tick) == 0.0, "Drought reaches zero at the declared n+1 boundary")
	var report: Dictionary = probe.finish_report()
	var outcome: Dictionary = report["outcomes"][0]
	_check(report["protocol"] == "production-forage-migration-v1" and report["motion_backend"] == "cpu", "Forage report names its own protocol and CPU validation backend")
	_check(report["observed_steps"] == 1200 and report["ai_budget_usec"] == 6000, "Forage does not enlarge the AI budget or trial duration")
	_check(outcome["cohort"] == 8 and outcome["eligible"] + outcome["never_eligible"] == 8, "Forage cohort keeps never-hungry or locally supplied animals")
	_check(outcome["search_decision"] + outcome["eligible_without_search"] == outcome["eligible"], "Exploration nonresponses remain in the opportunity denominator")
	_check(outcome["real_intake"] + outcome["eligible_without_intake"] == outcome["eligible"], "Missing intake remains an explicit finite-horizon result")
	_check(outcome["migration_completed"] <= outcome["real_intake"] and outcome["migration_completed"] <= outcome["search_motion"], "Migration success cannot be created by a state label alone")
	_check(report["first_intake"].size() == outcome["real_intake"], "Every ingestion claim retains independently inspectable numerical evidence")
	for intake: Dictionary in report["first_intake"]:
		_check(intake["expected_hunger_without_food"] - intake["hunger_after_step"] > ProductionForageProbe.HUNGER_EVIDENCE_EPSILON, "Reported intake exceeds Float32 metabolic prediction noise")
		_check(intake["interaction_total_consumed_this_step"] > 0.0, "Stomach evidence is accompanied by actual resource consumption")
	_check(report["terminal"].size() == 8 and report["quality"].size() == 20, "All sheep have a final state and regular quality samples")
	if empty_control:
		_check(not outcome["goal_reachable_by_fixture"], "Full-empty control explicitly declares food unreachable")
		_check(outcome["real_intake"] == 0 and report["interaction_grass_consumed_after_drought"] == 0.0, "Metabolic Float32 noise cannot manufacture food in the empty control")
	else:
		_check(outcome["goal_reachable_by_fixture"], "Perimeter-food experiment is distinct from the empty control")
	_close(world)
