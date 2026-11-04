extends SceneTree
## Test coalescing independently of wall-clock scheduling: one real producer,
## an intentionally stalled consumer, and retained immutable old publications.
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
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.detached_ai = true
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 1
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	world.ai.begin_frame()
	world.step()
	var executor := SimulationExecutor.new()
	var handle: AgentHandle = world.store.handle_at(0)
	var first_pose: PublishedPose
	var pinned: SimulationPublication
	for sequence: int in SimulationExecutor.PUBLICATION_LIMIT:
		var intent := MotionIntent.new()
		intent.behavior = SimTypes.Behavior.FLEE if sequence % 2 == 0 else SimTypes.Behavior.IDLE
		intent.expires_tick = 100
		world.intents.write(handle, intent)
		world.tick = sequence + 1
		world.store.position_current[0] = Vector2(sequence, 100)
		if sequence == 3:
			var event := CaptureEvent.new()
			event.target = handle
			event.tick = world.tick
			event.position = Vector2(3, 100)
			event.previous_position = Vector2(2, 100)
			executor._capture_notice(event)
		executor._publish(world, 1)
		if sequence == 0:
			pinned = executor._latest
			first_pose = pinned.poses[0]
	_check(executor._deliveries.size() == 8, "Eight reliable batches are retained at the capacity boundary")
	_check(executor.poll_state(-1) == null, "State cannot overtake undelivered reliable facts")
	var behavior_count: int = 0
	var capture_count: int = 0
	for sequence: int in 8:
		var delivery: SimulationDelivery = executor.poll_delivery()
		_check(delivery.sequence == sequence, "Reliable batches preserve all sequence numbers")
		_check(not delivery.metrics is SimulationPublication, "Reliable telemetry does not retain full display states")
		for notice: SimulationNotice in delivery.notices:
			if notice.kind == SimulationNotice.Kind.BEHAVIOR:
				_check(notice.tick == sequence, "Even transient behavior changes retain their original clock")
				behavior_count += 1
			if notice.kind == SimulationNotice.Kind.CAPTURE:
				_check(notice.capture.previous_position == Vector2(2, 100) and notice.pose.handle.same_life(handle), "Capture owns retired-life visual facts")
				capture_count += 1
	_check(behavior_count == 8 and capture_count == 1, "Coalescing loses no intermediate behavior or capture facts")
	var newest: SimulationPublication = executor.poll_state(7)
	_check(newest.sequence == 7 and executor.poll_state(7) == null, "Display mailbox yields only the newest unread state")
	_check(pinned.store.position_current[0] == Vector2(0, 100) and first_pose.behavior == SimTypes.Behavior.FLEE, "Delivered snapshots and poses remain immutable after later publications")
	_check(newest.poses[0].behavior == SimTypes.Behavior.IDLE, "Latest state is self-contained after seven skipped versions")
	var motion_clock: int = newest.completed_usec
	_check(newest.previous_completed_usec <= motion_clock, "Display age retains the actual two wall-clock endpoints")
	executor._publish(world, 0)
	executor.poll_delivery()
	_check(executor.poll_state(8).completed_usec == motion_clock, "Control-only publications cannot refresh the motion age")
	world.reset(scenario)
	executor._publish(world, 0)
	executor.poll_delivery()
	var reset: SimulationPublication = executor.poll_state(9)
	_check(reset.epoch != pinned.epoch and reset.completed_usec >= motion_clock, "Reset establishes a new epoch and display clock")
	_check(pinned.store.is_alive(handle), "Reset leaves already delivered prior-epoch state intact")
	var access := SimulationAccess.new()
	access.executor = executor
	access.publication = reset
	access.delivered_sequence = 9
	access.observer_event_ready = func() -> bool: return false
	var received: Array[Dictionary] = []
	access.observer_event.connect(func(record: Dictionary) -> void: received.append(record))
	executor._observer_notice({"event": "disk_backpressure", "tick": world.tick})
	executor._publish(world, 0)
	access.pump_events(Time.get_ticks_usec() + 1000)
	_check(received.is_empty() and access.delivered_sequence == 9, "A full evidence queue defers reliable delivery without consuming its event")
	access.observer_event_ready = Callable()
	access.pump_events(Time.get_ticks_usec() + 3000)
	_check(received.size() == 1 and access.delivered_sequence == 10, "Delivery resumes exactly once after evidence backpressure clears")
	world.motion.close()
	world.ai.reset()
	world.free()
	print("PUBLICATION_STREAM_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
