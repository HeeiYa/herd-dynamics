class_name CoordinationSystem
extends RefCounted
## Requests emitted at step N can only be granted in begin_step(N + 1).
## Ownership tokens prevent an interrupted leaf releasing its replacement's lease.
enum Kind { HUNT, DEFEND }
enum Role { MAIN, LEFT, RIGHT }

class Request extends RefCounted:
	var actor: AgentHandle
	var target: AgentHandle
	var kind: Kind
	var owner_token: int
	var actor_position: Vector2
	var requested_tick: int

class Lease extends RefCounted:
	var actor: AgentHandle
	var target: AgentHandle
	var kind: Kind
	var role: int = Role.MAIN
	var owner_token: int
	var expires_tick: int
	var actor_position: Vector2

var leases: Dictionary[int, Lease] = {}
var _incoming: Dictionary[int, Request] = {}
var _invalid: Array[int] = []
var _store: AgentStore
var _config: SimulationConfig
var _settings: AISettings

func setup(store: AgentStore, config: SimulationConfig, settings: AISettings) -> void:
	_store = store
	_config = config
	_settings = settings

func request(actor: AgentHandle, target: AgentHandle, kind: Kind, token: int, position: Vector2, tick: int) -> void:
	var request_value := Request.new()
	request_value.actor = actor
	request_value.target = target
	request_value.kind = kind
	request_value.owner_token = token
	request_value.actor_position = position
	request_value.requested_tick = tick
	_incoming[actor.slot] = request_value

func begin_step(tick: int) -> void:
	_invalid.clear()
	for slot: int in leases:
		var lease: Lease = leases[slot]
		if tick >= lease.expires_tick or not _store.is_alive(lease.actor) or not _store.is_alive(lease.target):
			_invalid.append(slot)
	for slot: int in _invalid:
		leases.erase(slot)
	_invalid.clear()
	for slot: int in _incoming:
		var pending: Request = _incoming[slot]
		if pending.requested_tick >= tick:
			continue
		if _store.is_alive(pending.actor) and _store.is_alive(pending.target):
			_grant(pending, tick)
		_invalid.append(slot)
	for slot: int in _invalid:
		_incoming.erase(slot)

func _grant(pending: Request, tick: int) -> void:
	var current: Lease = get_lease(pending.actor, tick)
	if current != null and current.target.same_life(pending.target) and current.owner_token == pending.owner_token:
		current.expires_tick = tick + _config.lease_ticks
		current.actor_position = pending.actor_position
		return
	var occupied: Array[bool] = [false, false, false]
	for slot: int in leases:
		var other: Lease = leases[slot]
		if other.actor.same_life(pending.actor) or other.kind != pending.kind or not other.target.same_life(pending.target):
			continue
		if other.actor_position.distance_to(pending.actor_position) > _settings.cooperation_radius:
			# A distant observer cannot join this local group or duplicate its role.
			return
		occupied[other.role] = true
	var role: int = -1
	var limit: int = 3 if pending.kind == Kind.HUNT else 1
	for candidate: int in range(limit):
		if not occupied[candidate]:
			role = candidate
			break
	if role < 0:
		return
	var lease := Lease.new()
	lease.actor = pending.actor
	lease.target = pending.target
	lease.kind = pending.kind
	lease.role = role
	lease.owner_token = pending.owner_token
	lease.expires_tick = tick + _config.lease_ticks
	lease.actor_position = pending.actor_position
	leases[pending.actor.slot] = lease

func get_lease(actor: AgentHandle, tick: int) -> Lease:
	var lease: Lease = leases.get(actor.slot)
	if lease == null or not lease.actor.same_life(actor) or tick >= lease.expires_tick:
		return null
	return lease

func release(actor: AgentHandle, token: int) -> void:
	var lease: Lease = leases.get(actor.slot)
	if lease != null and lease.actor.same_life(actor) and lease.owner_token == token:
		leases.erase(actor.slot)
	var pending: Request = _incoming.get(actor.slot)
	if pending != null and pending.actor.same_life(actor) and pending.owner_token == token:
		_incoming.erase(actor.slot)

func remove(actor: AgentHandle) -> void:
	_invalid.clear()
	for slot: int in leases:
		var lease: Lease = leases[slot]
		if lease.actor.same_life(actor) or lease.target.same_life(actor):
			_invalid.append(slot)
	for slot: int in _invalid:
		leases.erase(slot)
	_invalid.clear()
	for slot: int in _incoming:
		var pending: Request = _incoming[slot]
		if pending.actor.same_life(actor) or pending.target.same_life(actor):
			_invalid.append(slot)
	for slot: int in _invalid:
		_incoming.erase(slot)

func clear() -> void:
	leases.clear()
	_incoming.clear()
	_invalid.clear()