class_name SimulationExecutor
extends RefCounted
## One thread owns the entire detached world, including BT and RenderingDevice.
## Locks exchange ownership only. UI never waits for a simulation step or GPU.
const PUBLICATION_LIMIT: int = 8
const COMMAND_LIMIT: int = 256
enum WaitReason { BACKPRESSURE, CATCHUP_YIELD, IDLE }
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
var _pose_histories: Array[PublishedPose.History] = []
var _pose_buffers: Array[PoseBuffer] = []
var _pose_epoch: int = -1
var _motion_completed_usec: int = 0
var _previous_motion_completed_usec: int = 0
var _pose_sample_count: int = 0
var _behavior_probe: ProductionBehaviorProtocol
# Only a completed, primitive report crosses the mutex; the UI never sees probe/World.
var _behavior_report: Dictionary = {}

# Diagnostic accumulators are updated/read under the mailbox mutex. Sampling
# never borrows the live World. Totals span resets; epoch/tick label the latest
# completed publication. GPU totals belong to that completed step endpoint.
var _diagnostic_totals: Dictionary[String, int] = {
	"backpressure_wait_count": 0, "backpressure_wait_usec": 0,
	"catchup_yield_usec": 0, "idle_wait_usec": 0, "step_usec": 0,
	"snapshot_usec": 0, "ai_used_usec": 0, "motion_usec": 0,
	"interaction_usec": 0, "grid_usec": 0, "commands_usec": 0,
	"coordination_usec": 0, "steps": 0, "publications": 0,
}
var _backpressure_started_usec: int = 0
var _diagnostic_queue_peak: int = 0
var _diagnostic_tick: int = 0
var _diagnostic_epoch: int = 0
var _diagnostic_completed_usec: int = 0
var _diagnostic_motion: Dictionary = {}

func start(config: SimulationConfig, scenario: ScenarioConfig) -> Error:
	_config = config.duplicate() as SimulationConfig
	_config.detached_ai = true
	_config.ai_budget_usec = _config.worker_ai_budget_usec
	_initial = scenario.duplicate(true) as ScenarioConfig
	# Benchmark-only bounded timing, disabled in ordinary play and regressions.
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--pose-samples="):
			_pose_sample_count = clampi(int(argument.trim_prefix("--pose-samples=")), 0, 64)
	return _thread.start(_run)

## Called only at diagnostic window boundaries. An in-flight not-room sleep is
## included up to read_usec, so a fully backpressured window cannot report zero.
func diagnostic_counters(reset_queue_peak: bool = false) -> Dictionary:
	_mutex.lock()
	var now: int = Time.get_ticks_usec()
	# A duplicate of the typed accumulator retains its int-only value type;
	# copy into an untyped diagnostic boundary before adding nested metadata.
	var result: Dictionary = {}
	result.merge(_diagnostic_totals)
	if _backpressure_started_usec > 0:
		result["backpressure_wait_usec"] += now - _backpressure_started_usec
	result["read_usec"] = now
	result["completed_publication_usec"] = _diagnostic_completed_usec
	result["epoch"] = _diagnostic_epoch
	result["tick"] = _diagnostic_tick
	result["queue_depth"] = _deliveries.size()
	result["queue_peak"] = _diagnostic_queue_peak
	result["motion_backend_metrics"] = _diagnostic_motion.duplicate(true)
	result["pose_samples_per_publication"] = _pose_sample_count
	if reset_queue_peak:
		_diagnostic_queue_peak = _deliveries.size()
	_mutex.unlock()
	return result

func _wait_one_millisecond(reason: WaitReason) -> void:
	var started: int = Time.get_ticks_usec()
	if reason == WaitReason.BACKPRESSURE:
		_mutex.lock()
		_backpressure_started_usec = started
		_diagnostic_totals["backpressure_wait_count"] += 1
		_mutex.unlock()
	OS.delay_msec(1)
	_mutex.lock()
	var elapsed: int = Time.get_ticks_usec() - started
	match reason:
		WaitReason.BACKPRESSURE:
			_diagnostic_totals["backpressure_wait_usec"] += elapsed
			_backpressure_started_usec = 0
		WaitReason.CATCHUP_YIELD:
			_diagnostic_totals["catchup_yield_usec"] += elapsed
		WaitReason.IDLE:
			_diagnostic_totals["idle_wait_usec"] += elapsed
	_mutex.unlock()

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

