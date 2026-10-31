class_name SimulationAccess
extends RefCounted
## Frontend boundary: read a publication, submit a command. The inline adapter
## exists for regression/profiling; only it can reference a same-thread world.
signal captured(event: CaptureEvent)
signal observer_commands_applied(tick: int)
signal observer_reset(epoch: int)
signal observer_event(record: Dictionary)
signal command_completed(receipt: SimulationCommand.Receipt)
signal command_rejected(message: String)
signal publication_received(snapshot: SimulationPublication)
var executor: SimulationExecutor
var publication: SimulationPublication
var probes: Probes
var tuning: TuningCatalog
var _local: SimulationWorld
var _next_request: int = 1
var _command_epoch: int = 2
var _pending: Dictionary[int, SimulationCommand] = {}
var _last_sequence: int = -1

var store: AgentStore:
	get: return _local.store if _local != null else publication.store
var intents: IntentBuffer:
	get: return _local.intents if _local != null else publication.intents
var resources: ResourceGrid:
	get: return _local.resources if _local != null else publication.resources
var config: SimulationConfig:
	get: return _local.config if _local != null else publication.config
var scenario: ScenarioConfig:
	get: return _local.scenario if _local != null else publication.scenario
var settings: AISettings:
	get: return _local.ai.settings if _local != null else publication.settings
var tick: int:
	get: return _local.tick if _local != null else publication.tick
var capture_count: int:
	get: return _local.capture_count if _local != null else publication.capture_count
var phase_usec: PackedInt64Array:
	get: return _local.phase_usec if _local != null else publication.phase_usec
var max_perception_delay_ticks: int:
	get: return _local.ai.max_perception_delay_ticks if _local != null else publication.max_perception_delay_ticks
var max_decision_delay_ticks: int:
	get: return _local.ai.max_decision_delay_ticks if _local != null else publication.max_decision_delay_ticks
var grid_max_occupancy: int:
	get: return _local.grid.max_occupancy if _local != null else publication.grid_max_occupancy
var grid_candidate_count: int:
	get: return _local.grid.candidate_count if _local != null else publication.grid_candidate_count
var motion_backend_status: String:
	get: return _local.motion.backend_status if _local != null else publication.motion_backend_status
var spawn_planner: SpawnPlanner:
	get: return _local.spawn_planner if _local != null else null
var planner_description: String:
	get:
		if _local != null:
			return _local.spawn_planner.describe() if _local.spawn_planner != null else "V1 固定算法"
		return publication.planner_description

static func local(world: SimulationWorld) -> SimulationAccess:
	var access := SimulationAccess.new()
	access._local = world
	access.probes = world.probes
	access.tuning = world.tuning
	world.captured.connect(access.captured.emit)
	world.observer_commands_applied.connect(access.observer_commands_applied.emit)
	world.observer_reset.connect(access.observer_reset.emit)
	world.observer_event.connect(access.observer_event.emit)
	return access

static func threaded(config: SimulationConfig, scenario: ScenarioConfig) -> SimulationAccess:
	var access := SimulationAccess.new()
	access.publication = SimulationPublication.new()
	access.publication.store = AgentStore.new()
	access.publication.store.epoch = 2
	access.publication.intents = IntentBuffer.new()
	access.publication.config = config.duplicate() as SimulationConfig
	access.publication.settings = AISettings.new()
	access.publication.scenario = scenario.duplicate() as ScenarioConfig
	access.publication.resources = ResourceGrid.new(config)
	access.publication.phase_usec.resize(7)
	access.probes = Probes.new(config.instrument_enabled)
	access.tuning = TuningCatalog.new(access.config, access.settings)
	access.executor = SimulationExecutor.new()
	var result: Error = access.executor.start(config, scenario)
	if result != OK:
		push_error("Simulation worker could not start: " + error_string(result))
	return access

func close() -> void:
	if executor == null:
		return
	executor.close()
	# At shutdown, deliver accepted/rejected operations and applied event records
	# before the session log closes. No rendering or waiting occurs in frame code.
	while true:
		var final_publication: SimulationPublication = executor.poll()
		if final_publication == null:
			break
		adopt(final_publication)

func adopt(next: SimulationPublication) -> void:
	assert(next.sequence == _last_sequence + 1, "Publication/event FIFO must not skip or duplicate a sequence")
	_last_sequence = next.sequence
	var old_epoch: int = store.epoch
	publication = next
	_command_epoch = maxi(_command_epoch, store.epoch)
	for index: int in publication.tuning_values.size():
		tuning.parameters[index].value = publication.tuning_values[index]
	tuning.applied_count = publication.tuning_applied_count
	if old_epoch != store.epoch:
		observer_reset.emit(store.epoch)
	var completed_world_command: bool = false
	for receipt: SimulationCommand.Receipt in publication.receipts:
		var command: SimulationCommand = _pending.get(receipt.request_id)
		if command == null:
			continue
		completed_world_command = completed_world_command or command.kind in [SimulationCommand.Kind.HOLD, SimulationCommand.Kind.DROP, SimulationCommand.Kind.CANCEL_GRAB, SimulationCommand.Kind.PLACE, SimulationCommand.Kind.TUNING]
		_pending.erase(receipt.request_id)
		command_completed.emit(receipt)
		if not receipt.accepted and receipt.reason not in ["cancelled_by_observer", "discarded_by_reset"]:
			command_rejected.emit("操作未生效：目标或场景已经变化（%s）" % receipt.reason)
	if completed_world_command and not has_pending_tuning():
		observer_commands_applied.emit(tick)
	for event: Dictionary in publication.observer_events:
		observer_event.emit(event)
	publication_received.emit(next)

func deliver_captures() -> void:
	for event: CaptureEvent in publication.captures:
		captured.emit(event)

