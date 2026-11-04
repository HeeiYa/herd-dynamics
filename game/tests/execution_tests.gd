extends SceneTree
## Real asynchronous boundary contracts; the caller never borrows worker state.
var _checks: int = 0
var _failures: int = 0
var _access: SimulationAccess
var _receipts: Array[SimulationCommand.Receipt] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _poll() -> void:
	_access.pump_events(Time.get_ticks_usec() + 3000)
	var publication: SimulationPublication = _access.executor.poll_state(_access.delivered_sequence)
	if publication != null:
		_access.adopt(publication)
		_access.acknowledge_display(publication.sequence)

func _until(predicate: Callable, message: String) -> void:
	var deadline: int = Time.get_ticks_usec() + 5000000
	while not predicate.call() and Time.get_ticks_usec() < deadline:
		_poll()
		await process_frame
	_check(predicate.call(), message)

func _control(kind: SimulationCommand.Kind, integer: int = 0) -> void:
	var command := SimulationCommand.new()
	command.kind = kind
	command.integer = integer
	_check(_access.submit(command), "Control enters the bounded mailbox")

func _run() -> void:
	_test_intent_publication_lifetime()
	var config := SimulationConfig.new()
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 40
	scenario.wolf_count = 4
	scenario.dog_count = 2
	_access = SimulationAccess.threaded(config, scenario)
	_access.command_completed.connect(func(receipt: SimulationCommand.Receipt) -> void: _receipts.append(receipt))
	await _until(func() -> bool: return _access.tick >= 8, "Worker advances the formal world")
	var pinned: SimulationPublication = _access.publication
	var pinned_positions: PackedVector2Array = pinned.store.position_current.duplicate()
	var pinned_tick: int = pinned.tick
	await _until(func() -> bool: return _access.tick >= pinned_tick + 5, "Worker publishes further steps")
	_check(pinned.store.position_current == pinned_positions and pinned.tick == pinned_tick, "A retained publication is never overwritten")
	_control(SimulationCommand.Kind.PAUSE, 1)
	await _until(func() -> bool: return _access.publication.paused, "Pause confirms at a complete step boundary")
	var before_receipt: int = _receipts.size()
	var old_display_sequence: int = _access.publication.sequence
	_control(SimulationCommand.Kind.SELECT)
	var receipt_deadline: int = Time.get_ticks_usec() + 3000000
	while _receipts.size() == before_receipt and Time.get_ticks_usec() < receipt_deadline:
		_access.pump_events(Time.get_ticks_usec() + 750)
		await process_frame
	_check(_receipts.size() == before_receipt + 1, "Receipt delivery is independent of state adoption or rendering")
	_check(_access.publication.sequence == old_display_sequence and _access.has_pending_control(SimulationCommand.Kind.SELECT), "Accepted effects keep their preview barrier until the display catches up")
	await _until(func() -> bool: return not _access.has_pending_control(SimulationCommand.Kind.SELECT), "Committing the corresponding state clears the visual barrier")
	var paused_tick: int = _access.tick
	var handle: AgentHandle = _access.store.handle_at(0)
	_access.queue_hold(handle)
	_access.cancel_grab(handle, Vector2(-999, -999))
	await _until(func() -> bool: return not _access.is_hold_pending(handle), "Paused hold cancellation acknowledges without advancing time")
	_check(_access.tick == paused_tick and _access.store.is_active(handle), "Cancelled pending hold changes neither clock nor participation")
	_access.queue_hold(handle)
	_control(SimulationCommand.Kind.SINGLE_STEP)
	await _until(func() -> bool: return _access.store.is_held(handle), "One step applies hold")
	_check(_access.tick == paused_tick + 1, "Single-step advances exactly once")
	var origin: Vector2 = _access.store.position_current[_access.store.resolve(handle)]
	_access.queue_drop(handle, Vector2(1400, 850))
	_access.cancel_grab(handle, Vector2(-999, -999))
	_control(SimulationCommand.Kind.SINGLE_STEP)
	await _until(func() -> bool: return not _access.is_hold_pending(handle), "Drop then cancel is processed in order")
	_check(_access.store.is_active(handle), "Cancellation restores participation")
	_check(_access.store.position_current[_access.store.resolve(handle)].distance_to(origin) < 2.0, "Cancellation uses accepted simulation origin, never caller's stale position")
	_access.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.PERCEPTION_RADIUS, 240.0))
	_control(SimulationCommand.Kind.SINGLE_STEP)
	await _until(func() -> bool: return not _access.has_pending_tuning(), "Parameter receipt confirms stage-zero application")
	_check(_access.config.perception_radius == 240.0, "Applied parameter appears in the next owned snapshot")
	_access.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.PERCEPTION_RADIUS, 300.0))
	var reset := SimulationCommand.new()
	reset.kind = SimulationCommand.Kind.RESET
	reset.scenario = scenario.duplicate() as ScenarioConfig
	_access.submit(reset)
	reset.scenario.sheep_count = 999
	reset.kind = SimulationCommand.Kind.STALL
	_access.queue_remove(handle)
	await _until(func() -> bool: return _access.store.epoch > handle.world_epoch, "Reset crosses the epoch barrier")
	_check(_access.config.perception_radius == 240.0 and not _access.has_pending_tuning(), "Reset discards queued tuning and keeps applied configuration")
	_control(SimulationCommand.Kind.SINGLE_STEP)
	await _until(func() -> bool: return _access.tick == 1, "New epoch starts at tick zero before stepping")
	_check(_access.store.resolve(handle) < 0 and _access.store.count == 46, "Old handle cannot remove the recycled slot")
	_check(_receipts.any(func(receipt: SimulationCommand.Receipt) -> bool: return not receipt.accepted and receipt.reason == "expired_life"), "Stale full identity receives rejection")
	var before_stall: int = _access.tick
	_control(SimulationCommand.Kind.STALL, 100)
	var heartbeat_start: int = Time.get_ticks_usec()
	var heartbeats: int = 0
	while Time.get_ticks_usec() - heartbeat_start < 80000:
		_poll()
		heartbeats += 1
		await process_frame
	_check(heartbeats > 2 and _access.tick == before_stall, "Frontend continues while the simulation is stalled")
	await _until(func() -> bool: return not _access.has_pending_control(SimulationCommand.Kind.STALL), "Stall has a completion receipt")
	var step_tick: int = _access.tick
	for count: int in 3:
		_control(SimulationCommand.Kind.SINGLE_STEP)
	await _until(func() -> bool: return not _access.has_pending_control(SimulationCommand.Kind.SINGLE_STEP), "Each queued single-step completes before its receipt")
	_check(_access.tick == step_tick + 3, "Three queued single-step requests publish three distinct ticks")
	var accepted: int = 0
	for count: int in SimulationExecutor.COMMAND_LIMIT + 1:
		var selection := SimulationCommand.new()
		selection.kind = SimulationCommand.Kind.SELECT
		selection.handle = _access.store.handle_at(0)
		accepted += int(_access.submit(selection))
	_check(accepted == SimulationExecutor.COMMAND_LIMIT, "Unconsumed commands have a strict bound and explicit rejection")
	# Stop polling long enough to exercise a full publication FIFO.
	await create_timer(0.1).timeout
	await _until(func() -> bool: return not _access.has_pending_control(SimulationCommand.Kind.SELECT), "Backpressure preserves every receipt and publication sequence")
	_access.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.PERCEPTION_RADIUS, 300.0))
	_access.close()
	_check(not _access.has_pending_tuning(), "Shutdown drains pending command rejection before closing the observer log")
	_check(_receipts.any(func(receipt: SimulationCommand.Receipt) -> bool: return receipt.reason == "executor_closed"), "Unapplied shutdown command is explicitly rejected")
	print("EXECUTION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_intent_publication_lifetime() -> void:
	var handle := AgentHandle.new(0, 1, 2)
	var buffer := IntentBuffer.new()
	var original := MotionIntent.new()
	original.expires_tick = 100
	original.speed = 10.0
	buffer.write(handle, original)
	var first: IntentBuffer = buffer.publication_copy()
	var second: IntentBuffer = buffer.publication_copy()
	_check(first.get_intent(handle, 0) != original, "Publication never borrows the authoritative intent object")
	_check(first.get_intent(handle, 0) == second.get_intent(handle, 0), "Unchanged immutable copies are reused across publications")
	var replacement := MotionIntent.new()
	replacement.expires_tick = 100
	replacement.speed = 20.0
	buffer.write(handle, replacement)
	var third: IntentBuffer = buffer.publication_copy()
	buffer.clear()
	_check(third.get_intent(handle, 0).speed == 20.0 and first.get_intent(handle, 0).speed == 10.0, "Replacement and reset leave retained publication records intact")
	_check(buffer.publication_copy().get_intent(handle, 0) == null, "Reset clears the publication cache without reviving old lives")
