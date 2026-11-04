extends SceneTree
## Fixed storage, population accounting, owner-safe turnover and bounded logging.
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
	_check_histogram()
	_check_replacement_counts()
	_check_sample_sequences()
	_check_turnover()
	_check_spawn_allowance()
	_check_capture_precedes_pending_remove()
	_check_turnover_window_boundary()
	_check_log_admission()
	await _check_log_drain()
	await process_frame
	print("ENDURANCE_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_histogram() -> void:
	var histogram := EnduranceHistogram.new(0.1, 1.0, "ms")
	var capacity: int = histogram._buckets.size()
	for sample: float in [0.0, 0.1, 0.99, 1.0, 2.0]:
		histogram.add(sample)
	histogram.add(NAN)
	histogram.add(-1.0)
	_check(histogram.count == 5 and histogram.invalid == 2, "Invalid measurements do not enter histogram denominator")
	_check(histogram.overflow == 1 and histogram.maximum == 2.0, "Overflow retains its real maximum")
	_check(histogram.percentile(0.99)["overflow"], "Tail in overflow is not clamped to the configured limit")
	var interval: Dictionary = histogram.percentile(0.6)
	_check(interval["lower"] <= 0.99 and interval["upper"] >= 0.99, "Finite percentile names a containing interval")
	for sample: int in 100000:
		histogram.add(0.2)
	_check(histogram._buckets.size() == capacity, "Histogram storage does not grow with run length")
	var exported: Dictionary = histogram.summary(true)
	exported["buckets"][0] = 999999
	_check(histogram._buckets[0] == 1, "Exported bucket arrays cannot mutate the owner accumulator")

func _check_replacement_counts() -> void:
	_check(EnduranceProbe.replacement_count(100, 100, 0, 0) == 0, "Full population is not supplemented")
	_check(EnduranceProbe.replacement_count(100, 90, 10, 0) == 0, "Already pending births prevent overfill")
	_check(EnduranceProbe.replacement_count(100, 100, 0, 7) == 7, "Scheduled live removals are replaced at next stage zero")
	_check(EnduranceProbe.replacement_count(100, 95, 3, 2) == 4, "Death, pending births and turnover share one deficit")

func _make_world(count: int = 8) -> SimulationWorld:
	var config := SimulationConfig.new()
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = count
	scenario.wolf_count = 1
	scenario.dog_count = 1
	var world := SimulationWorld.new()
	world.setup(config, scenario)
	return world

func _check_sample_sequences() -> void:
	var benchmark := EnduranceBenchmark.new()
	benchmark._last_worker_sample = 10
	_check(not benchmark._observe_sample_sequence(10), "The same owner sample is never counted twice")
	_check(benchmark._observe_sample_sequence(12) and benchmark._missed_worker_samples == 1, "Latest-sample phase drift is retained as a detail coverage gap")
	_check(benchmark._steps == 0, "Sample coverage gaps do not alter the reliable step denominator")
	benchmark.free()

func _publication(world: SimulationWorld, timestamp: int, sequence: int) -> SimulationPublication:
	var result := SimulationPublication.new()
	result.epoch = world.store.epoch
	result.tick = world.tick
	result.published_usec = timestamp
	result.sequence = sequence
	result.step_usec = 1
	result.counts = world.counts()
	result.held_counts = world.held_counts()
	result.active_agents = world.store.count
	result.grass_consumed = world.interaction.grass_consumed
	return result

func _step(world: SimulationWorld) -> void:
	world.ai.begin_frame()
	world.step()

func _check_turnover() -> void:
	var world: SimulationWorld = _make_world()
	var probe := EnduranceProbe.new()
	probe.setup(world, "turnover", PackedInt32Array([8, 1, 1]))
	_step(world)
	probe.observe_publication(_publication(world, Time.get_ticks_usec(), 0))
	_check(world.counts() == PackedInt32Array([8, 1, 1]), "Ordinary initial generation reaches all species")
	var original: AgentHandle = world.store.handle_at(0)
	probe.turnover_counts = PackedInt32Array([5, 1, 1])
	probe._queue_turnover()
	probe._replenish(world.counts(), false)
	probe._replenish(world.counts(), false)
	_check(world.pending_spawns == PackedInt32Array([5, 1, 1]), "Repeated correction does not enqueue duplicate replacements")
	_check(world.store.is_alive(original), "Protocol schedules deletion without writing the store immediately")
	_step(world)
	probe.observe_publication(_publication(world, Time.get_ticks_usec(), 1))
	_check(world.counts() == PackedInt32Array([8, 1, 1]), "Next normal stage zero removes before creating replacements")
	_check(not world.store.is_alive(original), "Old full identity is invalid after turnover")
	var replacement: AgentHandle = world.store.handle_at(world.store.slot_to_dense[original.slot])
	_check(replacement.slot == original.slot and replacement.generation > original.generation, "Reused slot carries a new generation")
	_check(probe._pending_removals.is_empty() and probe._error_count == 0, "Only confirmed removals settle the bounded pending set")
	var future: int = Time.get_ticks_usec() + 1000000
	_check(probe.arm_window(future, future + 1000000), "Window is armed ahead of its monotonic start")
	_check(not probe.arm_window(future, future + 2000000), "Window cannot be silently restarted")
	_step(world)
	probe.observe_publication(_publication(world, future, 2))
	_step(world)
	probe.observe_publication(_publication(world, future + 1000000, 3))
	_check(probe.finished and probe.final_report["steps"] == 1, "End-exclusive publication boundary does not count the drain step")
	_check(probe.final_report["first_step_sequence"] == 2 and probe.final_report["last_step_sequence"] == 2, "Exact owner sequences support reliable-delivery accounting")
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_log_admission() -> void:
	var logger := ObserverSessionLog.new()
	_check(not logger.try_append_endurance_sample({"world": AgentStore.new()}), "Live objects cannot enter the diagnostic log")
	_check(not logger.try_append_endurance_sample({"bulk": range(100)}), "Large arrays cannot disguise unbounded sampling rows")
	var release := Semaphore.new()
	var result: Error = logger._writer.start(func() -> void: release.wait())
	_check(result == OK, "Admission fixture owns a separate sleeping writer")
	if result == OK:
		logger._lines.resize(ObserverSessionLog.QUEUE_LIMIT - ObserverSessionLog.ENDURANCE_EVENT_RESERVE)
		_check(not logger.try_append_endurance_sample({"tick": 1}), "Statistics cannot consume reserved event queue capacity")
		logger._lines.clear()
		release.post()
		logger._writer.wait_to_finish()
	_check(logger.writer_status()["dropped"] == 3, "Rejected statistics remain visible in final completeness checks")

func _check_log_drain() -> void:
	var world: SimulationWorld = _make_world()
	var access: SimulationAccess = SimulationAccess.local(world)
	var runner := SimulationRunner.new()
	var logger := ObserverSessionLog.new()
	var path: String = ProjectSettings.globalize_path("res://").path_join("../endurance-log-test-%d.jsonl" % Time.get_ticks_usec())
	var started: bool = logger.start(access, runner, path)
	_check(started, "The existing observer writer supports diagnostic output")
	if started:
		var accepted: bool = false
		# A busy mutex is a reported rejection, so this fixture uses one attempt
		# after the initial session row drains rather than hiding retries in production.
		await process_frame
		accepted = logger.try_append_endurance_sample({"event": "endurance_test", "tick": 1, "counts": [8, 1, 1]})
		_check(accepted, "Small scalar diagnostic row is accepted by the same writer")
		logger.close()
		var state: Dictionary = logger.writer_status()
		_check(not state["failed"] and state["accepted"] == state["written"], "Close drains every accepted row before final accounting")
		_check(state["queue_depth"] == 0 and state["inflight"] == 0, "No queued or in-flight rows survive close")
		_check(not access.observer_event_ready.is_valid(), "Closing detaches only this writer's observer gate")
		var contents: String = FileAccess.get_file_as_string(path)
		_check(contents.contains("endurance_test") and contents.contains("session"), "Native event and diagnostic records both reach the file")
	runner.free()
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_spawn_allowance() -> void:
	var world: SimulationWorld = _make_world(80)
	var probe := EnduranceProbe.new()
	probe.setup(world, "turnover", PackedInt32Array([80, 1, 1]))
	_step(world)
	probe.observe_publication(_publication(world, Time.get_ticks_usec(), 0))
	_check(world.counts() == PackedInt32Array([64, 0, 0]), "Protocol preserves the shared 64-birth stage-zero limit")
	_check(world.pending_spawns == PackedInt32Array([16, 1, 1]), "Uncreated wolves and dogs remain in the real pending denominator")
	_step(world)
	probe.observe_publication(_publication(world, Time.get_ticks_usec(), 1))
	_check(world.counts() == PackedInt32Array([80, 1, 1]) and world.pending_spawns == PackedInt32Array([0, 0, 0]), "Correction does not overfill during multi-step initial generation")
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_capture_precedes_pending_remove() -> void:
	var world: SimulationWorld = _make_world()
	var probe := EnduranceProbe.new()
	probe.setup(world, "turnover", PackedInt32Array([8, 1, 1]))
	_step(world)
	probe.observe_publication(_publication(world, Time.get_ticks_usec(), 0))
	var victim: AgentHandle = world.store.handle_at(0)
	probe.turnover_counts = PackedInt32Array([1, 0, 0])
	probe._queue_turnover()
	probe._replenish(world.counts(), false)
	# Diagnostic ordering fixture: a real dead identity is published before
	# lifecycle removal, as InteractionSystem does. No AI outcome is manufactured.
	var event := CaptureEvent.new()
	event.target = victim
	event.tick = world.tick
	world.store.mark_dead(victim)
	world.captured.emit(event)
	world._remove(victim)
	probe._replenish(world.counts(), false)
	_check(world.pending_spawns[0] == 1, "Capture of a scheduled removal does not request two births")
	_check(probe._pending_removals.is_empty() and probe._pending_removal_counts[0] == 0, "Capture retires the same full identity from the removal set")
	_step(world)
	probe.observe_publication(_publication(world, Time.get_ticks_usec(), 1))
	_check(world.counts() == PackedInt32Array([8, 1, 1]) and probe._error_count == 0, "Stale queued removal cannot delete the replacement life")
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_turnover_window_boundary() -> void:
	var world: SimulationWorld = _make_world()
	var probe := EnduranceProbe.new()
	probe.setup(world, "turnover", PackedInt32Array([8, 1, 1]))
	probe.turnover_ticks = 1
	probe.turnover_counts = PackedInt32Array([5, 0, 0])
	_step(world)
	probe.observe_publication(_publication(world, Time.get_ticks_usec(), 0))
	var future: int = Time.get_ticks_usec() + 1000000
	probe.arm_window(future, future + 1000000)
	_step(world)
	probe.observe_publication(_publication(world, future, 1))
	_step(world)
	probe.observe_publication(_publication(world, future + 500000, 2))
	_step(world)
	probe.observe_publication(_publication(world, future + 1000000, 3))
	var report: Dictionary = probe.final_report
	_check(report["turnover_rounds_scheduled"] == 1 and report["protocol_removals"] == [0, 0, 0], "Last-window scheduling is distinct from the next excluded step's removals")
	_check(report["births"] == [0, 0, 0] and report["steps"] == 2, "Drain does not inflate birth or completed-step numerators")
	_check(report["pending_spawns_at_last_window_publication"] == [0, 0, 0], "Publication endpoint retains its pre-scheduling pending count")
	_check(report["pending_spawns_after_last_window_protocol"] == [5, 0, 0] and report["pending_removals_after_last_window_protocol"] == [5, 0, 0], "Post-publication protocol endpoint explains outstanding replacements")
	_check(report["pending_spawns_at_finish"] == [0, 0, 0], "Actual finish state is retained separately after pending replacements complete")
	world.motion.close()
	world.ai.reset()
	world.free()
