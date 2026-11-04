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
	_check_exposure_episodes()
	_check_registered_fixture()
	_check_capture_after_mark_dead()
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
	responding.recovery_eligible_tick = 20
	responding.recovery_v2_tick = 21
	responding.recovery_v2_kind = "VERIFIED_SATIATED_REST"
	var recovery_records: Array[Dictionary] = [responding.to_dictionary()]
	var recovery: Dictionary = ProductionBehaviorTrace.summarize(recovery_records, "sheep_flee")
	_check(recovery["recovered"] == 0 and recovery["recovered_v2"] == 1, "v2 rest does not rewrite the original recovered column")
	_check(recovery["recovered_satiated_rest_v2"] == 1 and recovery["recovery_eligible"] == 1, "Rest adds evidence without shrinking the recovery denominator")

func _check_exposure_episodes() -> void:
	var record: ProductionBehaviorTrace = _record(0, 597)
	var target := AgentHandle.new(1, 1, 2)
	for tick: int in range(597, 600):
		record.observe_exposure_tick(tick, target)
	record.close_exposure(600, "THREATS_REMOVED")
	var row: Dictionary = record.to_dictionary()
	_check(row["exposure_ticks"] == 3 and row["exposure_longest_ticks"] == 3, "Late exposure retains its actual three-tick opportunity")
	_check(row["response_right_censored"] and row["exposed_without_decision"], "Right censoring explains a nonresponse without removing it")
	var rows: Array[Dictionary] = [row]
	var result: Dictionary = ProductionBehaviorTrace.summarize(rows, "sheep_flee")
	_check(result["eligible"] == 1 and result["unresponded_alive"] == 1 and result["right_censored_unresponded"] == 1, "Censored lives remain in the original exposed denominator")
	_check(record.exposure_episodes[0]["start_tick"] == 597 and record.exposure_episodes[0]["end_tick_exclusive"] == 600, "Exposure intervals use inclusive start and exclusive end")
	var fragmented: ProductionBehaviorTrace = _record(2, 300)
	for episode: int in range(ProductionBehaviorTrace.MAX_EXPOSURE_EPISODES + 2):
		fragmented.observe_exposure_tick(300 + episode * 4, target)
		fragmented.observe_exposure_tick(301 + episode * 4, target)
		fragmented.close_exposure(302 + episode * 4, "LEFT_STIMULUS_RADIUS")
	var fragmented_row: Dictionary = fragmented.to_dictionary()
	_check(fragmented.exposure_episodes.size() == 8 and fragmented_row["exposure_episodes_omitted"] == 2, "Episode list has a fixed per-life bound")
	_check(fragmented.exposure_ticks == 20 and fragmented.exposure_episode_count == 10 and fragmented.exposure_longest_ticks == 2, "Truncated episodes still contribute exact aggregates")
	_check(fragmented.exposure_last_visible_tick == 337 and fragmented.exposure_last_end_tick == 338, "Latest visibility survives truncation and gaps")
	_check(not fragmented_row["response_right_censored"], "Leaving the stimulus radius is reported separately from a protocol cutoff")

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
	_check_satiated_rest_contract(world)
	_check_registered_rest_output(world, observer)
	_check_replacement_life_is_retained(world, observer)
	world.motion.close()
	world.ai.reset()
	world.free()

