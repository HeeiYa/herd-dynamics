class_name MotionSystem
extends RefCounted
## Reads only S(n) for steering and writes S(n+1); neighbors never see partial motion.
var _store: AgentStore
var _grid: SpatialGrid
var _intents: IntentBuffer
var _config: SimulationConfig
var _neighbors: Array[int] = []
var _crowd_field: CrowdMotionField

# Last fixed-step counters. Consumers must not sum frame snapshots as though
# they were all steps; the frame can contain zero, one or several fixed steps.
var field_build_usec: int = 0
var field_sample_usec: int = 0
var exact_sample_usec: int = 0
var field_agent_count: int = 0
var exact_agent_count: int = 0
var field_cell_visits: int = 0
var exact_candidate_visits: int = 0
var exact_neighbor_visits: int = 0
var aggregate_agent_contributions: int = 0
var moving_agent_count: int = 0
var displacement_sum: float = 0.0

func setup(store: AgentStore, grid: SpatialGrid, intents: IntentBuffer, config: SimulationConfig) -> void:
	_store = store
	_grid = grid
	_intents = intents
	_config = config
	_crowd_field = CrowdMotionField.new(config.world_size, config.crowd_cell_size)

func step(tick: int, dt: float) -> void:
	_prepare_step()
	for dense: int in range(_store.count):
		if _store.alive[dense] == 0:
			continue
		var intent: MotionIntent = _intents.get_intent(_store.handle_at(dense), tick)
		var guidance: Vector2 = _guidance(dense, intent)
		var desired_velocity: Vector2 = guidance
		var speed_limit: float = 0.0
		if intent != null:
			speed_limit = maxf(0.0, intent.speed)
			var steering: Vector2 = _local_steering(dense, intent)
			var preserve_advance: bool = intent.mode == SimTypes.IntentMode.FLEE or intent.mode == SimTypes.IntentMode.ATTACK
			if preserve_advance and not guidance.is_zero_approx():
				# Pressure may steer sideways but cannot cancel committed escape
				# or attack approach. Both backends enforce the same intent contract.
				var escape_direction: Vector2 = guidance.normalized()
				var backward_component: float = steering.dot(escape_direction)
				if backward_component < 0.0:
					steering -= escape_direction * backward_component
			desired_velocity += steering
			# A stopped grazer may yield softly to neighbors without resuming travel.
			if speed_limit == 0.0 and intent.mode == SimTypes.IntentMode.GRAZE:
				speed_limit = _config.separation_strength
		var velocity: Vector2 = _store.velocity_current[dense].move_toward(desired_velocity, _config.acceleration * dt)
		velocity = velocity.limit_length(speed_limit)
		var position: Vector2 = _store.position_current[dense] + velocity * dt
		var body_radius: float = _store.radius[dense]
		var lower: Vector2 = Vector2.ONE * body_radius
		var upper: Vector2 = _config.world_size - lower
		var bounded_position: Vector2 = position.clamp(lower, upper)
		if bounded_position.x != position.x:
			velocity.x = 0.0
		if bounded_position.y != position.y:
			velocity.y = 0.0
		_store.position_next[dense] = bounded_position
		_store.velocity_next[dense] = velocity
		var displacement: float = _store.position_current[dense].distance_to(bounded_position)
		displacement_sum += displacement
		if displacement > 0.0001:
			moving_agent_count += 1
		_update_facing(dense, velocity, guidance, intent)
	if _config.crowd_motion_enabled:
		field_cell_visits = _crowd_field.cell_visits
		exact_candidate_visits = _crowd_field.exact_candidate_visits
		aggregate_agent_contributions = _crowd_field.aggregate_agent_contributions

func _prepare_step() -> void:
	field_build_usec = 0
	field_sample_usec = 0
	exact_sample_usec = 0
	field_agent_count = 0
	exact_agent_count = 0
	field_cell_visits = 0
	exact_candidate_visits = 0
	exact_neighbor_visits = 0
	aggregate_agent_contributions = 0
	moving_agent_count = 0
	displacement_sum = 0.0
	if _config.crowd_motion_enabled:
		var started_usec: int = Time.get_ticks_usec() if _config.instrument_enabled else 0
		_crowd_field.rebuild(_store)
		if _config.instrument_enabled:
			field_build_usec = Time.get_ticks_usec() - started_usec

