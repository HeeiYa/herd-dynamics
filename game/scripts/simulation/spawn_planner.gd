class_name SpawnPlanner
extends RefCounted
## Initial placement for the planned layouts. A reset builds one complete plan
## from the scenario seed; stage 0 then consumes it in creation order. The plan
## owns its random stream, so presentation and AI never shift these positions.
##
## Sheep are split into herds whose footprint follows the head count and a
## target area per sheep. Herds are lumpy ellipses kept apart by a gap; members
## keep a minimum spacing. All searches have fixed attempt budgets. When space
## runs out the best attempted point is accepted and counted as relaxed.

class Herd extends RefCounted:
	var center: Vector2
	var radius: float
	var aspect: float = 1.0
	var rotation: float = 0.0
	var lobe_phase: float = 0.0
	var lobe_amount: float = 0.0
	var member_count: int = 0

	## Boundary distance in a direction, including aspect and soft lobes.
	func reach(angle: float) -> float:
		var local: float = angle - rotation
		var ellipse := Vector2(cos(local) * aspect, sin(local) / aspect)
		var lobes: float = 1.0 + lobe_amount * sin(3.0 * angle + lobe_phase) + lobe_amount * 0.5 * sin(5.0 * angle + lobe_phase * 1.7)
		return radius * ellipse.length() * lobes

class Profile extends RefCounted:
	var sheep_per_herd: float
	var area_per_sheep: float
	var herd_gap: float
	var wolf_packs: int
	var wolf_clearance: float

const CENTER_ATTEMPTS: int = 48
const MEMBER_ATTEMPTS: int = 14
const SPILL_ATTEMPTS: int = 64
const WOLF_PACK_SPREAD: float = 42.0
const THREAT_ATTEMPTS: int = 64
# Herds may cover at most this share of the usable pasture before the planner
# raises density instead of pushing herds off the map.
const MAX_HERD_COVERAGE: float = 0.62

var herds: Array[Herd] = []
var relaxed_placements: int = 0
var spill_placements: int = 0
var density_scale: float = 1.0
var planned_counts: PackedInt32Array = PackedInt32Array([0, 0, 0])

var _random := RandomNumberGenerator.new()
var _config: SimulationConfig
var _bounds: Rect2
var _spacing: float
var _queues: Array[PackedVector2Array] = [PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]
var _cursors: PackedInt32Array = PackedInt32Array([0, 0, 0])
var _wolf_centers: PackedVector2Array = PackedVector2Array()
# Planner-private spacing index over planned points; never the live grid.
var _occupied: Dictionary[Vector2i, PackedVector2Array] = {}

func _init(config: SimulationConfig, scenario: ScenarioConfig) -> void:
	_config = config
	var margin: float = config.agent_radius * 2.0
	_bounds = Rect2(Vector2.ONE * margin, config.world_size - Vector2.ONE * margin * 2.0)
	_spacing = config.agent_radius * 2.0
	# A distinct stream from the world's legacy RNG and from decoration seeds.
	_random.seed = hash(Vector2i(scenario.random_seed, 0x5eed))
	var profile: Profile = _profile(scenario.layout)
	_plan_herds(scenario.sheep_count, profile)
	_plan_threat_centers(scenario.wolf_count, profile)
	_plan_sheep(scenario.sheep_count)
	_plan_dogs(scenario.dog_count)
	_plan_wolves(scenario.wolf_count)
	for species: int in range(3):
		planned_counts[species] = _queues[species].size()

## Next creation position. Initial members come from the plan in order; later
## spawn commands join an existing herd (or the pasture) with the same rules.
func next_position(species: int) -> Vector2:
	if _cursors[species] < _queues[species].size():
		var planned: Vector2 = _queues[species][_cursors[species]]
		_cursors[species] += 1
		return planned
	if species == SimTypes.Species.WOLF:
		return _threat_position(_random.randf_range(0.0, TAU), 0.0)
	if herds.is_empty():
		return _place(_bounds.get_center(), minf(_bounds.size.x, _bounds.size.y) * 0.3)
	var herd: Herd = herds[_random.randi_range(0, herds.size() - 1)]
	if species == SimTypes.Species.DOG:
		return _edge_position(herd)
	return _herd_point(herd)

func describe() -> String:
	var text: String = "%d 个羊群 · 密度系数 %.2f" % [herds.size(), density_scale]
	if spill_placements > 0:
		text += " · %d 个扩展到空闲区域" % spill_placements
	if relaxed_placements > 0:
		text += " · 空间不足，%d 个以较小间距放置" % relaxed_placements
	return text

