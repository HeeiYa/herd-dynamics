class_name ProductionDogProtectionProbe
extends ProductionBehaviorProtocol
## Worker-owned finite observation. External placements/removals are the only
## interventions; every perception, reservation, motion and capture is real.
const THREAT_TICK: int = 240
const CLEAR_THREATS_TICK: int = 600
const END_TICK: int = 1200
const QUALITY_PERIOD: int = 60
var geometry_variant: ProductionDogProtectionGeometry.Variant = ProductionDogProtectionGeometry.Variant.NORMAL
var _world: SimulationWorld
var _seed: int
var _sheep_count: int
var _started_usec: int
var _fixture_error: String = ""
var _fixture_error_details: Dictionary = {}
var _layout := ProductionDogProtectionGeometry.new()
var _cohort: Array[AgentHandle] = []
var _background: Array[AgentHandle] = []
var _dogs: Array[AgentHandle] = []
var _wolves: Array[AgentHandle] = []
var _records: Array[ProductionDogProtectionTrace] = []
var _requested_wolves: Array[Vector2] = []
var _initial: Array[Dictionary] = []
var _preflight: Array[Dictionary] = []
var _quality: Array[Dictionary] = []
var _cohort_samples: Array[Dictionary] = []
var _wolf_steps: Array[Dictionary] = []
var _anchor_changes: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _captures: Array[Dictionary] = []
var _dog_diagnostics := ProductionDogDiagnostics.new()
var _background_sample_positions: PackedVector2Array = PackedVector2Array()
var _background_perception_ticks: PackedInt32Array = PackedInt32Array()
var _background_decision_ticks: PackedInt32Array = PackedInt32Array()
var _quality_observer_usec: int = 0

func setup(world: SimulationWorld, sheep_count: int, seed_value: int) -> void:
	assert(world.store.count == 0 and world.pending_spawns == PackedInt32Array([0, 0, 0]))
	assert(not world.has_pending_observer_commands())
	_world = world
	_seed = seed_value
	_sheep_count = sheep_count
	_started_usec = Time.get_ticks_usec()
	var arguments := PackedStringArray(["--dog-geometry=" + ProductionDogProtectionGeometry.variant_name(geometry_variant)])
	var error: String = ProductionDogProtectionGeometry.argument_error(arguments, "dog-protection", sheep_count, seed_value)
	if not error.is_empty() or world.config.world_size != Vector2(2400, 1400):
		_fail(error if not error.is_empty() else "Dog protection requires the declared 2400x1400 world")
		return
	_layout.prepare(sheep_count, seed_value)
	error = _layout.initial_error(world.config.agent_radius, world.config.world_size)
	if not error.is_empty():
		_fail(error)
		return
	world.diagnostic_step_started = observe_step_start
	world.captured.connect(_on_capture)
	for index: int in _layout.positions.size():
		world.queue_place(_layout.species[index], _layout.positions[index])
	observer_usec += Time.get_ticks_usec() - _started_usec

