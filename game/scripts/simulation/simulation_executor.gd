class_name SimulationExecutor
extends RefCounted
## One thread owns the entire detached world, including BT and RenderingDevice.
## Locks exchange ownership only. UI never waits for a simulation step or GPU.
const PUBLICATION_LIMIT: int = 8
const COMMAND_LIMIT: int = 256
var _thread := Thread.new()
var _mutex := Mutex.new()
var _commands: Array[SimulationCommand] = []
var _deliveries: Array[SimulationDelivery] = []
var _latest: SimulationPublication
var _stop_requested: bool = false
var _config: SimulationConfig
var _initial: ScenarioConfig

# Worker-only state; never read directly by the UI.
var _paused: bool = false
var _speed: float = 1.0
var _accumulator_seconds: float = 0.0
var _single_steps: int = 0
var _step_requests: Array[SimulationCommand] = []
var _selected: AgentHandle
var _sequence: int = 0
var _awaiting_step: Array[SimulationCommand] = []
var _notices: Array[SimulationNotice] = []
var _poses: Array[PublishedPose] = []
var _pose_epoch: int = -1
var _motion_completed_usec: int = 0
var _previous_motion_completed_usec: int = 0

func start(config: SimulationConfig, scenario: ScenarioConfig) -> Error:
	_config = config.duplicate() as SimulationConfig
	_config.detached_ai = true
	_config.ai_budget_usec = _config.worker_ai_budget_usec
	_initial = scenario.duplicate(true) as ScenarioConfig
	return _thread.start(_run)

func enqueue(command: SimulationCommand) -> bool:
	_mutex.lock()
	var accepted: bool = not _stop_requested and _commands.size() < COMMAND_LIMIT
	if accepted:
		_commands.append(command)
	_mutex.unlock()
	return accepted

func poll_delivery() -> SimulationDelivery:
	if not _mutex.try_lock():
		return null
	var result: SimulationDelivery = _deliveries.pop_front() if not _deliveries.is_empty() else null
	_mutex.unlock()
	return result

func poll_state(delivered_sequence: int) -> SimulationPublication:
	if not _mutex.try_lock():
		return null
	var result: SimulationPublication
	if _latest != null and _latest.sequence <= delivered_sequence:
		result = _latest
		_latest = null
	_mutex.unlock()
	return result

func close() -> void:
	if not _thread.is_started():
		return
	_mutex.lock()
	_stop_requested = true
	_mutex.unlock()
	# Shutdown is the only joining point, never a frame update or input callback.
	_thread.wait_to_finish()

func _run() -> void:
	var world := SimulationWorld.new()
	world.captured.connect(_capture_notice)
	world.observer_event.connect(_observer_notice)
	world.setup(_config, _initial)
	_publish(world, 0)
	var last_usec: int = Time.get_ticks_usec()
	var consecutive_steps: int = 0
	while true:
		_mutex.lock()
		var stopping: bool = _stop_requested
		var room: bool = _deliveries.size() < PUBLICATION_LIMIT
		var commands: Array[SimulationCommand] = _commands
		_commands = []
		_mutex.unlock()
		if stopping:
			for pending: SimulationCommand in commands + _awaiting_step + _step_requests:
				_receipt(pending, world, false, "executor_closed")
			if not _notices.is_empty():
				_publish(world, 0, true)
			break
		var now: int = Time.get_ticks_usec()
		if not _paused:
			_accumulator_seconds += float(now - last_usec) * _speed / 1000000.0
		last_usec = now
		var control_changed: bool = _apply_commands(world, commands)
		if not room:
			# Bounded backpressure retains ticks and reliable events. It never
			# holds the mailbox lock or makes the frontend wait for this thread.
			OS.delay_msec(1)
			continue
		if _single_steps > 0 or (not _paused and _accumulator_seconds >= _config.fixed_dt):
			var started: int = Time.get_ticks_usec()
			world.ai.begin_frame()
			world.step()
			var step_usec: int = Time.get_ticks_usec() - started
			if _single_steps > 0:
				_single_steps -= 1
				_receipt(_step_requests.pop_front(), world, true, "completed_single_step")
			else:
				_accumulator_seconds -= _config.fixed_dt
			for command: SimulationCommand in _awaiting_step:
				_receipt(command, world, true, "processed_at_stage_zero")
			_awaiting_step.clear()
			_publish(world, step_usec)
			consecutive_steps += 1
			if consecutive_steps >= _config.max_catchup_steps:
				consecutive_steps = 0
				OS.delay_msec(1)
		else:
			if control_changed or not _notices.is_empty():
				_publish(world, 0)
			consecutive_steps = 0
			OS.delay_msec(1)
	world.motion.close()
	world.ai.reset()
	world.free()