## Boundary checks for the diagnostic definition, not a production AI result.
func _check_satiated_rest_contract(world: SimulationWorld) -> void:
	var context := AgentContext.new()
	context.coordinator = world.ai
	context.handle = world.store.handle_at(0)
	context.task_name = &"rest_satiated"
	context.task_token = 7
	var intent := MotionIntent.new()
	intent.actor = context.handle
	intent.owner_token = 7
	intent.expires_tick = 20
	var evidence: String = ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0)
	_check(evidence == "VERIFIED_SATIATED_REST", "Real rest contract is eligible with valid owned STOP/IDLE and satiation")
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, null, 10, 0.0) == "MISSING_OR_EXPIRED_INTENT", "Missing intent cannot masquerade as idle rest")
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 20, 0.0) == "MISSING_OR_EXPIRED_INTENT", "TTL equality rejects the expired rest intent")
	intent.actor = AgentHandle.new(context.handle.slot, context.handle.generation + 1, context.handle.world_epoch)
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "WRONG_LIFE", "Same slot with a different generation cannot recover the old life")
	intent.actor = context.handle
	intent.owner_token = 6
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "UNOWNED_INTENT", "Exited task token cannot claim recovery")
	intent.owner_token = 7
	context.task_name = &"search_area"
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "OTHER_LEAF", "Other task producing IDLE is not the formal rest leaf")
	context.task_name = &"rest_satiated"
	context.grazing_committed = true
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "FEEDING_COMMITTED", "Low hunger alone cannot override a feeding commitment")
	context.grazing_committed = false
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, world.ai.settings.hungry_threshold) == "NOT_SATIATED", "SATIATED uses the formal strict hungry-threshold inequality")
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, NAN) == "NOT_SATIATED", "Invalid hunger is not accepted as satiation")
	intent.mode = SimTypes.IntentMode.MOVE
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "NOT_REST_OUTPUT", "A moving IDLE intent does not prove rest")
	intent.mode = SimTypes.IntentMode.STOP
	intent.speed = 1.0
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "NOT_REST_OUTPUT", "Rest requires the leaf's zero-speed output")
	intent.speed = 0.0
	context.safe_after_tick = 11
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "UNSAFE_OR_SAFETY_HOLD", "Safety hold prevents a stale rest label from claiming recovery")
	context.safe_after_tick = 0
	var threat := LocalObservation.new()
	threat.handle = world.store.handle_at(1)
	threat.expires_tick = 20
	context.threat = threat
	context.observations[threat.handle.slot] = threat
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "UNSAFE_OR_SAFETY_HOLD", "An active observed threat prevents stale rest output from claiming recovery")
	context.threat = null
	context.observations.clear()
	context.suspended = true
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "INACTIVE_OR_AWAITING_SCAN", "Held life does not count as autonomous rest")
	context.suspended = false
	context.awaiting_resume_perception = true
	_check(ProductionBehaviorTrace.satiated_rest_evidence(context, intent, 10, 0.0) == "INACTIVE_OR_AWAITING_SCAN", "Awaiting resume scan cannot be reported as recovered")
	context.free()

func _check_registered_rest_output(world: SimulationWorld, observer: ProductionBehaviorProbe) -> void:
	var record: ProductionBehaviorTrace = observer._records[0]
	var context: AgentContext = world.ai.inspect(record.handle)
	# Only this unit fixture supplies satiation. The production protocol never
	# changes hunger, task state, or tree output to manufacture a recovery.
	world.store.hunger[world.store.resolve(record.handle)] = 0.0
	context.grazing_committed = false
	for step: int in 24:
		observer.before_step(world)
		world.ai.begin_frame()
		world.step()
		observer.after_step(world)
		if context.task_name == &"rest_satiated":
			break
	_check(context.task_name == &"rest_satiated", "Normal registered tree chooses the formal satiated rest branch")
	# The hunger input may change between BT jobs. Start this diagnostic unit
	# assertion only after the normal scheduler has published the new leaf.
	var intent: MotionIntent = world.intents.get_intent(record.handle, world.tick - 1)
	_check(intent != null, "Registered rest leaf publishes a valid intent")
	if intent != null:
		record.recovery_eligible_tick = world.tick - 1
		observer._observe_recovery(record, context, intent, context.position(), world.tick - 1)
	_check(record.recovery_tick < 0 and record.recovery_v2_kind == "VERIFIED_SATIATED_REST", "Actual rest output is added only to the new recovery definition")
	_check(not record.sheep_recovery_v2.is_empty(), "First recovery retains an evidence record")
	if not record.sheep_recovery_v2.is_empty():
		_check(record.sheep_recovery_v2["intent_owned"] and record.sheep_recovery_v2["mode"] == "STOP", "First recovery evidence retains the real tree's owned output")