func before_step(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	if world.tick == THREAT_TICK:
		_prepare_threats()
	elif world.tick == CLEAR_THREATS_TICK:
		for record: ProductionDogProtectionTrace in _records:
			if record.species != SimTypes.Species.WOLF or not world.store.is_alive(record.handle):
				continue
			record.removed_by_protocol = true
			world.queue_remove(record.handle)
		_events.append({"event": "remove_declared_wolves", "input_tick": world.tick,
			"meaning": "Normal stage0 removal; dogs and sheep keep their own running state"})
	observer_usec += Time.get_ticks_usec() - started

func _prepare_threats() -> void:
	if _dogs.size() != 4:
		_fail("Four complete registered dog lives are required before the stimulus")
		return
	for group: int in 2:
		var positions: Array[Vector2] = []
		var anchors: Array[Vector2] = []
		for member: int in 2:
			var dog: AgentHandle = _dogs[group * 2 + member]
			var dense: int = _world.store.resolve(dog)
			var context: AgentContext = _world.ai.inspect(dog)
			if dense < 0 or not _world.store.is_active(dog) or context == null or not _current_flock(context, _world.tick):
				_fail("A declared dog lacks an active life and genuinely observed current protection sample", {
					"dog": dog.key(), "group": group, "active": _world.store.is_active(dog),
					"context_present": context != null, "flock_count": context.flock_count if context != null else -1,
					"current_sample_count": context.flock_sample_count if context != null else -1,
					"current_sample_observed_tick": context.flock_sample_observed_tick if context != null else -1,
					"current_sample_expires_tick": context.flock_sample_expires_tick if context != null else -1})
				return
			positions.append(_world.store.position_current[dense])
			anchors.append(context.protection_anchor)
		var wolf: Vector2 = ProductionDogProtectionGeometry.wolf_position(positions[0], positions[1], geometry_variant)
		_requested_wolves.append(wolf)
		for member: int in 2:
			var context: AgentContext = _world.ai.inspect(_dogs[group * 2 + member])
			_preflight.append({"dog": _dogs[group * 2 + member].key(), "group": group, "tick": _world.tick,
				"dog_x": positions[member].x, "dog_y": positions[member].y,
				"anchor_x": anchors[member].x, "anchor_y": anchors[member].y,
				"sample_count": context.flock_sample_count, "sample_observed_tick": context.flock_sample_observed_tick,
				"sample_expires_tick": context.flock_sample_expires_tick,
				"wolf_x": wolf.x, "wolf_y": wolf.y, "dog_distance": positions[member].distance_to(wolf),
				"anchor_distance": anchors[member].distance_to(wolf)})
		var error: String = ProductionDogProtectionGeometry.opportunity_error(wolf, positions, anchors,
			_world.config.agent_radius, _world.config.world_size, _world.ai.settings.dog_risk_radius,
			_world.config.perception_radius, _world.ai.settings.protection_radius)
		if not error.is_empty():
			_fail(error, {"group": group, "wolf_index": group, "wolf_x": wolf.x, "wolf_y": wolf.y,
				"preflight_rows_begin": group * 2, "preflight_rows_count": 2})
			return
	# Validate the complete batch before enqueueing either wolf. Background is
	# real and may already have entered the region; it is not ignored here.
	for index: int in _requested_wolves.size():
		var wolf: Vector2 = _requested_wolves[index]
		for dense: int in _world.store.count:
			var actor: AgentHandle = _world.store.handle_at(dense)
			if not _world.store.is_active(actor):
				continue
			var distance: float = wolf.distance_to(_world.store.position_current[dense])
			if distance < _world.config.agent_radius + _world.store.radius[dense]:
				_fail("A requested wolf overlaps a real active body", _body_conflict_details(index, wolf, dense, distance))
				return
			if _world.store.species[dense] == SimTypes.Species.DOG and distance <= _world.ai.settings.dog_risk_radius:
				_fail("A requested wolf starts inside another dog's risk radius", _body_conflict_details(index, wolf, dense, distance))
				return
		for previous: int in index:
			if wolf.distance_to(_requested_wolves[previous]) < _world.config.agent_radius * 2.0:
				_fail("Requested wolves overlap", {"wolf_index": index, "other_wolf_index": previous,
					"wolf_x": wolf.x, "wolf_y": wolf.y,
					"other_wolf_x": _requested_wolves[previous].x, "other_wolf_y": _requested_wolves[previous].y,
					"distance": wolf.distance_to(_requested_wolves[previous])})
				return
	for position: Vector2 in _requested_wolves:
		_world.queue_place(SimTypes.Species.WOLF, position)
	_events.append({"event": "place_declared_wolves", "input_tick": _world.tick,
		"meaning": "One fixed relative placement per dog pair; no retry or forced target/lease"})

func _body_conflict_details(wolf_index: int, wolf: Vector2, dense: int, distance: float) -> Dictionary:
	var blocker: AgentHandle = _world.store.handle_at(dense)
	var blocker_position: Vector2 = _world.store.position_current[dense]
	return {"wolf_index": wolf_index, "wolf_x": wolf.x, "wolf_y": wolf.y,
		"wolf_radius": _world.config.agent_radius, "blocker": blocker.key(),
		"blocker_species": _world.store.species[dense], "blocker_x": blocker_position.x, "blocker_y": blocker_position.y,
		"blocker_radius": _world.store.radius[dense], "distance": distance,
		"minimum_body_separation": _world.config.agent_radius + _world.store.radius[dense],
		"dog_risk_radius": _world.ai.settings.dog_risk_radius}

func observe_step_start(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	if _cohort.is_empty():
		_register_initial()
	if not finished and world.tick == THREAT_TICK:
		_register_wolves()
	if finished:
		observer_usec += Time.get_ticks_usec() - started
		return
	for record: ProductionDogProtectionTrace in _records:
		record.start_active = world.store.is_active(record.handle)
		if not record.start_active:
			record.alive = world.store.is_alive(record.handle)
			record.close_exposure(world.tick, "PROTOCOL_REMOVED" if record.removed_by_protocol else "LIFE_INACTIVE")
			continue
		var dense: int = world.store.resolve(record.handle)
		record.previous_position = world.store.position_current[dense]
		record.start_velocity = world.store.velocity_current[dense]
		var context: AgentContext = world.ai.inspect(record.handle)
		record.start_anchor = context.protection_anchor
		record.start_flock_count = context.flock_count
		record.start_flock_tick = context.flock_sample_observed_tick
		record.start_current_flock = _current_flock(context, world.tick)
		_observe_geometry(record, context)
	observer_usec += Time.get_ticks_usec() - started

func _register_initial() -> void:
	if _world.store.count != _layout.positions.size():
		_fail("Initial registered population differs from the declared roster")
		return
	for index: int in _layout.positions.size():
		var actor: AgentHandle = _world.store.handle_at(index)
		if not _world.store.is_active(actor) or _world.store.species[index] != _layout.species[index] or _world.store.position_current[index] != _layout.positions[index]:
			_fail("Stage0 changed an initial body, species or requested coordinate")
			return
		var position: Vector2 = _world.store.position_current[index]
		var cohort_name: String = "background"
		if index < 80:
			_cohort.append(actor)
			cohort_name = "observed_sheep"
		elif index < 84:
			_dogs.append(actor)
			_add_record(actor, SimTypes.Species.DOG, (index - 80) / 2)
			cohort_name = "dog"
		else:
			_background.append(actor)
			_background_sample_positions.append(position)
			var context: AgentContext = _world.ai.inspect(actor)
			_background_perception_ticks.append(context.last_perception_tick)
			_background_decision_ticks.append(context.last_decision_tick)
		_initial.append({"handle": actor.key(), "cohort": cohort_name, "registration_index": index,
			"tick": _world.tick, "species": _world.store.species[index], "x": position.x, "y": position.y})

func _register_wolves() -> void:
	for dense: int in _world.store.count:
		if _world.store.species[dense] != SimTypes.Species.WOLF:
			continue
		var index: int = _wolves.size()
		if index >= _requested_wolves.size() or _world.store.position_current[dense] != _requested_wolves[index]:
			_fail("Registered wolf positions differ from the preflight request")
			return
		var actor: AgentHandle = _world.store.handle_at(dense)
		_wolves.append(actor)
		_add_record(actor, SimTypes.Species.WOLF, index)
	if _wolves.size() != 2:
		_fail("Exactly two real wolf lives must be registered")

func _add_record(actor: AgentHandle, species: int, group: int) -> void:
	var record := ProductionDogProtectionTrace.new()
	record.handle = actor
	record.species = species
	record.group = group
	record.birth_tick = _world.tick
	_records.append(record)

func _observe_geometry(record: ProductionDogProtectionTrace, context: AgentContext) -> void:
	var targets: Array[AgentHandle] = _wolves if record.species == SimTypes.Species.DOG else _dogs
	var radius: float = _world.config.perception_radius if record.species == SimTypes.Species.DOG else _world.ai.settings.dog_risk_radius
	record.start_nearest_target = null
	record.start_nearest_distance = -1.0
	record.start_protected_geometry = false
	for target: AgentHandle in targets:
		var dense: int = _world.store.resolve(target)
		if dense < 0 or not _world.store.is_active(target):
			continue
		var position: Vector2 = _world.store.position_current[dense]
		var distance: float = record.previous_position.distance_to(position)
		# Wolf risk enters strictly inside its radius; dog visual exposure
		# includes its boundary. Keep both denominators aligned with production.
		var outside: bool = distance > radius
		if record.species == SimTypes.Species.WOLF:
			outside = distance >= radius
		if outside:
			continue
		if record.start_nearest_target == null or distance < record.start_nearest_distance:
			record.start_nearest_target = target
			record.start_nearest_distance = distance
			record.start_nearest_position = position
		if record.species == SimTypes.Species.DOG and _current_flock(context, _world.tick) and position.distance_to(context.protection_anchor) < _world.ai.settings.protection_radius:
			record.start_protected_geometry = true
	if record.start_nearest_target != null:
		if record.eligible_tick < 0:
			record.eligible_tick = _world.tick
			record.eligible_usec = Time.get_ticks_usec() - _started_usec
		record.observe_exposure_tick(_world.tick, record.start_nearest_target)
	else:
		var reason: String = "GEOMETRY_ENDED"
		if _world.tick >= CLEAR_THREATS_TICK:
			reason = "THREATS_REMOVED"
		record.close_exposure(_world.tick, reason)
	if record.start_protected_geometry:
		record.protected_geometry_ticks += 1

func after_step(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	var tick: int = world.tick - 1
	for record: ProductionDogProtectionTrace in _records:
		_observe_actor(record, tick)
	if world.tick % QUALITY_PERIOD == 0:
		_sample_quality(tick)
	observed_steps += 1
	finished = world.tick >= END_TICK
	observer_usec += Time.get_ticks_usec() - started

func _observe_actor(record: ProductionDogProtectionTrace, tick: int) -> void:
	var dense: int = _world.store.resolve(record.handle)
	if dense < 0 or not _world.store.is_active(record.handle):
		record.alive = _world.store.is_alive(record.handle)
		if not record.alive and not record.removed_by_protocol and record.death_tick < 0:
			record.death_tick = tick + 1
		return
	var context: AgentContext = _world.ai.inspect(record.handle)
	var intent: MotionIntent = _world.intents.get_intent(record.handle, tick)
	var owned: bool = intent != null and intent.owner_token == context.task_token
	var position: Vector2 = _world.store.position_current[dense]
	var elapsed: int = Time.get_ticks_usec() - _started_usec
	record.active_observed_steps += 1
	record.missing_intent_steps += int(intent == null)
	record.unowned_intent_steps += int(intent != null and not owned)
	_observe_knowledge(record, context, tick, elapsed)
	var lease: CoordinationSystem.Lease = _world.ai.coordination.get_lease(record.handle, tick)
	var qualified: bool = valid_defend_evidence(_world, context, intent, lease, tick)
	if record.species == SimTypes.Species.DOG:
		if lease != null and lease.kind == CoordinationSystem.Kind.DEFEND and lease.owner_token == context.task_token and _world.store.is_active(lease.target):
			record.lease_ticks += 1
			if record.first_lease_tick < 0:
				record.first_lease_tick = tick
		_observe_dog(record, context, intent, position, tick, elapsed, qualified)
	else:
		_wolf_steps.append({"wolf": record.handle.key(), "tick": tick, "elapsed_usec": elapsed,
			"start_x": record.previous_position.x, "start_y": record.previous_position.y,
			"end_x": position.x, "end_y": position.y, "risk_geometry": record.start_nearest_target != null,
			"nearest_risk_dog": record.start_nearest_target.key() if record.start_nearest_target != null else "",
			"nearest_risk_distance": record.start_nearest_distance,
			"risk_dog_start_x": record.start_nearest_position.x if record.start_nearest_target != null else null,
			"risk_dog_start_y": record.start_nearest_position.y if record.start_nearest_target != null else null,
			"task": str(context.task_name), "task_token": context.task_token,
			"perception_tick": context.last_perception_tick, "decision_tick": context.last_decision_tick,
			"intent_present": intent != null, "intent_owned": owned,
			"behavior": SimTypes.Behavior.keys()[intent.behavior] if intent != null else "NONE",
			"intent_destination_x": intent.destination.x if intent != null else null,
			"intent_destination_y": intent.destination.y if intent != null else null,
			"intent_target": intent.target.key() if intent != null and intent.target != null else ""})
	if owned:
		record.record_motion(intent, position, tick, elapsed, qualified)
		if intent.behavior == record.response_behavior():
			record.peak_response_speed = maxf(record.peak_response_speed, _world.store.velocity_current[dense].length())

static func _current_flock(context: AgentContext, tick: int) -> bool:
	return context.flock_count > 0 and context.flock_sample_count > 0 and context.flock_sample_observed_tick >= 0 and tick < context.flock_sample_expires_tick

static func valid_defend_evidence(world: SimulationWorld, context: AgentContext, intent: MotionIntent, lease: CoordinationSystem.Lease, tick: int) -> bool:
	if intent == null or lease == null or context.species != SimTypes.Species.DOG:
		return false
	if not world.store.is_active(context.handle) or not world.store.is_active(lease.target):
		return false
	if intent.behavior != SimTypes.Behavior.INTERCEPT:
		return false
	if intent.actor == null or not intent.actor.same_life(context.handle) or tick >= intent.expires_tick:
		return false
	if not lease.actor.same_life(context.handle) or lease.kind != CoordinationSystem.Kind.DEFEND or tick >= lease.expires_tick:
		return false
	if lease.owner_token != context.task_token or intent.owner_token != context.task_token or intent.target == null or not intent.target.same_life(lease.target):
		return false
	var sighting: LocalObservation = context.observation_for(lease.target, tick)
	return (_current_flock(context, tick) and sighting != null
		and sighting.position.distance_to(context.protection_anchor) < world.ai.settings.protection_radius)

func _observe_knowledge(record: ProductionDogProtectionTrace, context: AgentContext, tick: int, elapsed: int) -> void:
	var targets: Array[AgentHandle] = _wolves if record.species == SimTypes.Species.DOG else _dogs
	for target: AgentHandle in targets:
		var sighting: LocalObservation = context.observation_for(target, tick)
		if sighting == null:
			continue
		if record.known_tick < 0:
			record.known_tick = tick
			record.known_usec = elapsed
			record.known_source = LocalObservation.Source.keys()[sighting.source]
		if record.direct_tick < 0 and sighting.last_direct_tick >= 0:
			record.direct_tick = tick
			record.direct_usec = elapsed

func _observe_dog(record: ProductionDogProtectionTrace, context: AgentContext, intent: MotionIntent, position: Vector2, tick: int, elapsed: int, qualified: bool) -> void:
	var owned: bool = intent != null and intent.owner_token == context.task_token
	var current_flock: bool = _current_flock(context, tick)
	var at_guard: bool = owned and intent.behavior == SimTypes.Behavior.GUARD and current_flock and position.distance_to(context.protection_anchor) <= _world.ai.settings.guard_arrival_distance
	if tick < THREAT_TICK and at_guard and record.guard_before_threat_tick < 0:
		record.guard_before_threat_tick = tick + 1
	if owned and intent.behavior == SimTypes.Behavior.GUARD and _world.ai.coordination.get_lease(record.handle, tick) == null:
		record.guard_without_lease_ticks += 1
	if tick >= CLEAR_THREATS_TICK:
		if not record.recovery_started:
			record.recovery_started = true
			record.recovery_eligible_tick = CLEAR_THREATS_TICK
			record.return_needed = not record.start_current_flock or record.previous_position.distance_to(record.start_anchor) > _world.ai.settings.guard_arrival_distance
		if owned and intent.behavior == SimTypes.Behavior.RETURN:
			var direction: Vector2 = (intent.destination - record.previous_position).normalized()
			record.return_motion_pixels += maxf(0.0, (position - record.previous_position).dot(direction))
		if at_guard and record.recovery_tick < 0:
			record.recovery_tick = tick + 1
			record.recovery_usec = elapsed
			record.recovery_v2_tick = tick + 1
			record.recovery_v2_usec = elapsed
			record.recovery_v2_kind = "DOG_GUARD"
	if record.observe_anchor(context.protection_anchor, current_flock):
		_record_anchor_change(record, context, position, tick)
	_dog_diagnostics.sample(_world, record, context, intent, position, tick, elapsed, _wolves)
	var row: Dictionary = _dog_diagnostics.contexts.back()
	var dense: int = _world.store.resolve(record.handle)
	row.merge({"start_x": record.previous_position.x, "start_y": record.previous_position.y,
		"start_velocity_x": record.start_velocity.x, "start_velocity_y": record.start_velocity.y,
		"end_velocity_x": _world.store.velocity_current[dense].x, "end_velocity_y": _world.store.velocity_current[dense].y,
		"start_anchor_x": record.start_anchor.x, "start_anchor_y": record.start_anchor.y,
		"start_flock_count": record.start_flock_count, "start_flock_tick": record.start_flock_tick,
		"start_current_sample_valid": record.start_current_flock,
		"start_protected_geometry": record.start_protected_geometry,
		"geometric_nearest_target": record.start_nearest_target.key() if record.start_nearest_target != null else "",
		"geometric_nearest_distance": record.start_nearest_distance, "qualified_defend_evidence": qualified,
		"step_displacement_pixels": position.distance_to(record.previous_position),
		"intent_destination_x": intent.destination.x if intent != null else null,
		"intent_destination_y": intent.destination.y if intent != null else null,
		"intent_speed": intent.speed if intent != null else null,
		"intent_mode": SimTypes.IntentMode.keys()[intent.mode] if intent != null else "NONE",
		"step_intended_progress_pixels": maxf(0.0, (position - record.previous_position).dot((intent.destination - record.previous_position).normalized())) if owned else 0.0,
		"at_guard": at_guard})

func _record_anchor_change(record: ProductionDogProtectionTrace, context: AgentContext, dog_position: Vector2, tick: int) -> void:
	var old_cell := Vector2i(floori(record.start_anchor.x / _world.grid.cell_size), floori(record.start_anchor.y / _world.grid.cell_size))
	var new_cell := Vector2i(floori(context.protection_anchor.x / _world.grid.cell_size), floori(context.protection_anchor.y / _world.grid.cell_size))
	var old_visible: int = 0
	var new_visible: int = 0
	for sheep: AgentHandle in _cohort:
		var dense: int = _world.store.resolve(sheep)
		if dense < 0 or not _world.store.is_active(sheep):
			continue
		var position: Vector2 = _world.store.position_current[dense]
		if position.distance_to(dog_position) > _world.config.perception_radius:
			continue
		var cell := Vector2i(floori(position.x / _world.grid.cell_size), floori(position.y / _world.grid.cell_size))
		old_visible += int(cell == old_cell)
		new_visible += int(cell == new_cell)
	_anchor_changes.append({"dog": record.handle.key(), "tick": tick,
		"old_anchor_x": record.start_anchor.x, "old_anchor_y": record.start_anchor.y,
		"new_anchor_x": context.protection_anchor.x, "new_anchor_y": context.protection_anchor.y,
		"change_pixels": record.start_anchor.distance_to(context.protection_anchor),
		"old_anchor_cell": str(old_cell), "new_anchor_cell": str(new_cell),
		"old_sample_tick": record.start_flock_tick, "new_sample_tick": context.flock_sample_observed_tick,
		"old_visible_cohort_sheep_at_end": old_visible, "new_visible_cohort_sheep_at_end": new_visible})

func _sample_quality(tick: int) -> void:
	var started: int = Time.get_ticks_usec()
	var cohort_active: int = 0
	var cohort_flee: int = 0
	for actor: AgentHandle in _cohort:
		var dense: int = _world.store.resolve(actor)
		var active: bool = dense >= 0 and _world.store.is_active(actor)
		var intent: MotionIntent = _world.intents.get_intent(actor, tick)
		var context: AgentContext = _world.ai.inspect(actor)
		var owned: bool = intent != null and context != null and intent.owner_token == context.task_token
		cohort_active += int(active)
		cohort_flee += int(active and owned and intent.behavior == SimTypes.Behavior.FLEE)
		_cohort_samples.append({"sheep": actor.key(), "input_tick": tick, "endpoint_tick": _world.tick,
			"active": active, "x": _world.store.position_current[dense].x if active else null,
			"y": _world.store.position_current[dense].y if active else null,
			"intent_present": intent != null, "intent_owned": owned,
			"behavior": SimTypes.Behavior.keys()[intent.behavior] if intent != null else "NONE",
			"perception_tick": context.last_perception_tick if context != null else -1,
			"decision_tick": context.last_decision_tick if context != null else -1})
	var background_active: int = 0
	var background_moved: int = 0
	var background_owned: int = 0
	var background_intrusions: int = 0
	var background_perceived: int = 0
	var background_decided: int = 0
	for index: int in _background.size():
		var actor: AgentHandle = _background[index]
		var dense: int = _world.store.resolve(actor)
		if dense < 0 or not _world.store.is_active(actor):
			continue
		background_active += 1
		var position: Vector2 = _world.store.position_current[dense]
		background_moved += int(position.distance_to(_background_sample_positions[index]) >= 1.0)
		_background_sample_positions[index] = position
		background_intrusions += int(ProductionDogProtectionGeometry.inside_foreground_region(position))
		var intent: MotionIntent = _world.intents.get_intent(actor, tick)
		var context: AgentContext = _world.ai.inspect(actor)
		background_owned += int(intent != null and context != null and intent.owner_token == context.task_token)
		if context != null:
			background_perceived += int(context.last_perception_tick > _background_perception_ticks[index])
			background_decided += int(context.last_decision_tick > _background_decision_ticks[index])
			_background_perception_ticks[index] = context.last_perception_tick
			_background_decision_ticks[index] = context.last_decision_tick
	_quality.append({"input_tick": tick, "endpoint_tick": _world.tick, "elapsed_usec": Time.get_ticks_usec() - _started_usec,
		"declared_cohort": 80, "cohort_active": cohort_active, "cohort_flee_sample": cohort_flee,
		"declared_background": _background.size(), "background_active": background_active,
		"background_owned_intents_sample": background_owned, "background_net_moved_ge_1px_since_sample": background_moved,
		"background_lives_perceived_since_sample": background_perceived, "background_lives_decided_since_sample": background_decided,
		"background_in_foreground_region_sample": background_intrusions})
	_quality_observer_usec += Time.get_ticks_usec() - started

func _on_capture(event: CaptureEvent) -> void:
	var started: int = Time.get_ticks_usec()
	_captures.append({"actor": event.actor.key(), "target": event.target.key(), "tick": event.tick,
		"x": event.position.x, "y": event.position.y})
	observer_usec += Time.get_ticks_usec() - started

func _fail(reason: String, details: Dictionary = {}) -> void:
	_fixture_error = reason
	_fixture_error_details = {"input_tick": _world.tick}
	_fixture_error_details.merge(details.duplicate(true))
	finished = true

func finish_report() -> Dictionary:
	var records: Array[Dictionary] = []
	for record: ProductionDogProtectionTrace in _records:
		record.close_exposure(record.exposure_last_visible_tick + 1, "OBSERVATION_WINDOW_ENDED")
		record.alive = _world.store.is_alive(record.handle)
		records.append(record.to_dictionary())
	var terminal: Array[Dictionary] = []
	for actor: AgentHandle in _cohort:
		terminal.append({"handle": actor.key(), "cohort": "observed_sheep", "alive": _world.store.is_alive(actor), "active": _world.store.is_active(actor)})
	for actor: AgentHandle in _background:
		terminal.append({"handle": actor.key(), "cohort": "background", "alive": _world.store.is_alive(actor), "active": _world.store.is_active(actor)})
	var requested_positions: Array[Array] = []
	for position: Vector2 in _requested_wolves:
		requested_positions.append([position.x, position.y])
	var report: Dictionary = report_header(_world, ProductionDogProtectionGeometry.VERSION, _seed, _sheep_count, _started_usec)
	report.merge({"fixture_valid": _fixture_error.is_empty(), "fixture_error": _fixture_error,
		"fixture_error_details": _fixture_error_details.duplicate(true),
		"geometry": ProductionDogProtectionGeometry.variant_name(geometry_variant),
		"stimulus_tick": THREAT_TICK, "remove_wolves_tick": CLEAR_THREATS_TICK,
		"declared_observed_sheep": 80, "declared_dogs": 4, "declared_wolves": 2,
		"registered_cohort": _cohort.size(), "registered_background": _background.size(),
		"registered_dogs": _dogs.size(), "registered_wolves": _wolves.size(),
		"requested_wolf_positions": requested_positions,
		"risk_radius": _world.ai.settings.dog_risk_radius, "perception_radius": _world.config.perception_radius,
		"protection_radius": _world.ai.settings.protection_radius, "guard_arrival_distance": _world.ai.settings.guard_arrival_distance,
		"records": records, "terminal": terminal, "initial_roster": _initial.duplicate(true), "preflight": _preflight.duplicate(true),
		"quality": _quality.duplicate(true), "cohort_samples": _cohort_samples.duplicate(true),
		"dog_contexts": _dog_diagnostics.contexts.duplicate(true), "dog_threats": _dog_diagnostics.threats.duplicate(true),
		"wolf_steps": _wolf_steps.duplicate(true), "anchor_changes": _anchor_changes.duplicate(true),
		"captures": _captures.duplicate(true), "events": _events.duplicate(true), "quality_observer_usec": _quality_observer_usec,
		"outcomes": [ProductionBehaviorTrace.summarize(records, "dog_intercept"), ProductionBehaviorTrace.summarize(records, "wolf_retreat_from_dog")],
		"eligibility": "All four dog and two wolf lives remain in records. Dog exposure is actual pre-AI perception geometry; protected_geometry additionally requires a valid historical flock sample and actual wolf within its anchor radius. Wolf exposure is actual dog-risk geometry. Known/direct, owned behavior, actual >=1px and narrower matching DEFEND lease evidence are separate. One defender per wolf is normal; four exposed dogs does not mean four required chasers.",
		"motion_evidence": "Each owned response contributes positive projection of real step displacement along that step's intent. >=1px is unchanged. Narrow lease progress additionally requires matching full actor/target, token, TTL, live target and valid observed protection evidence; it does not replace the broad four-dog denominator. Retreat before active intercept is visible in separate wolf steps and dog contexts, not labeled successful active driving.",
		"anchor_evidence": "Context sample centers/counts/ticks are historical AI observations. Anchor cells are derived from these centers. Change rows count only the fixed80 sheep geometrically visible at the post-motion endpoint, excluding background; they are not same-scan candidate scores or permanent flock membership. No production query or strategy is repeated by this observer.",
		"background_evidence": "920 extra sheep are ordinary active participants in motion, AI and common resources. Only 60tick snapshots are taken; net displacement >=1px is a sampled lower bound, and zero sampled intrusion/missing is not a continuous-window claim. Fixed seed does not hold autonomous foreground trajectories equal across loads.",
		"recovery_evidence": "All dogs still alive at wolf removal are separately eligible to regain a current local protection sample and GUARD inside the unchanged arrival distance. Already guarding is a valid recovery endpoint; no artificial extra movement is demanded. No permanent flock identity is claimed.",
	})
	return report