## Ownership transfer once, after the diagnostic protocol has completed.
func take_behavior_report() -> Dictionary:
	_mutex.lock()
	var result: Dictionary = _behavior_report
	_behavior_report = {}
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
	_setup_behavior_probe(world)
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
			_wait_one_millisecond(WaitReason.BACKPRESSURE)
			continue
		if _single_steps > 0 or (not _paused and _accumulator_seconds >= _config.fixed_dt):
			if _behavior_probe != null:
				_behavior_probe.before_step(world)
			var started: int = Time.get_ticks_usec()
			world.ai.begin_frame()
			world.step()
			var step_usec: int = Time.get_ticks_usec() - started
			if _behavior_probe != null:
				_behavior_probe.after_step(world)
			if _single_steps > 0:
				_single_steps -= 1
				_receipt(_step_requests.pop_front(), world, true, "completed_single_step")
			else:
				_accumulator_seconds -= _config.fixed_dt
			for command: SimulationCommand in _awaiting_step:
				_receipt(command, world, true, "processed_at_stage_zero")
			_awaiting_step.clear()
			_publish(world, step_usec)
			_finish_behavior_probe()
			consecutive_steps += 1
			if consecutive_steps >= _config.max_catchup_steps:
				consecutive_steps = 0
				_wait_one_millisecond(WaitReason.CATCHUP_YIELD)
		else:
			if control_changed or not _notices.is_empty():
				_publish(world, 0)
			consecutive_steps = 0
			_wait_one_millisecond(WaitReason.IDLE)
	world.motion.close()
	world.ai.reset()
	world.free()

func _setup_behavior_probe(world: SimulationWorld) -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if not arguments.has("--benchmark=production-behavior"):
		return
	var sheep_count: int = 80
	var behavior_case: String = "two-flocks"
	for argument: String in arguments:
		if argument.begins_with("--sheep="):
			sheep_count = int(argument.trim_prefix("--sheep="))
		elif argument.begins_with("--behavior-case="):
			behavior_case = argument.trim_prefix("--behavior-case=")
	match behavior_case:
		"two-flocks":
			_behavior_probe = ProductionBehaviorProbe.new()
		"hunt-cooperation":
			_behavior_probe = ProductionHuntProbe.new()
		"forage-migration", "forage-empty":
			var forage := ProductionForageProbe.new()
			forage.empty_control = behavior_case == "forage-empty"
			_behavior_probe = forage
		_:
			push_error("Unknown production behavior case: " + behavior_case)
			return
	_behavior_probe.setup(world, sheep_count, _initial.random_seed)

func _finish_behavior_probe() -> void:
	if _behavior_probe == null or not _behavior_probe.finished:
		return
	var completed_report: Dictionary = _behavior_probe.finish_report()
	_mutex.lock()
	_behavior_report = completed_report
	_mutex.unlock()
	# This only ends an explicitly invoked diagnostic. Ordinary play has no probe.
	_paused = true
	_behavior_probe = null

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

func _acquire_pose_buffer(count: int, publication: SimulationPublication) -> PoseBuffer:
	for index: int in _pose_buffers.size():
		var available: PoseBuffer = _pose_buffers[index]
		# Only the pool and this local may own a reusable buffer lease.
		if available.get_reference_count() == 2:
			available.prepare(count)
			return available
	var created := PoseBuffer.new()
	created.prepare(count)
	publication.pose_buffer_allocations += 1
	# External readers can pin arbitrarily old frames. Bounded retention with
	# unpooled fallback preserves correctness instead of stealing a reader's data.
	if _pose_buffers.size() < 8:
		_pose_buffers.append(created)
	return created

