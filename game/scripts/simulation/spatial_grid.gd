class_name SpatialGrid
extends RefCounted
## Rebuilt from current state. Linked slots reuse storage; exact queries never cap candidates.
class FlockSample extends RefCounted:
	var count: int = 0
	var position_sum: Vector2 = Vector2.ZERO

class CandidateBatch extends RefCounted:
	var radius: float
	var members: Array[int] = []

# This private index cache never survives rebuild or leaves the grid. It shares
# only synchronous queries on the same S(n), not memories or direct visibility.
const MAX_CACHED_CANDIDATES: int = 16384
var shared_hits: int = 0
var shared_builds: int = 0
var shared_fallbacks: int = 0
var shared_filter_visits: int = 0
var shared_candidate_references: int = 0
var _candidate_batches: Dictionary[Vector2i, CandidateBatch] = {}
var _cell_flock_sample: FlockSample = FlockSample.new()

var cell_size: float
var columns: int
var rows: int
var candidate_count: int = 0
var aggregated_cell_count: int = 0
var max_occupancy: int = 0
var _heads: PackedInt32Array = PackedInt32Array()
var _next: PackedInt32Array = PackedInt32Array()
var _occupancy: PackedInt32Array = PackedInt32Array()
var _flock_counts: PackedInt32Array = PackedInt32Array()
var _flock_sums: PackedVector2Array = PackedVector2Array()
var _flock_min: PackedVector2Array = PackedVector2Array()
var _flock_max: PackedVector2Array = PackedVector2Array()
var _indexed_life_revision: int = -1

func _init(world_size: Vector2 = Vector2(1600, 1000), width: float = 80.0) -> void:
	cell_size = width
	columns = ceili(world_size.x / width)
	rows = ceili(world_size.y / width)
	_heads.resize(columns * rows * 3)
	_occupancy.resize(columns * rows)
	_flock_counts.resize(columns * rows)
	_flock_sums.resize(columns * rows)
	_flock_min.resize(columns * rows)
	_flock_max.resize(columns * rows)

func rebuild(store: AgentStore) -> void:
	_candidate_batches.clear()
	shared_hits = 0
	shared_builds = 0
	shared_fallbacks = 0
	shared_filter_visits = 0
	shared_candidate_references = 0
	_heads.fill(-1)
	_occupancy.fill(0)
	_flock_counts.fill(0)
	_flock_sums.fill(Vector2.ZERO)
	if _next.size() < store.capacity:
		_next.resize(store.capacity)
	candidate_count = 0
	aggregated_cell_count = 0
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
		if store.species[dense] == SimTypes.Species.SHEEP:
			if _flock_counts[cell] == 0:
				_flock_min[cell] = position
				_flock_max[cell] = position
			else:
				_flock_min[cell] = _flock_min[cell].min(position)
				_flock_max[cell] = _flock_max[cell].max(position)
			_flock_counts[cell] += 1
			_flock_sums[cell] += position
	_indexed_life_revision = store.life_revision

func query_shared(center: Vector2, search_radius: float, species_filter: int, store: AgentStore, output: Array[int]) -> void:
	assert(_indexed_life_revision == store.life_revision, "Shared candidates require the current lifecycle snapshot")
	# Outside positions do not obey the nominal cell's half-diagonal bound.
	if search_radius < 0.0 or center.x < 0.0 or center.y < 0.0 or center.x >= columns * cell_size or center.y >= rows * cell_size:
		shared_fallbacks += 1
		query(center, search_radius, species_filter, store, output)
		return
	var cell_position := Vector2i(floori(center.x / cell_size), floori(center.y / cell_size))
	var key := Vector2i(cell_position.y * columns + cell_position.x, species_filter)
	var batch: CandidateBatch = _candidate_batches.get(key)
	if batch != null and batch.radius == search_radius:
		shared_hits += 1
	else:
		if batch != null:
			shared_candidate_references -= batch.members.size()
			_candidate_batches.erase(key)
		batch = CandidateBatch.new()
		batch.radius = search_radius
		var cell_center: Vector2 = (Vector2(cell_position) + Vector2(0.5, 0.5)) * cell_size
		var covering_radius: float = search_radius + cell_size * sqrt(0.5)
		query(cell_center, covering_radius, species_filter, store, batch.members)
		shared_builds += 1
		if shared_candidate_references + batch.members.size() > MAX_CACHED_CANDIDATES:
			# Capacity exhaustion never turns an incomplete result into "no threat".
			shared_fallbacks += 1
			query(center, search_radius, species_filter, store, output)
			return
		shared_candidate_references += batch.members.size()
		_candidate_batches[key] = batch
	output.clear()
	var radius_squared: float = search_radius * search_radius
	for dense: int in batch.members:
		shared_filter_visits += 1
		if store.alive[dense] != 0 and center.distance_squared_to(store.position_current[dense]) <= radius_squared:
			output.append(dense)

