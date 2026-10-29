class_name InteractionSystem
extends RefCounted
## Owns hunger, grass consumption and attack timelines. World owns structural removal.
var deaths: Array[AgentHandle] = []
var captures: Array[CaptureEvent] = []
var grass_consumed: float = 0.0
var _store: AgentStore
var _resources: ResourceGrid
var _intents: IntentBuffer
var _config: SimulationConfig
# A single latest request per slot bounds history; full life identity guards reuse.
var _requests: Dictionary[int, AttackRequest] = {}
var _contacts: Array[AttackRequest] = []
var _cell_demand: PackedFloat64Array = PackedFloat64Array()
var _cell_consumed: PackedFloat64Array = PackedFloat64Array()
var _agent_demand: PackedFloat64Array = PackedFloat64Array()
var _agent_cell: PackedInt32Array = PackedInt32Array()
var _grazed_cells: Array[int] = []

func setup(store: AgentStore, resources: ResourceGrid, intents: IntentBuffer, config: SimulationConfig) -> void:
	_store = store
	_resources = resources
	_intents = intents
	_config = config
	_cell_demand.resize(resources.cell_count)
	_cell_consumed.resize(resources.cell_count)

func step(tick: int, dt: float) -> void:
	deaths.clear()
	captures.clear()
	_contacts.clear()
	grass_consumed = 0.0
	_increase_hunger(dt)
	_accept_intents(tick)
	_collect_contacts(tick)
	_contacts.sort_custom(_contact_precedes)
	for request: AttackRequest in _contacts:
		_resolve_capture(request, tick)
	_graze(tick, dt)

func _increase_hunger(dt: float) -> void:
	for dense: int in range(_store.count):
		if _store.alive[dense] != 0:
			_store.hunger[dense] = clampf(_store.hunger[dense] + _config.hunger_rate * dt, 0.0, 1.0)

func _accept_intents(tick: int) -> void:
	for dense: int in range(_store.count):
		if _store.alive[dense] == 0 or _store.species[dense] != SimTypes.Species.WOLF:
			continue
		var actor: AgentHandle = _store.handle_at(dense)
		var intent: MotionIntent = _intents.get_intent(actor, tick)
		if intent == null:
			# Successful handoff survives normal BT exit and intent expiration.
			continue
		if intent.mode == SimTypes.IntentMode.FLEE or intent.behavior == SimTypes.Behavior.RETREAT:
			cancel(actor)
			continue
		if intent.mode == SimTypes.IntentMode.ATTACK:
			_accept_attack(actor, intent, tick)

func _accept_attack(actor: AgentHandle, intent: MotionIntent, tick: int) -> void:
	var target_dense: int = _store.resolve(intent.target)
	if target_dense < 0 or _store.species[target_dense] != SimTypes.Species.SHEEP or intent.owner_token <= 0:
		return
	var previous: AttackRequest = _requests.get(actor.slot)
	if previous != null and previous.actor.same_life(actor):
		if intent.owner_token <= previous.owner_token or previous.is_pending() or tick < previous.cooldown_until_tick:
			return
	var request := AttackRequest.new()
	request.actor = actor
	request.target = intent.target
	request.owner_token = intent.owner_token
	request.accepted_tick = tick
	request.active_start_tick = tick + maxi(0, _config.attack_windup_ticks)
	request.active_end_tick = request.active_start_tick + maxi(1, _config.attack_window_ticks)
	request.cooldown_until_tick = tick + maxi(0, _config.attack_cooldown_ticks)
	_requests[actor.slot] = request

func _collect_contacts(tick: int) -> void:
	for slot: int in _requests:
		var request: AttackRequest = _requests[slot]
		if not request.is_pending():
			continue
		if not _store.is_alive(request.actor) or not _store.is_alive(request.target):
			request.status = AttackRequest.Status.CANCELLED
			continue
		if tick >= request.active_end_tick:
			request.status = AttackRequest.Status.MISSED
			continue
		if tick < request.active_start_tick:
			continue
		request.status = AttackRequest.Status.ACTIVE
		request.contact_fraction = _swept_contact(request, tick)
		if request.contact_fraction >= 0.0:
			_contacts.append(request)

