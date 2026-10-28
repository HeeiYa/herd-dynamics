class_name SpatialGrid
extends RefCounted
## Rebuilt from current state. Linked slots reuse storage; exact queries never cap candidates.
var cell_size: float
var columns: int
var rows: int
var candidate_count: int = 0
var max_occupancy: int = 0
var _heads: PackedInt32Array = PackedInt32Array()
var _next: PackedInt32Array = PackedInt32Array()
var _occupancy: PackedInt32Array = PackedInt32Array()

func _init(world_size: Vector2 = Vector2(1600, 1000), width: float = 80.0) -> void:
	cell_size = width
	columns = ceili(world_size.x / width)
	rows = ceili(world_size.y / width)
	_heads.resize(columns * rows * 3)
	_occupancy.resize(columns * rows)

func rebuild(store: AgentStore) -> void:
	_heads.fill(-1)
	_occupancy.fill(0)
	if _next.size() < store.capacity:
		_next.resize(store.capacity)
	candidate_count = 0
	max_occupancy = 0
	for dense: int in store.count:
		if store.alive[dense] == 0:
			continue
		var position: Vector2 = store.position_current[dense]
		var x: int = clampi(floori(position.x / cell_size), 0, columns - 1)
		var y: int = clampi(floori(position.y / cell_size), 0, rows - 1)
		var cell: int = y * columns + x
		var head: int = cell * 3 + store.species[dense]
		_next[dense] = _heads[head]
		_heads[head] = dense
		_occupancy[cell] += 1
		max_occupancy = maxi(max_occupancy, _occupancy[cell])

func query(center: Vector2, search_radius: float, species_filter: int, store: AgentStore, output: Array[int]) -> void:
	output.clear()
	var min_x: int = maxi(0, floori((center.x - search_radius) / cell_size))
	var max_x: int = mini(columns - 1, floori((center.x + search_radius) / cell_size))
	var min_y: int = maxi(0, floori((center.y - search_radius) / cell_size))
	var max_y: int = mini(rows - 1, floori((center.y + search_radius) / cell_size))
	var first_species: int = maxi(0, species_filter)
	var last_species: int = species_filter if species_filter >= 0 else 2
	var radius_squared: float = search_radius * search_radius
	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			for kind: int in range(first_species, last_species + 1):
				var dense: int = _heads[(y * columns + x) * 3 + kind]
				while dense >= 0:
					candidate_count += 1
					if store.alive[dense] != 0 and center.distance_squared_to(store.position_current[dense]) <= radius_squared:
						output.append(dense)
					dense = _next[dense]