func inspect(handle: AgentHandle) -> AgentInspection:
	if _local != null:
		return AgentInspection.capture(_local, handle)
	var inspection: AgentInspection = publication.inspection
	return inspection if inspection != null and handle != null and inspection.handle.same_life(handle) else null

func counts() -> PackedInt32Array:
	return _local.counts() if _local != null else publication.counts

func held_counts() -> PackedInt32Array:
	return _local.held_counts() if _local != null else publication.held_counts

func submit(command: SimulationCommand) -> bool:
	assert(executor != null)
	if not _valid_command(command):
		command_rejected.emit("操作参数无效")
		return false
	if _pending.size() >= SimulationExecutor.COMMAND_LIMIT:
		command_rejected.emit("待处理操作已满，请稍后重试")
		return false
	command.request_id = _next_request
	command.epoch = _command_epoch
	command.submitted_usec = Time.get_ticks_usec()
	var owned: SimulationCommand = command.owned_copy()
	if not executor.enqueue(owned):
		command_rejected.emit("模拟暂时无法接收操作")
		return false
	_next_request += 1
	_pending[owned.request_id] = owned
	if command.kind == SimulationCommand.Kind.RESET:
		_command_epoch += 1
	return true

func _valid_command(command: SimulationCommand) -> bool:
	if command == null or command.kind < 0 or command.kind >= SimulationCommand.Kind.size():
		return false
	match command.kind:
		SimulationCommand.Kind.RESET:
			return command.scenario != null and command.scenario.sheep_count >= 0 and command.scenario.wolf_count >= 0 and command.scenario.dog_count >= 0
		SimulationCommand.Kind.SPEED:
			return is_finite(command.scalar) and command.scalar > 0.0
		SimulationCommand.Kind.SPAWN:
			return command.integer >= 0 and command.integer <= SimTypes.Species.DOG and is_finite(command.scalar) and command.scalar >= 0.0
		SimulationCommand.Kind.PLACE:
			return command.integer >= 0 and command.integer <= SimTypes.Species.DOG and command.position.is_finite()
		SimulationCommand.Kind.DROP:
			return command.handle != null and command.position.is_finite()
		SimulationCommand.Kind.HOLD, SimulationCommand.Kind.REMOVE, SimulationCommand.Kind.CANCEL_GRAB:
			return command.handle != null
		SimulationCommand.Kind.TUNING:
			return tuning.validated_copy(command.tuning) != null
	return true

func has_pending_control(kind: SimulationCommand.Kind) -> bool:
	for command: SimulationCommand in _pending.values():
		if command.kind == kind:
			return true
	return false

func _command(kind: SimulationCommand.Kind, handle: AgentHandle = null) -> SimulationCommand:
	var command := SimulationCommand.new()
	command.kind = kind
	command.handle = handle
	return command

func queue_spawn(species: int, amount: int) -> void:
	if _local != null:
		_local.queue_spawn(species, amount)
		return
	var command: SimulationCommand = _command(SimulationCommand.Kind.SPAWN)
	command.integer = species
	command.scalar = amount
	submit(command)

func queue_place(species: int, position: Vector2) -> void:
	if _local != null:
		_local.queue_place(species, position)
		return
	var command: SimulationCommand = _command(SimulationCommand.Kind.PLACE)
	command.integer = species
	command.position = position
	submit(command)

func queue_remove(handle: AgentHandle) -> void:
	if _local != null:
		_local.queue_remove(handle)
	else:
		submit(_command(SimulationCommand.Kind.REMOVE, handle))

func queue_hold(handle: AgentHandle) -> void:
	if _local != null:
		_local.queue_hold(handle)
	else:
		submit(_command(SimulationCommand.Kind.HOLD, handle))

func queue_drop(handle: AgentHandle, position: Vector2) -> void:
	if _local != null:
		_local.queue_drop(handle, position)
		return
	var command: SimulationCommand = _command(SimulationCommand.Kind.DROP, handle)
	command.position = position
	submit(command)

func cancel_grab(handle: AgentHandle, origin: Vector2) -> bool:
	if _local != null:
		return _local.cancel_grab(handle, origin)
	return submit(_command(SimulationCommand.Kind.CANCEL_GRAB, handle))

func queue_tuning(change: TuningCatalog.Change) -> bool:
	if _local != null:
		return _local.queue_tuning(change)
	var owned: TuningCatalog.Change = tuning.validated_copy(change)
	if owned == null:
		return false
	var command: SimulationCommand = _command(SimulationCommand.Kind.TUNING)
	command.tuning = owned
	return submit(command)

func is_hold_pending(handle: AgentHandle) -> bool:
	if _local != null:
		return _local.is_hold_pending(handle)
	for command: SimulationCommand in _pending.values():
		if command.handle != null and command.handle.same_life(handle) and command.kind in [SimulationCommand.Kind.HOLD, SimulationCommand.Kind.DROP, SimulationCommand.Kind.CANCEL_GRAB]:
			return true
	return false

func has_pending_tuning() -> bool:
	if _local != null:
		return _local.has_pending_tuning()
	for command: SimulationCommand in _pending.values():
		if command.kind == SimulationCommand.Kind.TUNING:
			return true
	return false

func select(handle: AgentHandle) -> void:
	if executor != null:
		submit(_command(SimulationCommand.Kind.SELECT, handle))

func record_observer_event(action: String, details: Dictionary = {}) -> void:
	if _local != null:
		_local.record_observer_event(action, details)
	else:
		var record: Dictionary = details.duplicate(true)
		record.merge({"event": action, "epoch": store.epoch, "tick": tick, "seed": scenario.random_seed, "layout": scenario.layout})
		observer_event.emit(record)
