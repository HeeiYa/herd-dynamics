class_name ProductionHuntProbe
extends ProductionBehaviorProtocol
## Registered autonomous hunters around a real isolated sheep. Fixture geometry
## may read the sheep's current position; no such position is passed to an AI.
const HUNTER_TICK: int = 240
const END_TICK: int = 1200
const SAMPLE_PERIOD: int = 3
const HUNTER_OFFSETS: Array[Vector2] = [Vector2(-110, 0), Vector2(-100, -50), Vector2(-100, 50)]
var _world: SimulationWorld
var _seed: int
var _sheep_count: int
var _started_usec: int
var _bait: AgentHandle
var _records: Array[ProductionHuntTrace] = []
var _samples: Array[Dictionary] = []
var _captures: Array[Dictionary] = []
var _quality: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _cooperation_opportunity_ticks: int = 0
var _three_roles_ticks: int = 0
var _duplicate_captures: int = 0
var _captured_targets: Dictionary[String, bool] = {}
var _target_active_at_step_start: bool = false
var _target_position_at_step_start: Vector2
var _target_velocity_at_step_start: Vector2

func setup(world: SimulationWorld, sheep_count: int, seed_value: int) -> void:
	assert(world.store.count == 0 and sheep_count >= 8 and sheep_count <= 1000)
	assert(world.config.world_size == Vector2(2400, 1400))
	_world = world
	_seed = seed_value
	_sheep_count = sheep_count
	_started_usec = Time.get_ticks_usec()
	world.diagnostic_step_started = observe_step_start
	world.captured.connect(_on_capture)
	world.queue_place(SimTypes.Species.SHEEP, Vector2(600, 700))
	var random := RandomNumberGenerator.new()
	random.seed = seed_value
	var count: int = sheep_count - 1
	var columns: int = ceili(sqrt(float(count)))
	var rows: int = ceili(float(count) / columns)
	for index: int in count:
		var offset := Vector2(index % columns - (columns - 1) * 0.5, index / columns - (rows - 1) * 0.5) * 32.0
		world.queue_place(SimTypes.Species.SHEEP, Vector2(1800, 700) + offset + Vector2(random.randf_range(-2, 2), random.randf_range(-2, 2)))

func before_step(world: SimulationWorld) -> void:
	if finished or world.tick != HUNTER_TICK:
		return
	var started: int = Time.get_ticks_usec()
	var dense: int = world.store.resolve(_bait)
	assert(dense >= 0, "No predator or removal precedes the hunter stimulus")
	var position: Vector2 = world.store.position_current[dense]
	for offset: Vector2 in HUNTER_OFFSETS:
		world.queue_place(SimTypes.Species.WOLF, position + offset)
	_events.append({"event": "registered_three_hunters", "scheduled_tick": world.tick,
		"reference_life": _bait.key(), "reference_position": [position.x, position.y],
		"meaning": "External stimulus placement only; no target, task or reservation is assigned"})
	observer_usec += Time.get_ticks_usec() - started