func _profile(layout: ScenarioConfig.Layout) -> Profile:
	var profile := Profile.new()
	match layout:
		ScenarioConfig.Layout.SCATTERED:
			profile.sheep_per_herd = 18.0
			profile.area_per_sheep = 2600.0
			profile.herd_gap = 90.0
			profile.wolf_packs = 2
			profile.wolf_clearance = 220.0
		ScenarioConfig.Layout.HERDS_AND_THREATS:
			profile.sheep_per_herd = 45.0
			profile.area_per_sheep = 1300.0
			profile.herd_gap = 140.0
			profile.wolf_packs = 3
			profile.wolf_clearance = 200.0
		_:
			profile.sheep_per_herd = 24.0
			profile.area_per_sheep = 1500.0
			profile.herd_gap = 70.0
			profile.wolf_packs = 1
			profile.wolf_clearance = 230.0
	return profile

func _plan_herds(sheep_count: int, profile: Profile) -> void:
	if sheep_count <= 0:
		return
	var herd_count: int = clampi(roundi(float(sheep_count) / profile.sheep_per_herd), 1, 12)
	if profile.wolf_packs >= 3:
		herd_count = maxi(herd_count, mini(3, sheep_count))
	var usable_area: float = _bounds.get_area() * MAX_HERD_COVERAGE
	var required_area: float = sheep_count * profile.area_per_sheep
	density_scale = maxf(1.0, required_area / usable_area)
	var area_per_sheep: float = profile.area_per_sheep / density_scale
	# Keep the body diameter even when herd footprints reach their area budget.
	# A full herd spills into free pasture before any spacing is relaxed.
	# Uneven herd sizes look less staged than an equal split.
	var weights: PackedFloat32Array = PackedFloat32Array()
	var weight_total: float = 0.0
	for index: int in herd_count:
		var weight: float = _random.randf_range(0.6, 1.4)
		weights.append(weight)
		weight_total += weight
	var assigned: int = 0
	for index: int in herd_count:
		var herd := Herd.new()
		herd.member_count = roundi(sheep_count * weights[index] / weight_total)
		if index == herd_count - 1:
			herd.member_count = sheep_count - assigned
		herd.member_count = maxi(0, mini(herd.member_count, sheep_count - assigned))
		assigned += herd.member_count
		herd.radius = sqrt(maxf(1.0, herd.member_count) * area_per_sheep / PI)
		herd.aspect = _random.randf_range(0.78, 1.28)
		herd.rotation = _random.randf_range(0.0, PI)
		herd.lobe_phase = _random.randf_range(0.0, TAU)
		herd.lobe_amount = _random.randf_range(0.06, 0.16)
		herd.center = _herd_center(herd, profile.herd_gap)
		herds.append(herd)

func _herd_center(herd: Herd, gap: float) -> Vector2:
	var inset: float = minf(herd.radius * 1.15, minf(_bounds.size.x, _bounds.size.y) * 0.45)
	var area := _bounds.grow(-inset)
	var best: Vector2 = area.get_center()
	var best_clearance: float = -INF
	for attempt: int in CENTER_ATTEMPTS:
		var candidate := Vector2(_random.randf_range(area.position.x, area.end.x), _random.randf_range(area.position.y, area.end.y))
		var clearance: float = INF
		for other: Herd in herds:
			clearance = minf(clearance, candidate.distance_to(other.center) - other.radius - herd.radius - gap)
		if clearance >= 0.0:
			return candidate
		if clearance > best_clearance:
			best_clearance = clearance
			best = candidate
	return best

func _plan_sheep(sheep_count: int) -> void:
	for herd: Herd in herds:
		for member: int in herd.member_count:
			_queues[SimTypes.Species.SHEEP].append(_herd_point(herd))
	assert(_queues[SimTypes.Species.SHEEP].size() == sheep_count)

func _herd_point(herd: Herd) -> Vector2:
	var best: Vector2 = herd.center
	var best_gap: float = -INF
	for attempt: int in MEMBER_ATTEMPTS:
		var angle: float = _random.randf_range(0.0, TAU)
		# Exponent above 0.5 keeps the core slightly denser than the rim.
		var distance: float = pow(_random.randf(), 0.62) * herd.reach(angle)
		var candidate: Vector2 = _clamped(herd.center + Vector2.from_angle(angle) * distance)
		if not _outside_threat_reservations(candidate):
			continue
		var gap: float = _nearest_gap(candidate)
		if gap >= _spacing:
			_occupy(candidate)
			return candidate
		if gap > best_gap:
			best_gap = gap
			best = candidate
	return _spill_sheep(best, best_gap)

## Finite whole-pasture fallback. Only exhaustion permits actual overlap.
func _spill_sheep(best: Vector2, best_gap: float) -> Vector2:
	spill_placements += 1
	for attempt: int in SPILL_ATTEMPTS:
		var candidate: Vector2 = _bounds.position + Vector2(_random.randf(), _random.randf()) * _bounds.size
		if not _outside_threat_reservations(candidate):
			continue
		var gap: float = _nearest_gap(candidate)
		if gap >= _spacing:
			_occupy(candidate)
			return candidate
		if gap > best_gap:
			best = candidate
			best_gap = gap
	relaxed_placements += 1
	_occupy(best)
	return best

