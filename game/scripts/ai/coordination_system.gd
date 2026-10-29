class_name CoordinationSystem
extends RefCounted
## Requests and role repairs become visible only at the next begin_step boundary.
## Every request result is scoped to the complete actor/target lives and owner.
enum Kind { HUNT, DEFEND }
enum Role { MAIN, LEFT, RIGHT }
enum RequestStatus { PENDING, ACCEPTED, REJECTED, INVALID }

class Request extends RefCounted:
	var actor: AgentHandle
	var target: AgentHandle
	var kind: Kind
	var owner_token: int
	var actor_position: Vector2
	var requested_tick: int

class Result extends RefCounted:
	var request: Request
	var status: RequestStatus
	var expires_tick: int

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
var _results: Dictionary[int, Result] = {}
# Only changed hunt groups need repair; no per-step global role sorting.
var _changed_hunts: Dictionary[int, AgentHandle] = {}
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

func request_status(actor: AgentHandle, target: AgentHandle, token: int, tick: int) -> RequestStatus:
	if not _store.is_alive(actor) or not _store.is_alive(target):
		return RequestStatus.INVALID
	var lease: Lease = get_lease(actor, tick)
	if lease != null and lease.owner_token == token and lease.target.same_life(target):
		return RequestStatus.ACCEPTED
	var result: Result = _results.get(actor.slot)
	if result != null and tick < result.expires_tick and _matches(result.request, actor, target, token):
		return result.status
	var pending: Request = _incoming.get(actor.slot)
	if pending != null and _matches(pending, actor, target, token):
		return RequestStatus.PENDING
	return RequestStatus.INVALID

func begin_step(tick: int) -> void:
	_invalid.clear()
	for slot: int in leases:
		var lease: Lease = leases[slot]
		if tick >= lease.expires_tick or not _store.is_alive(lease.actor) or not _store.is_alive(lease.target):
			_invalid.append(slot)
	for slot: int in _invalid:
		_remove_lease(slot)
	_repair_changed_hunts()
	_invalid.clear()
	for slot: int in _results:
		var result: Result = _results[slot]
		if tick >= result.expires_tick or not _store.is_alive(result.request.actor) or not _store.is_alive(result.request.target):
			_invalid.append(slot)
	for slot: int in _invalid:
		_results.erase(slot)
	_invalid.clear()
	for slot: int in _incoming:
		var pending: Request = _incoming[slot]
		if pending.requested_tick >= tick:
			continue
		var status: RequestStatus = RequestStatus.INVALID
		if _store.is_alive(pending.actor) and _store.is_alive(pending.target):
			status = _grant(pending, tick)
		var result := Result.new()
		result.request = pending
		result.status = status
		result.expires_tick = tick + _config.lease_ticks
		_results[slot] = result
		_invalid.append(slot)
	for slot: int in _invalid:
		_incoming.erase(slot)
	# Replacing a target can remove an old group's MAIN during this grant phase.
	_repair_changed_hunts()

func _grant(pending: Request, tick: int) -> RequestStatus:
	var current: Lease = get_lease(pending.actor, tick)
	if current != null and current.kind == pending.kind and current.target.same_life(pending.target) and current.owner_token == pending.owner_token:
		current.expires_tick = tick + _config.lease_ticks
		current.actor_position = pending.actor_position
		return RequestStatus.ACCEPTED
	var occupied: Array[bool] = [false, false, false]
	for slot: int in leases:
		var other: Lease = leases[slot]
		if other.actor.same_life(pending.actor) or other.kind != pending.kind or not other.target.same_life(pending.target):
			continue
		if other.actor_position.distance_to(pending.actor_position) > _settings.cooperation_radius:
			return RequestStatus.REJECTED
		occupied[other.role] = true
	var role: int = -1
	var limit: int = 3 if pending.kind == Kind.HUNT else 1
	for candidate: int in range(limit):
		if not occupied[candidate]:
			role = candidate
			break
	if role < 0:
		return RequestStatus.REJECTED
	if leases.has(pending.actor.slot):
		_remove_lease(pending.actor.slot)
	var lease := Lease.new()
	lease.actor = pending.actor
	lease.target = pending.target
	lease.kind = pending.kind
	lease.role = role
	lease.owner_token = pending.owner_token
	lease.expires_tick = tick + _config.lease_ticks
	lease.actor_position = pending.actor_position
	leases[pending.actor.slot] = lease
	return RequestStatus.ACCEPTED

func _remove_lease(slot: int) -> void:
	var lease: Lease = leases[slot]
	if lease.kind == Kind.HUNT:
		_changed_hunts[lease.target.slot] = lease.target
	leases.erase(slot)

func _repair_changed_hunts() -> void:
	for target: AgentHandle in _changed_hunts.values():
		var replacement: Lease
		var has_main: bool = false
		for slot: int in leases:
			var member: Lease = leases[slot]
			if member.kind != Kind.HUNT or not member.target.same_life(target):
				continue
			if member.role == Role.MAIN:
				has_main = true
				break
			if replacement == null or member.actor.slot < replacement.actor.slot:
				replacement = member
		if not has_main and replacement != null:
			replacement.role = Role.MAIN
	_changed_hunts.clear()

func get_lease(actor: AgentHandle, tick: int) -> Lease:
	var lease: Lease = leases.get(actor.slot)
	if lease == null or not lease.actor.same_life(actor) or tick >= lease.expires_tick:
		return null
	return lease

func _matches(pending: Request, actor: AgentHandle, target: AgentHandle, token: int) -> bool:
	return pending.actor.same_life(actor) and pending.target.same_life(target) and pending.owner_token == token

func release(actor: AgentHandle, token: int) -> void:
	var lease: Lease = leases.get(actor.slot)
	if lease != null and lease.actor.same_life(actor) and lease.owner_token == token:
		_remove_lease(actor.slot)
	var pending: Request = _incoming.get(actor.slot)
	if pending != null and pending.actor.same_life(actor) and pending.owner_token == token:
		_incoming.erase(actor.slot)
	var result: Result = _results.get(actor.slot)
	if result != null and result.request.actor.same_life(actor) and result.request.owner_token == token:
		_results.erase(actor.slot)

func remove(actor: AgentHandle) -> void:
	_invalid.clear()
	for slot: int in leases:
		var lease: Lease = leases[slot]
		if lease.actor.same_life(actor) or lease.target.same_life(actor):
			_invalid.append(slot)
	for slot: int in _invalid:
		_remove_lease(slot)
	_invalid.clear()
	for slot: int in _incoming:
		var pending: Request = _incoming[slot]
		if pending.actor.same_life(actor) or pending.target.same_life(actor):
			_invalid.append(slot)
	for slot: int in _invalid:
		_incoming.erase(slot)
	_invalid.clear()
	for slot: int in _results:
		var pending: Request = _results[slot].request
		if pending.actor.same_life(actor) or pending.target.same_life(actor):
			_invalid.append(slot)
	for slot: int in _invalid:
		_results.erase(slot)

func clear() -> void:
	leases.clear()
	_incoming.clear()
	_results.clear()
	_changed_hunts.clear()
	_invalid.clear()