func query_protection_flock(center: Vector2, search_radius: float, previous_anchor: Vector2, has_previous: bool, store: AgentStore, output: FlockSample, commitment_bonus: float = 1.25) -> void:
	# Choose one occupied visible region, never a midpoint between distant groups.
	# Cell identity is only a scoring hint; every new scan checks actual membership.
	output.count = 0
	output.position_sum = Vector2.ZERO
	if search_radius < 0.0:
		return
	assert(_indexed_life_revision == store.life_revision, "Protection samples require the current lifecycle snapshot")
	var previous_cell := Vector2i(floori(previous_anchor.x / cell_size), floori(previous_anchor.y / cell_size))
	var min_x: int = clampi(floori((center.x - search_radius) / cell_size), 0, columns - 1)
	var max_x: int = clampi(floori((center.x + search_radius) / cell_size), 0, columns - 1)
	var min_y: int = clampi(floori((center.y - search_radius) / cell_size), 0, rows - 1)
	var max_y: int = clampi(floori((center.y + search_radius) / cell_size), 0, rows - 1)
	var best_score: float = -INF
	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			_sample_flock_cell(y * columns + x, center, search_radius * search_radius, store, _cell_flock_sample)
			if _cell_flock_sample.count == 0:
				continue
			var centroid: Vector2 = _cell_flock_sample.position_sum / float(_cell_flock_sample.count)
			var score: float = float(_cell_flock_sample.count) / (1.0 + center.distance_to(centroid) / maxf(1.0, search_radius))
			if has_previous and previous_cell == Vector2i(x, y):
				score *= commitment_bonus
			if score > best_score:
				best_score = score
				output.count = _cell_flock_sample.count
				output.position_sum = _cell_flock_sample.position_sum

func _sample_flock_cell(cell: int, center: Vector2, radius_squared: float, store: AgentStore, output: FlockSample) -> void:
	output.count = 0
	output.position_sum = Vector2.ZERO
	if _flock_counts[cell] == 0:
		return
	var far_x: float = maxf(absf(_flock_min[cell].x - center.x), absf(_flock_max[cell].x - center.x))
	var far_y: float = maxf(absf(_flock_min[cell].y - center.y), absf(_flock_max[cell].y - center.y))
	if far_x * far_x + far_y * far_y <= radius_squared:
		output.count = _flock_counts[cell]
		output.position_sum = _flock_sums[cell]
		aggregated_cell_count += 1
		return
	var dense: int = _heads[cell * 3 + SimTypes.Species.SHEEP]
	while dense >= 0:
		candidate_count += 1
		var position: Vector2 = store.position_current[dense]
		if store.alive[dense] != 0 and center.distance_squared_to(position) <= radius_squared:
			output.count += 1
			output.position_sum += position
		dense = _next[dense]