func _apply_commands(world: SimulationWorld, commands: Array[SimulationCommand]) -> bool:
	var changed: bool = false
	for command: SimulationCommand in commands:
		if command.epoch != world.store.epoch:
			_receipt(command, world, false, "stale_epoch")
			continue
		match command.kind:
			SimulationCommand.Kind.PAUSE:
				_paused = command.integer != 0
				world.record_observer_event("pause", {"value": _paused})
			SimulationCommand.Kind.SINGLE_STEP:
				_paused = true
				_single_steps += 1
				_step_requests.append(command)
				world.record_observer_event("single_step")
				changed = true
				continue
			SimulationCommand.Kind.SPEED:
				_speed = command.scalar
				world.record_observer_event("time_scale", {"value": _speed})
			SimulationCommand.Kind.RESET:
				for pending: SimulationCommand in _awaiting_step:
					_receipt(pending, world, false, "discarded_by_reset")
				_awaiting_step.clear()
				for pending: SimulationCommand in _step_requests:
					_receipt(pending, world, false, "discarded_by_reset")
				_step_requests.clear()
				world.reset(command.scenario)
				_accumulator_seconds = 0.0
				_single_steps = 0
				_selected = null
			SimulationCommand.Kind.SELECT:
				_selected = command.handle
			SimulationCommand.Kind.STALL:
				var duration_usec: int = clampi(command.integer, 0, 500) * 1000
				if command.scalar == 0.0:
					OS.delay_usec(duration_usec)
				else:
					var deadline: int = Time.get_ticks_usec() + duration_usec
					while Time.get_ticks_usec() < deadline:
						var busy_work: float = sin(float(Time.get_ticks_usec()))
						assert(is_finite(busy_work))
			_:
				_queue_world_command(world, command)
				continue
		_receipt(command, world, true, "applied_control")
		changed = true
	return changed

func _queue_world_command(world: SimulationWorld, command: SimulationCommand) -> void:
	var needs_life: bool = command.kind in [SimulationCommand.Kind.HOLD, SimulationCommand.Kind.DROP, SimulationCommand.Kind.REMOVE, SimulationCommand.Kind.CANCEL_GRAB]
	if needs_life and not world.store.is_alive(command.handle):
		_receipt(command, world, false, "expired_life")
		return
	match command.kind:
		SimulationCommand.Kind.SPAWN:
			world.queue_spawn(command.integer, int(command.scalar))
		SimulationCommand.Kind.PLACE:
			world.queue_place(command.integer, command.position)
		SimulationCommand.Kind.REMOVE:
			world.queue_remove(command.handle)
		SimulationCommand.Kind.HOLD:
			world.queue_hold(command.handle)
		SimulationCommand.Kind.DROP:
			world.queue_drop(command.handle, command.position)
		SimulationCommand.Kind.CANCEL_GRAB:
			var returning: bool = world.cancel_grab(command.handle, Vector2.ZERO)
			for index: int in range(_awaiting_step.size() - 1, -1, -1):
				var pending: SimulationCommand = _awaiting_step[index]
				if pending.handle != null and pending.handle.same_life(command.handle) and pending.kind in [SimulationCommand.Kind.HOLD, SimulationCommand.Kind.DROP]:
					_receipt(pending, world, false, "cancelled_by_observer")
					_awaiting_step.remove_at(index)
			if not returning:
				_receipt(command, world, true, "withdrawn_before_stage_zero")
				return
		SimulationCommand.Kind.TUNING:
			if not world.queue_tuning(command.tuning):
				_receipt(command, world, false, "invalid_parameter")
				return
	_awaiting_step.append(command)