func _sample_poses(world: SimulationWorld, publication: SimulationPublication) -> void:
	var store: AgentStore = world.store
	if _pose_epoch != store.epoch:
		_poses.clear()
		_pose_histories.clear()
		_pose_epoch = store.epoch
	_poses.resize(store.capacity)
	_pose_histories.resize(store.capacity)
	var buffer: PoseBuffer = _acquire_pose_buffer(store.count, publication)
	publication.pose_buffer = buffer
	var observed_tick: int = maxi(0, world.tick - 1)
	var sample_count: int = mini(_pose_sample_count, store.count)
	var sample_index: int = 0
	var next_sample: int = -1
	if sample_count > 0:
		publication.pose_profile = PublishedPose.SampleProfile.new()
		# One sample from each equal population stratum. The offset rotates each
		# publication to avoid repeatedly profiling the same first dense slots.
		next_sample = _sequence % maxi(1, store.count / sample_count)
	for dense: int in store.count:
		var profile: PublishedPose.SampleProfile = publication.pose_profile if dense == next_sample else null
		var row_started: int = Time.get_ticks_usec() if profile != null else 0
		var part_started: int = row_started
		var handle: AgentHandle = store.handle_at(dense)
		var slot: int = handle.slot
		var previous: PublishedPose = _poses[slot]
		var history: PublishedPose.History = _pose_histories[slot]
		if history == null:
			history = PublishedPose.History.new()
			_pose_histories[slot] = history
		var intent: MotionIntent = world.intents.get_intent(handle, observed_tick)
		if profile != null:
			profile.lookup_usec += Time.get_ticks_usec() - part_started
			part_started = Time.get_ticks_usec()
		# One validated lookup serves both clocks: animation uses n-1; service
		# quality counts expiration at n. Dense columns are valid in this phase.
		if store.alive[dense] != 0 and store.held[dense] == 0:
			publication.active_agents += 1
			if intent == null or world.tick >= intent.expires_tick:
				publication.missing_intents += 1
		var moving: bool = store.velocity_current[dense].length_squared() > 9.0
		if profile != null:
			profile.quality_usec += Time.get_ticks_usec() - part_started
		var pose: PublishedPose = PublishedPose.sample(handle, store.species[dense], intent, moving, store.facing[dense], world.tick, previous, history, profile)
		if profile != null:
			part_started = Time.get_ticks_usec()
		if pose != previous:
			publication.pose_changed += 1
			publication.pose_allocations += int(history.allocated_on_acquire)
			var old_behavior: int = previous.behavior if previous != null and previous.handle.same_life(handle) else SimTypes.Behavior.IDLE
			if pose.behavior != old_behavior:
				var notice := SimulationNotice.new()
				notice.kind = SimulationNotice.Kind.BEHAVIOR
				notice.pose = pose
				notice.position = store.position_current[dense]
				notice.previous_behavior = old_behavior
				notice.tick = observed_tick
				notice.held = store.held[dense] != 0
				_notices.append(notice)
		_poses[slot] = pose
		buffer.write(dense, pose)
		if profile != null:
			profile.notices_buffer_usec += Time.get_ticks_usec() - part_started
			profile.total_usec += Time.get_ticks_usec() - row_started
			profile.rows += 1
			sample_index += 1
			if sample_index < sample_count:
				var stratum_start: int = sample_index * store.count / sample_count
				var stratum_end: int = (sample_index + 1) * store.count / sample_count
				next_sample = stratum_start + _sequence % maxi(1, stratum_end - stratum_start)
			else:
				next_sample = -1

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
	var motion_metrics: Dictionary = world.motion.backend_metrics()
	_mutex.lock()
	_diagnostic_totals["snapshot_usec"] += publication.snapshot_usec
	_diagnostic_totals["publications"] += 1
	if step_usec > 0:
		_diagnostic_totals["steps"] += 1
		_diagnostic_totals["step_usec"] += step_usec
		_diagnostic_totals["ai_used_usec"] += world.ai.frame_used_usec
		_diagnostic_totals["commands_usec"] += world.phase_usec[0]
		_diagnostic_totals["coordination_usec"] += world.phase_usec[1]
		_diagnostic_totals["grid_usec"] += world.phase_usec[2]
		_diagnostic_totals["motion_usec"] += world.phase_usec[4]
		_diagnostic_totals["interaction_usec"] += world.phase_usec[5]
	_diagnostic_tick = world.tick
	_diagnostic_epoch = world.store.epoch
	_diagnostic_completed_usec = publication.published_usec
	_diagnostic_motion = motion_metrics
	# One final receipt-only publication may follow the full queue during close.
	assert(_deliveries.size() < PUBLICATION_LIMIT or closing)
	_deliveries.append(delivery)
	_diagnostic_queue_peak = maxi(_diagnostic_queue_peak, _deliveries.size())
	# Release an overwritten full state outside the mailbox lock. Destruction
	# can walk many reference-counted records; input enqueue must not wait on it.
	var replaced: SimulationPublication = _latest
	_latest = publication
	_mutex.unlock()
	replaced = null
