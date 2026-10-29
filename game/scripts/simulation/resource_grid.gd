class_name ResourceGrid
extends RefCounted
## Grass recovery is pure on read; only consume materializes authoritative state.
const MIN_GRAZABLE_AMOUNT: float = 0.03
var cell_size: float = 80.0
var columns: int
var rows: int
var cell_count: int
var _amount: PackedFloat32Array = PackedFloat32Array()
var _materialized_tick: PackedInt64Array = PackedInt64Array()
var _previous_amount: PackedFloat32Array = PackedFloat32Array()
var _previous_tick: PackedInt64Array = PackedInt64Array()
var _recovery_per_tick: float
var _world_size: Vector2
var _default_body_radius: float

func _init(config: SimulationConfig = null) -> void:
	if config == null:
		config = SimulationConfig.new()
	cell_size = config.resource_cell_size
	_world_size = config.world_size
	_default_body_radius = config.agent_radius
	columns = ceili(config.world_size.x / cell_size)
	rows = ceili(config.world_size.y / cell_size)
	cell_count = columns * rows
	_recovery_per_tick = config.grass_recovery_rate * config.fixed_dt
	_amount.resize(cell_count)
	_materialized_tick.resize(cell_count)
	_previous_amount.resize(cell_count)
	_previous_tick.resize(cell_count)
	reset(42)

func reset(random_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed ^ 7927
	for cell: int in cell_count:
		_amount[cell] = rng.randf_range(0.35, 1.0)
		_previous_amount[cell] = _amount[cell]
	_materialized_tick.fill(0)
	_previous_tick.fill(0)

func cell_bounds(cell: int) -> Rect2:
	var cell_y: int = floori(float(cell) / columns)
	var lower: Vector2 = Vector2(cell % columns, cell_y) * cell_size
	var upper: Vector2 = (lower + Vector2.ONE * cell_size).min(_world_size)
	return Rect2(lower, upper - lower)

func cell_center(cell: int) -> Vector2:
	return cell_bounds(cell).get_center()

func can_graze_at(cell: int, position: Vector2) -> bool:
	# The body center belongs to exactly one half-open cell. Clamping cell_at
	# alone would incorrectly authorize an out-of-world or adjacent-cell eater.
	return cell >= 0 and cell < cell_count and cell_bounds(cell).has_point(position)

func grazing_point(cell: int, handle: AgentHandle, body_radius: float) -> Vector2:
	var bounds: Rect2 = _reachable_bounds(cell, body_radius)
	assert(bounds.has_area(), "A selected grass cell must have reachable body-center area")
	# Fractional irrational sequences scatter identities without random-stream
	# consumption. Keep a margin inside the cell so steering can yield locally.
	var identity: float = float(handle.slot) + float(handle.generation) * 0.5
	var fraction := Vector2(fposmod(identity * 0.754877666, 1.0), fposmod(identity * 0.569840296, 1.0))
	fraction = Vector2.ONE * 0.15 + fraction * 0.7
	return bounds.position + bounds.size * fraction

func _reachable_bounds(cell: int, body_radius: float) -> Rect2:
	var inset: Vector2 = Vector2.ONE * body_radius
	return cell_bounds(cell).intersection(Rect2(inset, _world_size - inset * 2.0))

func cell_at(position: Vector2) -> int:
	return clampi(floori(position.y / cell_size), 0, rows - 1) * columns + clampi(floori(position.x / cell_size), 0, columns - 1)

func get_effective_amount(cell: int, tick: int) -> float:
	if cell < 0 or cell >= cell_count:
		return 0.0
	if tick < _materialized_tick[cell]:
		return clampf(_previous_amount[cell] + maxf(0.0, tick - _previous_tick[cell]) * _recovery_per_tick, 0.0, 1.0)
	return clampf(_amount[cell] + (tick - _materialized_tick[cell]) * _recovery_per_tick, 0.0, 1.0)

func consume(cell: int, requested: float, tick: int) -> float:
	assert(cell >= 0 and cell < cell_count)
	var committed_tick: int = tick + 1
	var available: float = get_effective_amount(cell, committed_tick)
	var consumed: float = minf(maxf(requested, 0.0), available)
	if _materialized_tick[cell] != committed_tick:
		_previous_amount[cell] = _amount[cell]
		_previous_tick[cell] = _materialized_tick[cell]
	_amount[cell] = available - consumed
	_materialized_tick[cell] = committed_tick
	return consumed

func best_cell(position: Vector2, search_radius: float, tick: int, excluded_cell: int = -1) -> int:
	var best: int = -1
	var best_score: float = -INF
	var min_x: int = maxi(0, floori((position.x - search_radius) / cell_size))
	var max_x: int = mini(columns - 1, floori((position.x + search_radius) / cell_size))
	var min_y: int = maxi(0, floori((position.y - search_radius) / cell_size))
	var max_y: int = mini(rows - 1, floori((position.y + search_radius) / cell_size))
	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			var cell: int = y * columns + x
			if cell == excluded_cell:
				continue
			if not _reachable_bounds(cell, _default_body_radius).has_area():
				continue
			var distance: float = position.distance_to(cell_center(cell))
			var available: float = get_effective_amount(cell, tick)
			if distance > search_radius or available < MIN_GRAZABLE_AMOUNT:
				continue
			var score: float = available - distance / maxf(search_radius, 1.0) * 0.3
			if score > best_score:
				best = cell
				best_score = score
	return best