func _receipt(command: SimulationCommand, world: SimulationWorld, accepted: bool, reason: String) -> void:
	var receipt := SimulationCommand.Receipt.new()
	receipt.request_id = command.request_id
	receipt.epoch = world.store.epoch
	receipt.tick = world.tick
	receipt.accepted = accepted
	receipt.reason = reason
	receipt.submitted_usec = command.submitted_usec
	receipt.completed_usec = Time.get_ticks_usec()
	var notice := SimulationNotice.new()
	notice.kind = SimulationNotice.Kind.RECEIPT
	notice.receipt = receipt
	_notices.append(notice)

func _capture_notice(event: CaptureEvent) -> void:
	var notice := SimulationNotice.new()
	notice.kind = SimulationNotice.Kind.CAPTURE
	notice.capture = event
	if event.target.slot < _poses.size():
		var pose: PublishedPose = _poses[event.target.slot]
		if pose != null and pose.handle.same_life(event.target):
			notice.pose = pose
	_notices.append(notice)

func _observer_notice(event: Dictionary) -> void:
	var notice := SimulationNotice.new()
	notice.kind = SimulationNotice.Kind.OBSERVER
	notice.observer = event.duplicate(true)
	_notices.append(notice)

func _sample_poses(world: SimulationWorld, publication: SimulationPublication) -> void:
	if _pose_epoch != world.store.epoch:
		_poses.clear()
		_pose_epoch = world.store.epoch
	_poses.resize(world.store.capacity)
	for dense: int in world.store.count:
		var handle: AgentHandle = world.store.handle_at(dense)
		var previous: PublishedPose = _poses[handle.slot]
		var pose: PublishedPose = PublishedPose.sample(world, dense, previous)
		var old_behavior: int = previous.behavior if previous != null and previous.handle.same_life(handle) else SimTypes.Behavior.IDLE
		if pose.behavior != old_behavior:
			var notice := SimulationNotice.new()
			notice.kind = SimulationNotice.Kind.BEHAVIOR
			notice.pose = pose
			notice.position = world.store.position_current[dense]
			notice.previous_behavior = old_behavior
			notice.tick = maxi(0, world.tick - 1)
			notice.held = world.store.held[dense] != 0
			_notices.append(notice)
		_poses[handle.slot] = pose
		publication.poses.append(pose)

func _publish(world: SimulationWorld, step_usec: int, closing: bool = false) -> void:
	var completed_usec: int = Time.get_ticks_usec()
	var publication: SimulationPublication = SimulationPublication.capture(world, _selected)
	if _motion_completed_usec == 0 or _pose_epoch != world.store.epoch:
		_previous_motion_completed_usec = completed_usec
		_motion_completed_usec = completed_usec
	elif step_usec > 0:
		_previous_motion_completed_usec = _motion_completed_usec
		_motion_completed_usec = completed_usec
	var pose_started: int = Time.get_ticks_usec()
	_sample_poses(world, publication)
	publication.pose_usec = Time.get_ticks_usec() - pose_started
	publication.completed_usec = _motion_completed_usec
	publication.previous_completed_usec = _previous_motion_completed_usec
	publication.sequence = _sequence
	_sequence += 1
	publication.paused = _paused
	publication.speed = _speed
	publication.backlog_seconds = _accumulator_seconds
	publication.step_usec = step_usec
	publication.published_usec = Time.get_ticks_usec()
	publication.snapshot_usec = publication.published_usec - completed_usec
	var delivery := SimulationDelivery.new()
	delivery.sequence = publication.sequence
	delivery.notices = _notices
	delivery.metrics = publication.telemetry_copy()
	_notices = []
	_mutex.lock()
	# One final receipt-only publication may follow the full queue during close.
	assert(_deliveries.size() < PUBLICATION_LIMIT or closing)
	_deliveries.append(delivery)
	# Release an overwritten full state outside the mailbox lock. Destruction
	# can walk many reference-counted records; input enqueue must not wait on it.
	var replaced: SimulationPublication = _latest
	_latest = publication
	_mutex.unlock()
	replaced = null