func query(center: Vector2, search_radius: float, species_filter: int, store: AgentStore, output: Array[int]) -> void:
	output.clear()
	if search_radius < 0.0:
		return
	var min_x: int = clampi(floori((center.x - search_radius) / cell_size), 0, columns - 1)
	var max_x: int = clampi(floori((center.x + search_radius) / cell_size), 0, columns - 1)
	var min_y: int = clampi(floori((center.y - search_radius) / cell_size), 0, rows - 1)
	var max_y: int = clampi(floori((center.y + search_radius) / cell_size), 0, rows - 1)
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

func query_flock(center: Vector2, search_radius: float, store: AgentStore, output: FlockSample) -> void:
	# The same published-position/lifecycle snapshot as rebuild is required. The
	# returned sample includes the observer if it is a sheep inside the circle.
	output.count = 0
	output.position_sum = Vector2.ZERO
	if search_radius < 0.0:
		return
	assert(_indexed_life_revision == store.life_revision, "Rebuild the grid after lifecycle changes before querying flock summaries")
	var min_x: int = clampi(floori((center.x - search_radius) / cell_size), 0, columns - 1)
	var max_x: int = clampi(floori((center.x + search_radius) / cell_size), 0, columns - 1)
	var min_y: int = clampi(floori((center.y - search_radius) / cell_size), 0, rows - 1)
	var max_y: int = clampi(floori((center.y + search_radius) / cell_size), 0, rows - 1)
	var radius_squared: float = search_radius * search_radius
	var flock_count: int = 0
	var position_sum := Vector2.ZERO
	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			var cell: int = y * columns + x
			if _flock_counts[cell] == 0:
				continue
			# Use actual member bounds: clamped edge cells may contain positions
			# outside the nominal world rectangle. No member is assumed in range.
			var far_x: float = maxf(absf(_flock_min[cell].x - center.x), absf(_flock_max[cell].x - center.x))
			var far_y: float = maxf(absf(_flock_min[cell].y - center.y), absf(_flock_max[cell].y - center.y))
			if far_x * far_x + far_y * far_y <= radius_squared:
				flock_count += _flock_counts[cell]
				position_sum += _flock_sums[cell]
				aggregated_cell_count += 1
				continue
			var dense: int = _heads[cell * 3 + SimTypes.Species.SHEEP]
			while dense >= 0:
				candidate_count += 1
				var position: Vector2 = store.position_current[dense]
				if store.alive[dense] != 0 and center.distance_squared_to(position) <= radius_squared:
					flock_count += 1
					position_sum += position
				dense = _next[dense]
	output.count = flock_count
	output.position_sum = position_sum

func query_peers(center: Vector2, search_radius: float, species_filter: int, store: AgentStore, output: Array[AgentHandle], max_results: int, exclude: AgentHandle) -> void:
	# This is bounded recipient selection, not a nearest-neighbor query. The
	# first current members in grid traversal order win; no stale memory is used.
	output.clear()
	if max_results <= 0 or search_radius < 0.0:
		return
	assert(species_filter >= SimTypes.Species.SHEEP and species_filter <= SimTypes.Species.DOG, "Peer selection requires a single species")
	assert(_indexed_life_revision == store.life_revision, "Rebuild the grid after lifecycle changes before querying peers")
	var excluded_dense: int = store.resolve(exclude) if exclude != null else -1
	var min_x: int = clampi(floori((center.x - search_radius) / cell_size), 0, columns - 1)
	var max_x: int = clampi(floori((center.x + search_radius) / cell_size), 0, columns - 1)
	var min_y: int = clampi(floori((center.y - search_radius) / cell_size), 0, rows - 1)
	var max_y: int = clampi(floori((center.y + search_radius) / cell_size), 0, rows - 1)
	var radius_squared: float = search_radius * search_radius
	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			var dense: int = _heads[(y * columns + x) * 3 + species_filter]
			while dense >= 0:
				candidate_count += 1
				if dense != excluded_dense and store.alive[dense] != 0 and center.distance_squared_to(store.position_current[dense]) <= radius_squared:
					output.append(store.handle_at(dense))
					if output.size() >= max_results:
						return
				dense = _next[dense]