func observe_step_start(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	if _bait == null and world.store.count > 0:
		_bait = world.store.handle_at(0)
	if world.tick == HUNTER_TICK:
		for dense: int in world.store.count:
			if world.store.species[dense] == SimTypes.Species.WOLF:
				var record := ProductionHuntTrace.new()
				record.handle = world.store.handle_at(dense)
				_records.append(record)
		assert(_records.size() == 3)
	for record: ProductionHuntTrace in _records:
		var dense: int = world.store.resolve(record.handle)
		assert(dense >= 0)
		record.previous_position = world.store.position_current[dense]
		record.previous_hunger = world.store.hunger[dense]
	_observe_geometric_opportunity()
	observer_usec += Time.get_ticks_usec() - started

func _observe_geometric_opportunity() -> void:
	var target_dense: int = _world.store.resolve(_bait)
	_target_active_at_step_start = target_dense >= 0
	if target_dense < 0:
		return
	var position: Vector2 = _world.store.position_current[target_dense]
	_target_position_at_step_start = position
	_target_velocity_at_step_start = _world.store.velocity_current[target_dense]
	var exposed: Array[ProductionHuntTrace] = []
	for record: ProductionHuntTrace in _records:
		if record.previous_position.distance_to(position) <= _world.config.perception_radius:
			exposed.append(record)
			record.exposure_ticks += 1
			if record.eligible_tick < 0:
				record.eligible_tick = _world.tick
				record.eligible_usec = Time.get_ticks_usec() - _started_usec
	var cooperative: bool = false
	for record: ProductionHuntTrace in exposed:
		for other: ProductionHuntTrace in exposed:
			if record == other or record.previous_position.distance_to(other.previous_position) > _world.ai.settings.cooperation_radius:
				continue
			cooperative = true
			if record.cooperation_eligible_tick < 0:
				record.cooperation_eligible_tick = _world.tick
	_cooperation_opportunity_ticks += int(cooperative)

func after_step(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	var tick: int = world.tick - 1
	var roles_present: Array[bool] = [false, false, false]
	for record: ProductionHuntTrace in _records:
		var context: AgentContext = world.ai.inspect(record.handle)
		var intent: MotionIntent = world.intents.get_intent(record.handle, tick)
		var position: Vector2 = world.store.position_current[world.store.resolve(record.handle)]
		var observation: LocalObservation = context.observation_for(_bait, tick)
		if observation != null and record.known_tick < 0:
			record.known_tick = tick
			record.known_usec = Time.get_ticks_usec() - _started_usec
		var lease: CoordinationSystem.Lease = world.ai.coordination.get_lease(record.handle, tick)
		var role: int = _observe_owned_role(record, context, intent, lease, position, tick)
		if role >= 0:
			roles_present[role] = true
		_observe_feed(record, context, intent, position, tick)
		if tick % SAMPLE_PERIOD == 0 or world.tick == END_TICK:
			var sample: Dictionary = _sample_context(record, context, intent, lease, position, tick)
			_samples.append(sample)
			if world.tick == END_TICK:
				record.terminal = sample.duplicate(true)
	_three_roles_ticks += int(roles_present[0] and roles_present[1] and roles_present[2])
	if world.tick % 60 == 0:
		_sample_quality(tick)
	observed_steps += 1
	observer_usec += Time.get_ticks_usec() - started
	finished = world.tick >= END_TICK

func _observe_owned_role(record: ProductionHuntTrace, context: AgentContext, intent: MotionIntent, lease: CoordinationSystem.Lease, position: Vector2, tick: int) -> int:
	if intent == null or intent.owner_token != context.task_token or intent.target == null or not intent.target.same_life(_bait):
		return -1
	if intent.behavior in [SimTypes.Behavior.STALK, SimTypes.Behavior.CHASE, SimTypes.Behavior.FLANK, SimTypes.Behavior.ATTACK] and record.hunt_tick < 0:
		record.hunt_tick = tick
		record.hunt_usec = Time.get_ticks_usec() - _started_usec
	if lease == null or lease.kind != CoordinationSystem.Kind.HUNT or lease.owner_token != intent.owner_token or not lease.target.same_life(_bait):
		return -1
	var role: int = lease.role
	if record.role_first_lease[role] < 0:
		record.role_first_lease[role] = tick
	var expected_behavior: int = SimTypes.Behavior.CHASE if role == CoordinationSystem.Role.MAIN else SimTypes.Behavior.FLANK
	if context.task_name != &"hunt_prey" or intent.behavior != expected_behavior or intent.mode != SimTypes.IntentMode.MOVE:
		return -1
	record.role_intent_ticks[role] += 1
	if not _target_active_at_step_start:
		return role
	var displacement: Vector2 = position - record.previous_position
	var role_direction: Vector2 = _role_direction_at_step_start(record.previous_position, role)
	record.role_intended_progress[role] += maxf(0.0, displacement.dot((intent.destination - record.previous_position).normalized()))
	record.role_direction_progress[role] += maxf(0.0, displacement.dot(role_direction))
	if record.role_intended_progress[role] >= 1.0 and record.role_direction_progress[role] >= 1.0 and record.role_motion_tick[role] < 0:
		record.role_motion_tick[role] = tick + 1
		record.role_motion_usec[role] = Time.get_ticks_usec() - _started_usec
	return role

func _role_direction_at_step_start(actor_position: Vector2, role: int) -> Vector2:
	# An external geometry measurement, not reconstruction of a BT's historical
	# input. Interleaved perception can replace that input even within one tick.
	var toward_target: Vector2 = (_target_position_at_step_start - actor_position).normalized()
	if role == CoordinationSystem.Role.MAIN:
		return toward_target
	var forward: Vector2 = _target_velocity_at_step_start.normalized()
	if forward.length_squared() < 0.001:
		forward = toward_target
	var side: float = -1.0 if role == CoordinationSystem.Role.LEFT else 1.0
	return forward.orthogonal() * side

func _observe_feed(record: ProductionHuntTrace, context: AgentContext, intent: MotionIntent, position: Vector2, tick: int) -> void:
	if record.capture_tick < 0 or intent == null or intent.owner_token != context.task_token:
		return
	if context.task_name != &"feed_capture" or intent.behavior != SimTypes.Behavior.FEED or intent.mode != SimTypes.IntentMode.STOP or tick >= context.feeding_until:
		return
	if record.feed_tick < 0:
		record.feed_tick = tick
		record.feed_usec = Time.get_ticks_usec() - _started_usec
	var actual_speed: float = position.distance_to(record.previous_position) / _world.config.fixed_dt
	if actual_speed <= _world.config.facing_min_speed and record.feed_stopped_tick < 0:
		record.feed_stopped_tick = tick + 1
		record.feed_stopped_usec = Time.get_ticks_usec() - _started_usec

func _on_capture(event: CaptureEvent) -> void:
	var started: int = Time.get_ticks_usec()
	_duplicate_captures += int(_captured_targets.has(event.target.key()))
	_captured_targets[event.target.key()] = true
	for record: ProductionHuntTrace in _records:
		if not record.handle.same_life(event.actor):
			continue
		record.capture_count += 1
		if record.capture_tick < 0:
			record.capture_tick = event.tick
			record.capture_usec = Time.get_ticks_usec() - _started_usec
		var hunger_after: float = _world.store.hunger[_world.store.resolve(record.handle)]
		_captures.append({"actor": event.actor.key(), "target": event.target.key(), "tick": event.tick,
			"elapsed_usec": Time.get_ticks_usec() - _started_usec,
			"declared_target": event.target.same_life(_bait), "position_x": event.position.x, "position_y": event.position.y,
			"actor_hunger_before_step": record.previous_hunger, "actor_hunger_after_capture": hunger_after,
			"target_already_dead": not _world.store.is_alive(event.target)})
	observer_usec += Time.get_ticks_usec() - started

func _sample_context(record: ProductionHuntTrace, context: AgentContext, intent: MotionIntent, lease: CoordinationSystem.Lease, position: Vector2, tick: int) -> Dictionary:
	var sighting: LocalObservation = context.observation_for(_bait, tick)
	return {"actor": record.handle.key(), "tick": tick, "elapsed_usec": Time.get_ticks_usec() - _started_usec,
		"position_x": position.x, "position_y": position.y, "task": str(context.task_name), "task_token": context.task_token,
		"intent_present": intent != null, "intent_owned": intent != null and intent.owner_token == context.task_token,
		"intent_behavior": SimTypes.Behavior.keys()[intent.behavior] if intent != null else "NONE",
		"intent_target": intent.target.key() if intent != null and intent.target != null else "",
		"destination_x": intent.destination.x if intent != null else 0.0, "destination_y": intent.destination.y if intent != null else 0.0,
		"lease_role": CoordinationSystem.Role.keys()[lease.role] if lease != null else "NONE",
		"lease_target": lease.target.key() if lease != null else "", "lease_token": lease.owner_token if lease != null else -1,
		"lease_expires_tick": lease.expires_tick if lease != null else -1,
		"declared_target_known": sighting != null, "declared_target_alive": _world.store.is_alive(_bait),
		"target_active_at_step_start": _target_active_at_step_start,
		"target_step_start_x": _target_position_at_step_start.x, "target_step_start_y": _target_position_at_step_start.y,
		"target_step_start_velocity_x": _target_velocity_at_step_start.x, "target_step_start_velocity_y": _target_velocity_at_step_start.y,
		"perception_tick": context.last_perception_tick, "decision_tick": context.last_decision_tick,
		"feeding_until": context.feeding_until}

func _sample_quality(tick: int) -> void:
	var missing: int = 0
	for dense: int in _world.store.count:
		missing += int(_world.intents.get_intent(_world.store.handle_at(dense), tick) == null)
	_quality.append({"tick": tick + 1, "elapsed_usec": Time.get_ticks_usec() - _started_usec,
		"active": _world.store.count, "missing_intents": missing})

func finish_report() -> Dictionary:
	assert(finished)
	var records: Array[Dictionary] = []
	var roles: Array[Dictionary] = []
	var terminal: Array[Dictionary] = []
	var outcome: Dictionary = {"case": "hunt_cooperation", "cohort": _records.size(), "eligible": 0,
		"cooperation_eligible": 0, "known": 0, "hunt_decision": 0, "eligible_without_hunt": 0,
		"main_real_motion_lives": 0, "left_real_motion_lives": 0, "right_real_motion_lives": 0,
		"capture_events": _captures.size(), "declared_target_captured": _captured_targets.has(_bait.key()),
		"feeding_after_capture": 0, "physically_stopped_feeding": 0, "duplicate_captures": _duplicate_captures}
	for record: ProductionHuntTrace in _records:
		records.append(record.to_dictionary())
		roles.append_array(record.role_rows(_bait))
		terminal.append(record.terminal.duplicate(true))
		outcome["eligible"] += int(record.eligible_tick >= 0)
		outcome["cooperation_eligible"] += int(record.cooperation_eligible_tick >= 0)
		outcome["known"] += int(record.known_tick >= 0)
		outcome["hunt_decision"] += int(record.hunt_tick >= 0)
		outcome["eligible_without_hunt"] += int(record.eligible_tick >= 0 and record.hunt_tick < 0)
		outcome["main_real_motion_lives"] += int(record.role_motion_tick[0] >= 0)
		outcome["left_real_motion_lives"] += int(record.role_motion_tick[1] >= 0)
		outcome["right_real_motion_lives"] += int(record.role_motion_tick[2] >= 0)
		outcome["feeding_after_capture"] += int(record.feed_tick >= 0)
		outcome["physically_stopped_feeding"] += int(record.feed_stopped_tick >= 0)
	var report: Dictionary = report_header(_world, "production-hunt-cooperation-v1", _seed, _sheep_count, _started_usec)
	report.merge({"case": "hunt_cooperation", "outcomes": [outcome], "records": records, "roles": roles,
		"terminal": terminal, "samples": _samples.duplicate(true), "quality": _quality.duplicate(true),
		"events": _events.duplicate(true), "captures": _captures.duplicate(true),
		"declared_target": _bait.key(), "declared_target_alive_at_end": _world.store.is_alive(_bait),
		"cooperation_opportunity_ticks": _cooperation_opportunity_ticks, "simultaneous_three_owned_role_ticks": _three_roles_ticks,
		"eligibility": "Each normal wolf geometrically sees the declared sheep inside the unchanged perception radius. Cooperative opportunity requires another simultaneously exposed wolf within cooperation_radius. These denominators precede role/target decisions and retain nonresponders.",
		"role_evidence": "Only valid owned HUNT leases and matching CHASE/FLANK intents for the one complete declared target life count. Physical role evidence needs >=1px along the intended direction and >=1px toward actual pre-step prey (MAIN) or signed lateral to its pre-step velocity, falling back to actor-to-prey direction (LEFT/RIGHT). These are independent observer geometry axes, never passed to AI; they do not reconstruct the BT's historical sighting or prove its exact flank-offset formula. Merely entering FLANK is insufficient. Role changes remain per-life/per-role records, never combined into a rate denominator.",
		"scope": "Isolated registered sheep and distant background flock; three registered wolves appear at tick240 around its actual position as an external experiment. No target, lease, hunger, speed, task or output is forced. CaptureEvent, nutrition state, later owned FEED/actual stopping and end states are separate evidence. A finite-horizon no-capture outcome is retained, not converted to success."})
	return report
