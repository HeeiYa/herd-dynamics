class_name CrowdMotionField
extends RefCounted
## Anonymous movement summaries rebuilt once from S(n). Dense row links are valid
## only until the next build; persistent hysteresis is keyed by complete lives.
## Dense sampling visits cells, never the members of a dense cell. The query
## square supplies candidates; only a centroid inside the exact circle contributes.
## Such a summary can include bodies up to sqrt(2) * cell_size beyond that circle.

const GOLDEN_ANGLE_RADIANS: float = 2.399963229728653

var built_agent_count: int = 0
var cell_visits: int = 0
var exact_candidate_visits: int = 0
var aggregate_agent_contributions: int = 0
var columns: int
var rows: int
var cell_size: float

var _store: AgentStore
var _counts: PackedInt32Array = PackedInt32Array()
var _position_sums: PackedVector2Array = PackedVector2Array()
var _radius_sums: PackedFloat32Array = PackedFloat32Array()
var _sheep_counts: PackedInt32Array = PackedInt32Array()
var _sheep_position_sums: PackedVector2Array = PackedVector2Array()
var _sheep_velocity_sums: PackedVector2Array = PackedVector2Array()
var _heads: PackedInt32Array = PackedInt32Array()
var _next: PackedInt32Array = PackedInt32Array()
var _dense_lives: Dictionary[AgentHandle, bool] = {}
var _indexed_life_revision: int = -1
var _indexed_epoch: int = -1
var _query_min: Vector2i
var _query_max: Vector2i
var _prepared_dense: int = -1
var _prepared_radius: float = 0.0

func _init(world_size: Vector2, width: float) -> void:
	assert(width > 0.0 and world_size.x > 0.0 and world_size.y > 0.0)
	cell_size = width
	columns = ceili(world_size.x / width)
	rows = ceili(world_size.y / width)
	var cell_count: int = columns * rows
	_counts.resize(cell_count)
	_position_sums.resize(cell_count)
	_radius_sums.resize(cell_count)
	_sheep_counts.resize(cell_count)
	_sheep_position_sums.resize(cell_count)
	_sheep_velocity_sums.resize(cell_count)
	_heads.resize(cell_count)

func rebuild(store: AgentStore) -> void:
	_store = store
	_expire_dead_lives()
	_counts.fill(0)
	_position_sums.fill(Vector2.ZERO)
	_radius_sums.fill(0.0)
	_sheep_counts.fill(0)
	_sheep_position_sums.fill(Vector2.ZERO)
	_sheep_velocity_sums.fill(Vector2.ZERO)
	_heads.fill(-1)
	if _next.size() < store.capacity:
		_next.resize(store.capacity)
	built_agent_count = 0
	cell_visits = 0
	exact_candidate_visits = 0
	aggregate_agent_contributions = 0
	_prepared_dense = -1
	for dense: int in range(store.count):
		if store.alive[dense] == 0:
			continue
		var position: Vector2 = store.position_current[dense]
		var cell: int = _cell_at(position)
		_next[dense] = _heads[cell]
		_heads[cell] = dense
		_counts[cell] += 1
		_position_sums[cell] += position
		_radius_sums[cell] += store.radius[dense]
		if store.species[dense] == SimTypes.Species.SHEEP:
			_sheep_counts[cell] += 1
			_sheep_position_sums[cell] += position
			_sheep_velocity_sums[cell] += store.velocity_current[dense]
		built_agent_count += 1
	_indexed_life_revision = store.life_revision
	_indexed_epoch = store.epoch