func _outside_threat_reservations(point: Vector2) -> bool:
	# Reserve actual pack footprints, so spilled sheep do not start under wolves.
	var clearance: float = _config.perception_radius * 0.5 + WOLF_PACK_SPREAD + _config.agent_radius
	for center: Vector2 in _wolf_centers:
		if point.distance_squared_to(center) < clearance * clearance:
			return false
	return true

func _plan_dogs(dog_count: int) -> void:
	if herds.is_empty():
		for index: int in dog_count:
			_queues[SimTypes.Species.DOG].append(_place(_bounds.get_center(), 120.0))
		return
	# Larger herds receive dogs first; each dog starts just outside its herd.
	var order: Array[Herd] = herds.duplicate()
	order.sort_custom(func(left: Herd, right: Herd) -> bool: return left.member_count > right.member_count)
	for index: int in dog_count:
		_queues[SimTypes.Species.DOG].append(_edge_position(order[index % order.size()]))

func _edge_position(herd: Herd) -> Vector2:
	var angle: float = _random.randf_range(0.0, TAU)
	var distance: float = herd.reach(angle) + _random.randf_range(18.0, 46.0)
	return _place(herd.center + Vector2.from_angle(angle) * distance, 20.0)

func _plan_threat_centers(wolf_count: int, profile: Profile) -> void:
	if wolf_count <= 0:
		return
	var pack_count: int = clampi(profile.wolf_packs, 1, wolf_count)
	var base_angle: float = _random.randf_range(0.0, TAU)
	for pack: int in pack_count:
		# Packs approach from different sides of the pasture.
		var bearing: float = base_angle + TAU * pack / pack_count + _random.randf_range(-0.4, 0.4)
		_wolf_centers.append(_threat_position(bearing, profile.wolf_clearance))

func _plan_wolves(wolf_count: int) -> void:
	var pack_count: int = _wolf_centers.size()
	for pack: int in pack_count:
		var members: int = wolf_count / pack_count + (1 if pack < wolf_count % pack_count else 0)
		for member: int in members:
			_queues[SimTypes.Species.WOLF].append(_place(_wolf_centers[pack], WOLF_PACK_SPREAD))

## A point far enough from every herd that wolves start by searching, biased
## toward the given bearing from the pasture center.
func _threat_position(bearing: float, clearance: float) -> Vector2:
	var center: Vector2 = _bounds.get_center()
	var best: Vector2 = _clamped(center + Vector2.from_angle(bearing) * _bounds.size.length())
	var best_score: float = -INF
	for attempt: int in THREAT_ATTEMPTS:
		var angle: float = bearing + _random.randf_range(-0.6, 0.6)
		var distance: float = _random.randf_range(0.35, 1.0) * _bounds.size.length() * 0.5
		var candidate: Vector2 = _clamped(center + Vector2.from_angle(angle) * distance)
		var herd_gap: float = INF
		for herd: Herd in herds:
			herd_gap = minf(herd_gap, candidate.distance_to(herd.center) - herd.reach(herd.center.angle_to_point(candidate)))
		if herds.is_empty():
			herd_gap = clearance
		# Prefer meeting the clearance, then staying away from the walls.
		var wall: float = minf(minf(candidate.x - _bounds.position.x, _bounds.end.x - candidate.x), minf(candidate.y - _bounds.position.y, _bounds.end.y - candidate.y))
		var score: float = minf(herd_gap, clearance) * 4.0 + minf(wall, 120.0)
		if score > best_score:
			best_score = score
			best = candidate
	return best

## Spaced point around an anchor, without herd shape constraints.
func _place(anchor: Vector2, spread: float) -> Vector2:
	var best: Vector2 = _clamped(anchor)
	var best_gap: float = -INF
	for attempt: int in MEMBER_ATTEMPTS:
		var offset: Vector2 = Vector2.from_angle(_random.randf_range(0.0, TAU)) * sqrt(_random.randf()) * spread
		var candidate: Vector2 = _clamped(anchor + offset)
		var gap: float = _nearest_gap(candidate)
		if gap >= _spacing:
			_occupy(candidate)
			return candidate
		if gap > best_gap:
			best_gap = gap
			best = candidate
	relaxed_placements += 1
	_occupy(best)
	return best

func _clamped(point: Vector2) -> Vector2:
	return point.clamp(_bounds.position, _bounds.end)

func _cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / _spacing), floori(point.y / _spacing))

func _occupy(point: Vector2) -> void:
	var cell: Vector2i = _cell(point)
	# Packed arrays are values: read, append and store back explicitly.
	var members: PackedVector2Array = _occupied.get(cell, PackedVector2Array())
	members.append(point)
	_occupied[cell] = members

func _nearest_gap(point: Vector2) -> float:
	var cell: Vector2i = _cell(point)
	var nearest: float = INF
	for y: int in range(cell.y - 1, cell.y + 2):
		for x: int in range(cell.x - 1, cell.x + 2):
			var members: PackedVector2Array = _occupied.get(Vector2i(x, y), PackedVector2Array())
			for other: Vector2 in members:
				nearest = minf(nearest, point.distance_to(other))
	return nearest