func _check_capture_after_mark_dead() -> void:
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	config.attack_windup_ticks = 0
	var initial := ScenarioConfig.new()
	initial.sheep_count = 0
	initial.wolf_count = 0
	initial.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, initial)
	var observer := ProductionBehaviorProbe.new()
	observer.setup(world, 8, 42)
	world.ai.begin_frame()
	world.step()
	observer.after_step(world)
	world.queue_place(SimTypes.Species.WOLF, Vector2(100, 100))
	world.ai.begin_frame()
	world.step()
	observer.after_step(world)
	var target_record: ProductionBehaviorTrace = observer._records[0]
	var wolf: AgentHandle = observer._wolves[0]
	world.store.relocate(target_record.handle, Vector2(100, 100))
	world.store.relocate(wolf, Vector2(100, 100))
	world.store.hunger[world.store.resolve(target_record.handle)] = 0.53
	# Boundary fixture: land on a periodic sample and resolve a real accepted
	# interaction, preserving World's mark_dead -> captured -> remove ordering.
	world.tick = 59
	target_record.eligible_tick = world.tick
	target_record.observe_exposure_tick(world.tick, wolf)
	var attack := MotionIntent.new()
	attack.mode = SimTypes.IntentMode.ATTACK
	attack.behavior = SimTypes.Behavior.ATTACK
	attack.target = target_record.handle
	attack.owner_token = 100
	world.interaction._accept_attack(wolf, attack, world.tick)
	world.captured.connect(func(event: CaptureEvent) -> void:
		_check(world.store.resolve(event.target) < 0, "Actual capture signal runs after mark_dead invalidates live lookup")
	)
	world.ai.begin_frame()
	world.step()
	observer.after_step(world)
	_check(observer._captures.size() == 1 and not target_record.alive, "Actual interaction capture reaches the diagnostic lifecycle path")
	_check(target_record.exposure_last_end_tick == 60 and target_record.exposure_last_end_reason == "CAPTURE", "Capture closes geometric exposure at the completed n+1 boundary")
	_check(target_record.exposure_ticks == 1 and target_record.eligible_tick == 59, "Death preserves the original short-exposure denominator")
	_check(target_record.sheep_terminal["hunger_phase"] == "pre_step_before_capture", "Dead target keeps explicitly earlier scalar evidence")
	_check(is_equal_approx(target_record.sheep_terminal["hunger"], 0.53), "Capture cannot read another row through a negative dense index")
	_check(target_record.sheep_terminal["rest_evidence"] == "DEAD_BEFORE_LIFECYCLE_REMOVAL", "A dead target terminal state is never labeled satiated rest")
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
	_check(report["protocol"] == "production-two-flocks-v2" and report["stimulus_protocol"] == "production-two-flocks-v1", "New evidence schema names its unchanged stimulus schedule")
	_check(report["sheep_terminal"].size() >= 8, "Every sheep retains its terminal or pre-removal observation")
	for state: Dictionary in report["sheep_terminal"]:
		_check(state.has("rest_evidence") and state.has("hunger") and state.has("intent_owned"), "Sheep terminal evidence includes satiety and valid-intent ownership")
	_check(report["dog_contexts"].size() == 1124, "Four real dogs retain periodic context samples and the final endpoint")
	_check(report["dog_threats"].size() == 4496, "Dog explanations retain all four stimulus identities, including expired memory")
	for record: Dictionary in report["records"]:
		_check(is_finite(record["response_distance_pixels"]) and is_finite(record["peak_response_speed_px_per_second"]), "Physical response diagnostics remain finite")
	world.motion.close()
	world.ai.reset()
	world.free()