func uses_dense_sample(dense: int, search_radius: float, enter_count: int, exit_count: int) -> bool:
	# Count the complete candidate square before deciding the backend. Therefore
	# an exact query can never visit more than enter_count - 1 bodies, including self.
	assert(enter_count > exit_count and exit_count >= 1)
	assert(_indexed_life_revision == _store.life_revision)
	_prepare_query(_store.position_current[dense], search_radius)
	_prepared_dense = dense
	_prepared_radius = search_radius
	var candidate_count: int = 0
	for y: int in range(_query_min.y, _query_max.y + 1):
		for x: int in range(_query_min.x, _query_max.x + 1):
			cell_visits += 1
			candidate_count += _counts[y * columns + x]
	var handle: AgentHandle = _store.handle_at(dense)
	var was_dense: bool = _dense_lives.has(handle)
	if candidate_count >= enter_count:
		_dense_lives[handle] = true
		return true
	if was_dense and candidate_count > exit_count:
		return true
	_dense_lives.erase(handle)
	return false

func query_exact(dense: int, search_radius: float, output: Array[int]) -> void:
	# Called only after uses_dense_sample returned false for this actor and radius.
	# Reusing the prepared bounds avoids another coordinate conversion. No consumer
	# may interleave queries: MotionSystem consumes one actor completely at a time.
	assert(_prepared_dense == dense and _prepared_radius == search_radius)
	output.clear()
	var position: Vector2 = _store.position_current[dense]
	var radius_squared: float = search_radius * search_radius
	for y: int in range(_query_min.y, _query_max.y + 1):
		for x: int in range(_query_min.x, _query_max.x + 1):
			cell_visits += 1
			var neighbor: int = _heads[y * columns + x]
			while neighbor >= 0:
				exact_candidate_visits += 1
				if position.distance_squared_to(_store.position_current[neighbor]) <= radius_squared:
					output.append(neighbor)
				neighbor = _next[neighbor]

func sample_steering(dense: int, intent_mode: int, config: SimulationConfig) -> Vector2:
	# Centroids and mean radii approximate pair pressure; sheep-only sums preserve
	# species-specific alignment. This is deliberately not an exact pair solver.
	assert(_prepared_dense == dense and _prepared_radius == config.neighbor_radius)
	var position: Vector2 = _store.position_current[dense]
	var velocity: Vector2 = _store.velocity_current[dense]
	var body_radius: float = _store.radius[dense]
	var own_cell: int = _cell_at(position)
	var is_sheep: bool = _store.species[dense] == SimTypes.Species.SHEEP
	var separation: Vector2 = Vector2.ZERO
	var flock_position: Vector2 = Vector2.ZERO
	var flock_velocity: Vector2 = Vector2.ZERO
	var flock_count: int = 0
	var radius_squared: float = config.neighbor_radius * config.neighbor_radius
	for y: int in range(_query_min.y, _query_max.y + 1):
		for x: int in range(_query_min.x, _query_max.x + 1):
			cell_visits += 1
			var cell: int = y * columns + x
			var neighbor_count: int = _counts[cell]
			if neighbor_count == 0:
				continue
			var position_sum: Vector2 = _position_sums[cell]
			var radius_sum: float = _radius_sums[cell]
			var sheep_count: int = _sheep_counts[cell]
			var sheep_position_sum: Vector2 = _sheep_position_sums[cell]
			var sheep_velocity_sum: Vector2 = _sheep_velocity_sums[cell]
			if cell == own_cell:
				neighbor_count -= 1
				position_sum -= position
				radius_sum -= body_radius
				if is_sheep:
					sheep_count -= 1
					sheep_position_sum -= position
					sheep_velocity_sum -= velocity
			if neighbor_count == 0:
				continue
			var offset: Vector2 = position - position_sum / neighbor_count
			if offset.length_squared() > radius_squared:
				continue
			aggregate_agent_contributions += neighbor_count
			var distance: float = offset.length()
			var direction: Vector2
			if distance <= 0.0001:
				direction = _overlap_direction(_store.handle_at(dense), position, body_radius, config.world_size)
			else:
				direction = offset / distance
			var desired_spacing: float = body_radius + radius_sum / neighbor_count
			var proximity: float = clampf(1.0 - distance / maxf(desired_spacing * 1.5, 0.0001), 0.0, 1.0)
			separation += direction * proximity * neighbor_count
			if is_sheep and sheep_count > 0:
				flock_count += sheep_count
				flock_position += sheep_position_sum
				flock_velocity += sheep_velocity_sum
	var unbounded_separation: Vector2 = separation
	separation = _remove_outward_pressure(separation, position, body_radius, config.world_size)
	if separation.is_zero_approx() and not unbounded_separation.is_zero_approx():
		# A centroid can place all pressure outside a corner. A bounded identity
		# direction supplies a finite escape from that degenerate projection.
		separation = _overlap_direction(_store.handle_at(dense), position, body_radius, config.world_size)
	separation = separation.limit_length(1.0) * config.separation_strength
	if flock_count == 0 or intent_mode != SimTypes.IntentMode.MOVE:
		return separation
	var cohesion: Vector2 = (flock_position / flock_count - position) * config.cohesion_weight
	var alignment: Vector2 = (flock_velocity / flock_count - velocity) * config.alignment_weight
	return separation + cohesion + alignment

