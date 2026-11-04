extends SceneTree
## Observation contracts: denominator, phase order, ordinary registration and epochs.
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
	_check_censored_denominators()
	_check_registered_fixture()
	_check_complete_cpu_protocol()
	await process_frame
	print("PRODUCTION_BEHAVIOR_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _record(slot: int, eligible_tick: int) -> ProductionBehaviorTrace:
	var record := ProductionBehaviorTrace.new()
	record.handle = AgentHandle.new(slot, 1, 2)
	record.species = SimTypes.Species.SHEEP
	record.eligible_tick = eligible_tick
	record.eligible_usec = eligible_tick * 10000
	return record

func _check_censored_denominators() -> void:
	var responding: ProductionBehaviorTrace = _record(0, 10)
	responding.decision_tick = 13
	responding.decision_usec = 160000
	responding.motion_tick = 15
	responding.motion_usec = 180000
	var dead: ProductionBehaviorTrace = _record(1, 10)
	dead.alive = false
	dead.death_tick = 12
	var waiting: ProductionBehaviorTrace = _record(2, 10)
	var removed: ProductionBehaviorTrace = _record(3, 10)
	removed.alive = false
	removed.removed_by_protocol = true
	var shared: ProductionBehaviorTrace = _record(4, -1)
	shared.decision_tick = 11
	shared.decision_usec = 120000
	var records: Array[Dictionary] = []
	for record: ProductionBehaviorTrace in [responding, dead, waiting, removed, shared]:
		records.append(record.to_dictionary())
	var result: Dictionary = ProductionBehaviorTrace.summarize(records, "sheep_flee")
	_check(result["cohort"] == 5 and result["eligible"] == 4, "All lives retained; only geometric exposures enter eligible denominator")
	_check(result["responded"] == 1 and result["responded_total"] == 2, "Shared response before geometric exposure stays separate")
	_check(result["died_without_response"] == 1 and result["unresponded_alive"] == 1, "Death and surviving nonresponse are not dropped from metrics")
	_check(result["protocol_removed_without_response"] == 1, "External removal is not mislabeled predation")
	_check(result["decision_latency_samples"] == 1 and result["decision_latency_wall_ms_p95"] == 60.0, "Successful-only percentile names its actual sample count and wall-clock units")
	_check(result["moved_along_intent"] == 1, "Decision onset is distinct from physical motion")
	_check(result["recovery_eligible"] == 0, "An ordinary idle or grazer is not treated as a failed return")

func _check_registered_fixture() -> void:
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = config.worker_ai_budget_usec
	var initial := ScenarioConfig.new()
	initial.sheep_count = 0
	initial.wolf_count = 0
	initial.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, initial)
	var observer := ProductionBehaviorProbe.new()
	observer.setup(world, 8, 42)
	_check(world.store.count == 0, "Fixture commands do not bypass stage zero")
	observer.before_step(world)
	world.ai.begin_frame()
	world.step()
	observer.after_step(world)
	_check(world.store.count == 8 and world.ai.contexts.size() == 8, "Every fixture body uses ordinary AI registration")
	_check(observer._records.size() == 8, "Post-command/pre-AI hook observes every new complete life")
	_check(world.config.ai_budget_usec == 6000, "Warmup uses the production 6ms allowance")
	var left: int = 0
	var right: int = 0
	for record: ProductionBehaviorTrace in observer._records:
		left += int(record.group == 0)
		right += int(record.group == 1)
		_check(world.ai.inspect(record.handle).tree_instance() != null, "No stimulus cohort uses an unregistered dummy")
	_check(left == 4 and right == 4, "Both independent flock groups have an explicit cohort")
	_check(observer._quality.is_empty(), "One-second quality samples do not pretend the first tick is steady state")
	_check_replacement_life_is_retained(world, observer)
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_replacement_life_is_retained(world: SimulationWorld, observer: ProductionBehaviorProbe) -> void:
	var retired: AgentHandle = world.store.handle_at(0)
	observer._retired_target = retired
	world.queue_remove(retired)
	world.queue_place(SimTypes.Species.SHEEP, Vector2(600, 700))
	world.ai.begin_frame()
	world.step()
	observer.after_step(world)
	var replacement: AgentHandle = observer._replacement_handle
	_check(replacement != null and replacement.slot == retired.slot and not replacement.same_life(retired), "Immediate replacement records the new complete life")
	if replacement == null:
		return
	_check(observer._by_identity[replacement.key()].species == SimTypes.Species.SHEEP, "First replacement is the scheduled sheep")
	world.queue_remove(replacement)
	world.queue_place(SimTypes.Species.DOG, Vector2(600, 700))
	world.ai.begin_frame()
	world.step()
	observer.after_step(world)
	_check(observer._replacement_handle.same_life(replacement), "Later slot reuse by a dog cannot overwrite the immediate replacement evidence")

func _check_complete_cpu_protocol() -> void:
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var initial := ScenarioConfig.new()
	initial.sheep_count = 0
	initial.wolf_count = 0
	initial.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, initial)
	var observer := ProductionBehaviorProbe.new()
	observer.setup(world, 8, 42)
	for step: int in ProductionBehaviorProbe.END_TICK:
		observer.before_step(world)
		world.ai.begin_frame()
		world.step()
		observer.after_step(world)
	var report: Dictionary = observer.finish_report()
	_check(observer.finished and report["observed_steps"] == ProductionBehaviorProbe.END_TICK, "Protocol has a finite simulation-clock endpoint")
	_check(observer._wolves.size() == 4 and observer._dogs.size() == 4, "Two-sided stimuli and intervening dogs are normal registered lives")
	_check(report["motion_backend"] == "cpu", "CPU fixture validation cannot masquerade as production GPU acceptance")
	_check(report["target_invalidation"]["illegal_retired_captures"] == 0, "Retired complete identity cannot be captured after the queued invalidation")
	_check(report["quality"].size() == 20, "Whole protocol retains regular quality samples, including recovery")
	_check(report["dog_contexts"].size() == 1124, "Four real dogs retain periodic context samples and the final endpoint")
	_check(report["dog_threats"].size() == 4496, "Dog explanations retain all four stimulus identities, including expired memory")
	for record: Dictionary in report["records"]:
		_check(is_finite(record["response_distance_pixels"]) and is_finite(record["peak_response_speed_px_per_second"]), "Physical response diagnostics remain finite")
	world.motion.close()
	world.ai.reset()
	world.free()