func _swept_contact(request: AttackRequest, tick: int) -> float:
	var actor_dense: int = _store.resolve(request.actor)
	var target_dense: int = _store.resolve(request.target)
	if actor_dense < 0 or target_dense < 0:
		return -1.0
	# Restrict relative segment contact to the active half-open simulation window.
	var lower: float = maxf(0.0, request.active_start_tick - tick)
	var upper: float = minf(1.0, request.active_end_tick - tick)
	if upper <= lower:
		return -1.0
	var relative_start: Vector2 = _store.position_current[actor_dense] - _store.position_current[target_dense]
	var relative_end: Vector2 = _store.position_next[actor_dense] - _store.position_next[target_dense]
	var segment: Vector2 = (relative_end - relative_start) * (upper - lower)
	var origin: Vector2 = relative_start.lerp(relative_end, lower)
	var reach: float = _store.radius[actor_dense] + _store.radius[target_dense] + _config.attack_range
	var constant: float = origin.length_squared() - reach * reach
	if constant <= 0.0:
		return lower
	var quadratic: float = segment.length_squared()
	if quadratic <= 0.0000001:
		return -1.0
	var linear: float = 2.0 * origin.dot(segment)
	var discriminant: float = linear * linear - 4.0 * quadratic * constant
	if discriminant < 0.0:
		return -1.0
	var local_contact: float = (-linear - sqrt(discriminant)) / (2.0 * quadratic)
	if local_contact < 0.0 or local_contact > 1.0:
		return -1.0
	var fraction: float = lerpf(lower, upper, local_contact)
	if float(tick) + fraction >= request.active_end_tick:
		return -1.0
	return fraction

func _contact_precedes(left: AttackRequest, right: AttackRequest) -> bool:
	if left.contact_fraction != right.contact_fraction:
		return left.contact_fraction < right.contact_fraction
	if left.actor.slot != right.actor.slot:
		return left.actor.slot < right.actor.slot
	return left.owner_token < right.owner_token

func _resolve_capture(request: AttackRequest, tick: int) -> void:
	var actor_dense: int = _store.resolve(request.actor)
	var target_dense: int = _store.resolve(request.target)
	if actor_dense < 0 or target_dense < 0:
		request.status = AttackRequest.Status.CANCELLED
		return
	request.status = AttackRequest.Status.CAPTURED
	var event := CaptureEvent.new()
	event.actor = request.actor
	event.target = request.target
	event.position = _store.position_next[target_dense]
	event.facing = _store.facing[target_dense]
	event.tick = tick + 1
	_store.mark_dead(request.target)
	_store.hunger[actor_dense] = clampf(_store.hunger[actor_dense] - _config.capture_nutrition, 0.0, 1.0)
	deaths.append(request.target)
	captures.append(event)

func _graze(tick: int, dt: float) -> void:
	if _agent_demand.size() < _store.capacity:
		_agent_demand.resize(_store.capacity)
		_agent_cell.resize(_store.capacity)
	_cell_demand.fill(0.0)
	_cell_consumed.fill(0.0)
	_agent_demand.fill(0.0)
	_agent_cell.fill(-1)
	_grazed_cells.clear()
	for dense: int in range(_store.count):
		_collect_grazing_demand(dense, tick, dt)
	for cell: int in _grazed_cells:
		# Exactly one commit per cell preserves ResourceGrid's pre-step snapshot.
		_cell_consumed[cell] = _resources.consume(cell, _cell_demand[cell], tick)
		grass_consumed += _cell_consumed[cell]
	for dense: int in range(_store.count):
		var cell: int = _agent_cell[dense]
		if cell < 0:
			continue
		var share: float = _agent_demand[dense] / _cell_demand[cell] * _cell_consumed[cell]
		_store.hunger[dense] = clampf(_store.hunger[dense] - share, 0.0, 1.0)

func _collect_grazing_demand(dense: int, tick: int, dt: float) -> void:
	if _store.alive[dense] == 0 or _store.species[dense] != SimTypes.Species.SHEEP:
		return
	var intent: MotionIntent = _intents.get_intent(_store.handle_at(dense), tick)
	if intent == null or intent.mode != SimTypes.IntentMode.GRAZE:
		return
	var cell: int = intent.resource_cell
	if cell < 0 or cell >= _resources.cell_count:
		return
	if not _resources.can_graze_at(cell, _store.position_next[dense]):
		return
	var requested: float = minf(_store.hunger[dense], maxf(0.0, _config.grazing_rate * dt))
	if requested <= 0.0:
		return
	if _cell_demand[cell] == 0.0:
		_grazed_cells.append(cell)
	_cell_demand[cell] += requested
	_agent_demand[dense] = requested
	_agent_cell[dense] = cell

func cancel(handle: AgentHandle) -> void:
	if handle == null:
		return
	var request: AttackRequest = _requests.get(handle.slot)
	if request != null and request.actor.same_life(handle) and request.is_pending():
		request.status = AttackRequest.Status.CANCELLED

func get_attack(handle: AgentHandle) -> AttackRequest:
	if handle == null:
		return null
	var request: AttackRequest = _requests.get(handle.slot)
	if request == null or not request.actor.same_life(handle):
		return null
	return request

func remove(handle: AgentHandle) -> void:
	if handle == null:
		return
	var request: AttackRequest = _requests.get(handle.slot)
	if request != null and request.actor.same_life(handle):
		_requests.erase(handle.slot)
	for slot: int in _requests:
		var pending: AttackRequest = _requests[slot]
		if pending.is_pending() and pending.target.same_life(handle):
			pending.status = AttackRequest.Status.CANCELLED

func reset() -> void:
	_requests.clear()
	_contacts.clear()
	deaths.clear()
	captures.clear()
	_grazed_cells.clear()
	grass_consumed = 0.0
