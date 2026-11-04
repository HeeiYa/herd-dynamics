extends SceneTree
## Measurement contracts: catch-up totals, zero-step frames and full denominators.
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
	var config := SimulationConfig.new()
	config.instrument_enabled = true
	config.ai_budget_usec = 100000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 3
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	var view := WorldPresentation.new(world.probes)
	root.add_child(view)
	view.setup(world.store, world.intents, world.resources, config)
	var runner := SimulationRunner.new()
	root.add_child(runner)
	runner.set_process(false)
	runner.setup(world, view)
	runner.accumulator_seconds = config.fixed_dt * 3.25
	runner._last_usec = Time.get_ticks_usec()
	runner._process(0.0)
	_check(runner.last_step_count == 3, "Fixture publishes three catch-up steps in one frame")
	_check(world.probes.counts[Probes.Tag.VISUAL_PUBLISH] == 3, "Visual publication is timed once for each published step")
	_check(runner.frame_observe_usec >= world.probes.sums[Probes.Tag.VISUAL_PUBLISH], "Frame publication timer contains all three inner timers")
	_check(runner.frame_field_build_usec + runner.frame_field_sample_usec + runner.frame_exact_sample_usec <= runner.frame_phase_usec[4], "Motion components fit inside the accumulated motion phase")
	_check(world.probes.counts[Probes.Tag.BODY_PREPARE] == 1 and world.probes.counts[Probes.Tag.SHADOWS] == 1, "Body preparation and shadows run once per render frame")
	runner.accumulator_seconds = 0.0
	runner._last_usec = Time.get_ticks_usec()
	runner._process(0.0)
	_check(runner.last_step_count == 0, "Fixture includes an interpolation-only frame")
	_check(runner.frame_observe_usec == 0 and runner.frame_field_build_usec == 0 and runner.frame_moved_agent_steps == 0, "Zero-step frame cannot repeat the previous frame's totals")
	_check(world.probes.counts[Probes.Tag.VISUAL_PUBLISH] == 3, "Repeated present does not count an extra publication")
	var held: AgentHandle = world.store.handle_at(0)
	world.queue_hold(held)
	world._apply_commands()
	var unserved: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(500, 500))
	_check(world.ai.inspect(unserved).last_perception_tick == -1, "Fixture includes an unserved live sheep")
	var benchmark := BenchmarkSession.new()
	var quality: Array[Dictionary] = benchmark._quality_snapshot(world)
	_check(quality[SimTypes.Species.SHEEP]["active"] == 3, "Quality denominator excludes held lives and includes unserved lives")
	_check(quality[SimTypes.Species.SHEEP]["never_perceived"] >= 1, "Unserved lives remain explicit in the quality result")
	_check(quality[SimTypes.Species.SHEEP]["missing_or_expired_intent"] >= 1, "Missing intents are counted instead of omitted")
	_check_receipt_drain_window(world, runner)
	_check_pose_sample_bound(world)
	await _check_worker_backpressure_window()
	benchmark.free()
	runner.queue_free()
	view.queue_free()
	world.queue_free()
	await process_frame
	print("MEASUREMENT_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_pose_sample_bound(world: SimulationWorld) -> void:
	var executor := SimulationExecutor.new()
	var unprofiled := SimulationPublication.new()
	executor._sample_poses(world, unprofiled)
	_check(unprofiled.pose_profile == null, "Ordinary publication performs no per-row clock sampling")
	executor._pose_sample_count = 2
	var sampled := SimulationPublication.new()
	executor._sample_poses(world, sampled)
	_check(sampled.pose_profile.rows == 2 and sampled.pose_profile.changed == 0, "Bounded sample does not change unchanged pose reuse")
	_check(sampled.pose_profile.total_usec >= sampled.pose_profile.pool_usec + sampled.pose_profile.action_usec + sampled.pose_profile.direction_usec, "Nested sampled phases remain inside their sampled row total")
	_check(sampled.pose_profile.csv_values().size() == PublishedPose.SampleProfile.csv_columns().size(), "Diagnostic CSV sample values align with named columns")
	for dense: int in world.store.count:
		_check(sampled.pose_at(dense) == unprofiled.pose_at(dense), "Optional timing preserves the exact immutable pose result")
	var plain_history := PublishedPose.History.new()
	var timed_history := PublishedPose.History.new()
	var plain_previous: PublishedPose
	var timed_previous: PublishedPose
	var profile := PublishedPose.SampleProfile.new()
	var handle: AgentHandle = world.store.handle_at(0)
	for index: int in 64:
		var intent := MotionIntent.new()
		intent.behavior = SimTypes.Behavior.FLEE if index % 3 == 0 else SimTypes.Behavior.IDLE
		var facing: Vector2 = Vector2.from_angle(float(index / 2) * 0.1)
		var moving: bool = index % 5 != 0
		plain_previous = PublishedPose.sample(handle, SimTypes.Species.SHEEP, intent, moving, facing, index, plain_previous, plain_history)
		timed_previous = PublishedPose.sample(handle, SimTypes.Species.SHEEP, intent, moving, facing, index, timed_previous, timed_history, profile)
		_check(plain_previous.action == timed_previous.action and plain_previous.behavior == timed_previous.behavior and plain_previous.direction == timed_previous.direction and plain_previous.previous_direction == timed_previous.previous_direction and plain_previous.direction_tick == timed_previous.direction_tick and plain_previous.started_tick == timed_previous.started_tick and plain_previous.phase_direction == timed_previous.phase_direction, "Timing preserves action changes, direction hysteresis, pooling and clocks")
	_check(profile.changed > 0, "Sampled equivalence fixture exercises the changed-record path")

func _check_worker_backpressure_window() -> void:
	var config := SimulationConfig.new()
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 1
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var executor := SimulationExecutor.new()
	var started: Error = executor.start(config, scenario)
	_check(started == OK, "Backpressure measurement fixture starts a detached CPU worker")
	if started != OK:
		return
	var deadline: int = Time.get_ticks_usec() + 3000000
	var before: Dictionary = executor.diagnostic_counters(true)
	while int(before["queue_depth"]) < SimulationExecutor.PUBLICATION_LIMIT and Time.get_ticks_usec() < deadline:
		await process_frame
		before = executor.diagnostic_counters(true)
	_check(int(before["queue_depth"]) == SimulationExecutor.PUBLICATION_LIMIT, "Stalled consumer fills the reliable queue")
	OS.delay_msec(30)
	var after: Dictionary = executor.diagnostic_counters()
	_check(int(after["steps"]) == int(before["steps"]), "Full reliable queue blocks further world steps")
	_check(int(after["backpressure_wait_count"]) > int(before["backpressure_wait_count"]), "Backpressure count increases without a new publication")
	_check(int(after["backpressure_wait_usec"]) - int(before["backpressure_wait_usec"]) >= 20000, "Boundary counters include actual wait time even without delivered telemetry")
	_check(int(after["queue_peak"]) == SimulationExecutor.PUBLICATION_LIMIT, "Queue high-water measurement is available independently of display")
	after["steps"] = -100
	_check(int(executor.diagnostic_counters()["steps"]) >= 0, "Counter snapshots cannot mutate worker accumulators")
	for delivery_index: int in SimulationExecutor.PUBLICATION_LIMIT:
		executor.poll_delivery()
	var previous_steps: int = int(before["steps"])
	deadline = Time.get_ticks_usec() + 2000000
	while int(executor.diagnostic_counters()["steps"]) <= previous_steps and Time.get_ticks_usec() < deadline:
		await process_frame
	_check(int(executor.diagnostic_counters()["steps"]) > previous_steps, "Worker resumes after the reliable consumer drains the queue")
	executor.close()

func _check_receipt_drain_window(world: SimulationWorld, runner: SimulationRunner) -> void:
	var benchmark := ExecutionBenchmark.new()
	benchmark._access = SimulationAccess.local(world)
	benchmark._started_usec = Time.get_ticks_usec() - 1000000
	benchmark._sampling = true
	benchmark._collecting_receipts = true
	benchmark._controls[1] = true
	runner.committed_frames = 10
	var end_tick: int = world.tick
	var sample_end: Dictionary = benchmark._finish_sampling(runner)
	world.tick += 3
	runner.committed_frames += 2
	var late_step := SimulationTelemetry.new()
	late_step.tick = world.tick
	late_step.step_usec = 1
	benchmark._on_publication(late_step)
	benchmark._receive_pulse(Time.get_ticks_usec())
	var receipt := SimulationCommand.Receipt.new()
	receipt.request_id = 1
	receipt.accepted = true
	receipt.submitted_usec = Time.get_ticks_usec() - 1000
	benchmark._on_receipt(receipt)
	_check(sample_end["tick"] == end_tick and sample_end["display_commits"] == 10, "Receipt drain cannot change the frozen throughput or display window")
	_check(benchmark._steps.is_empty() and benchmark._pulses.is_empty(), "Drain-only steps and dispatch pulses stay outside steady-window samples")
	_check(benchmark._received_controls == 1 and benchmark._receipts.size() == 1, "Late receipts are still collected independently of the closed frame window")
	benchmark.free()