func _guidance(dense: int, intent: MotionIntent) -> Vector2:
	if intent == null or intent.mode == SimTypes.IntentMode.STOP or intent.mode == SimTypes.IntentMode.GRAZE:
		return Vector2.ZERO
	var offset: Vector2 = intent.destination - _store.position_current[dense]
	var distance: float = offset.length()
	if distance <= 0.0001:
		return Vector2.ZERO
	var arrival_radius: float = _config.arrival_radius
	if intent.mode == SimTypes.IntentMode.FLEE or intent.mode == SimTypes.IntentMode.ATTACK:
		arrival_radius = _store.radius[dense]
	var arrival_fraction: float = clampf(distance / maxf(arrival_radius, 0.0001), 0.0, 1.0)
	return offset / distance * maxf(0.0, intent.speed) * arrival_fraction

func _local_steering(dense: int, intent: MotionIntent) -> Vector2:
	if intent.mode == SimTypes.IntentMode.STOP:
		return Vector2.ZERO
	var started_usec: int = Time.get_ticks_usec() if _config.instrument_enabled else 0
	if _config.crowd_motion_enabled:
		var use_field: bool = _crowd_field.uses_dense_sample(dense, _config.neighbor_radius,
			_config.crowd_enter_count, _config.crowd_exit_count)
		if use_field:
			field_agent_count += 1
			var field_steering: Vector2 = _crowd_field.sample_steering(dense, intent.mode, _config)
			if _config.instrument_enabled:
				field_sample_usec += Time.get_ticks_usec() - started_usec
			return field_steering
		_crowd_field.query_exact(dense, _config.neighbor_radius, _neighbors)
	else:
		var candidates_before: int = _grid.candidate_count
		_grid.query(_store.position_current[dense], _config.neighbor_radius, -1, _store, _neighbors)
		exact_candidate_visits += _grid.candidate_count - candidates_before
	exact_agent_count += 1
	var steering: Vector2 = _exact_steering(dense, intent)
	if _config.instrument_enabled:
		exact_sample_usec += Time.get_ticks_usec() - started_usec
	return steering

func _exact_steering(dense: int, intent: MotionIntent) -> Vector2:
	var position: Vector2 = _store.position_current[dense]
	var separation: Vector2 = Vector2.ZERO
	var flock_position: Vector2 = Vector2.ZERO
	var flock_velocity: Vector2 = Vector2.ZERO
	var flock_count: int = 0
	var actor_slot: int = _store.handle_at(dense).slot
	for neighbor: int in _neighbors:
		if neighbor == dense:
			continue
		exact_neighbor_visits += 1
		var offset: Vector2 = position - _store.position_current[neighbor]
		var distance: float = offset.length()
		var direction: Vector2
		if distance <= 0.0001:
			direction = _overlap_direction(actor_slot, _store.handle_at(neighbor).slot)
		else:
			direction = offset / distance
		var desired_spacing: float = _store.radius[dense] + _store.radius[neighbor]
		var proximity: float = clampf(1.0 - distance / maxf(desired_spacing * 1.5, 0.0001), 0.0, 1.0)
		separation += direction * proximity
		if _store.species[dense] == SimTypes.Species.SHEEP and _store.species[neighbor] == SimTypes.Species.SHEEP:
			flock_position += _store.position_current[neighbor]
			flock_velocity += _store.velocity_current[neighbor]
			flock_count += 1
	separation = separation.limit_length(1.0) * _config.separation_strength
	if flock_count == 0 or intent.mode != SimTypes.IntentMode.MOVE:
		return separation
	var cohesion: Vector2 = (flock_position / flock_count - position) * _config.cohesion_weight
	var alignment: Vector2 = (flock_velocity / flock_count - _store.velocity_current[dense]) * _config.alignment_weight
	return separation + cohesion + alignment

func _overlap_direction(actor_slot: int, neighbor_slot: int) -> Vector2:
	# A symmetric pair receives equal/opposite directions, without random-stream use.
	var first: int = mini(actor_slot, neighbor_slot)
	var second: int = maxi(actor_slot, neighbor_slot)
	var angle: float = float((first * 73856093 + second * 19349663) % 360) * PI / 180.0
	var direction: Vector2 = Vector2.from_angle(angle)
	return direction if actor_slot < neighbor_slot else -direction

func _update_facing(dense: int, velocity: Vector2, guidance: Vector2, intent: MotionIntent) -> void:
	if velocity.length_squared() < _config.facing_min_speed * _config.facing_min_speed:
		return
	if intent != null and intent.behavior == SimTypes.Behavior.RETREAT and not guidance.is_zero_approx():
		# Retreat destinations are escape points, so face back toward the observed threat.
		_store.facing[dense] = -guidance.normalized()
	else:
		_store.facing[dense] = velocity.normalized()