func maximum_cells_per_query(search_radius: float) -> int:
	# Any interval of length 2r intersects at most ceil(2r/h)+1 cells per axis.
	var maximum_axis_cells: int = ceili(2.0 * search_radius / cell_size) + 1
	return maximum_axis_cells * maximum_axis_cells

func _prepare_query(position: Vector2, search_radius: float) -> void:
	_query_min = Vector2i(
		clampi(floori((position.x - search_radius) / cell_size), 0, columns - 1),
		clampi(floori((position.y - search_radius) / cell_size), 0, rows - 1))
	_query_max = Vector2i(
		clampi(floori((position.x + search_radius) / cell_size), 0, columns - 1),
		clampi(floori((position.y + search_radius) / cell_size), 0, rows - 1))

func _cell_at(position: Vector2) -> int:
	var x: int = clampi(floori(position.x / cell_size), 0, columns - 1)
	var y: int = clampi(floori(position.y / cell_size), 0, rows - 1)
	return y * columns + x

func _expire_dead_lives() -> void:
	if _indexed_epoch != _store.epoch:
		_dense_lives.clear()
	elif _indexed_life_revision != _store.life_revision:
		for handle: AgentHandle in _dense_lives.keys():
			if not _store.is_alive(handle):
				_dense_lives.erase(handle)

func _overlap_direction(handle: AgentHandle, position: Vector2, body_radius: float, world_size: Vector2) -> Vector2:
	# The full life identity breaks coincidence without consuming a random stream.
	# Irrational angular spacing avoids assigning all nearby slots the same axis.
	var life_seed: int = handle.slot + handle.generation * 31 + handle.world_epoch * 131
	var angle: float = fmod(float(life_seed) * GOLDEN_ANGLE_RADIANS, TAU)
	var direction: Vector2 = Vector2.from_angle(angle)
	# Start the soft wall response one body radius before hard contact. Restricting
	# it to exact contact makes a centroid alternate between outward pressure and
	# inward fallback every step, creating movement without meaningful progress.
	var soft_wall_distance: float = body_radius + body_radius
	if position.x <= soft_wall_distance:
		direction.x = absf(direction.x)
	elif position.x >= world_size.x - soft_wall_distance:
		direction.x = -absf(direction.x)
	if position.y <= soft_wall_distance:
		direction.y = absf(direction.y)
	elif position.y >= world_size.y - soft_wall_distance:
		direction.y = -absf(direction.y)
	return direction

func _remove_outward_pressure(pressure: Vector2, position: Vector2, body_radius: float, world_size: Vector2) -> Vector2:
	# Anticipate hard contact within a body-radius band. Remove wall-directed
	# components before limiting force so usable tangents retain their strength.
	var soft_wall_distance: float = body_radius + body_radius
	if position.x <= soft_wall_distance and pressure.x < 0.0:
		pressure.x = 0.0
	elif position.x >= world_size.x - soft_wall_distance and pressure.x > 0.0:
		pressure.x = 0.0
	if position.y <= soft_wall_distance and pressure.y < 0.0:
		pressure.y = 0.0
	elif position.y >= world_size.y - soft_wall_distance and pressure.y > 0.0:
		pressure.y = 0.0
	return pressure
