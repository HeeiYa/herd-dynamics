extends SceneTree
## Exact local membership checks for cell summaries and bounded communication peers.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_snapshot_reference()
	_test_boundaries_and_empty()
	_test_clamped_edge_cells()
	_test_dense_cells()
	_test_lifecycle_rebuild()
	_test_bounded_peers()
	_test_peer_identity_and_geometry()
	print("FLOCK_QUERY_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _reference_flock(store: AgentStore, center: Vector2, radius: float) -> SpatialGrid.FlockSample:
	var reference := SpatialGrid.FlockSample.new()
	if radius < 0.0:
		return reference
	var radius_squared: float = radius * radius
	for dense: int in store.count:
		if store.alive[dense] == 0 or store.species[dense] != SimTypes.Species.SHEEP:
			continue
		var position: Vector2 = store.position_current[dense]
		if center.distance_squared_to(position) <= radius_squared:
			reference.count += 1
			reference.position_sum += position
	return reference

func _compare_flock(grid: SpatialGrid, store: AgentStore, center: Vector2, radius: float) -> void:
	var actual := SpatialGrid.FlockSample.new()
	grid.query_flock(center, radius, store, actual)
	var reference: SpatialGrid.FlockSample = _reference_flock(store, center, radius)
	_check(actual.count == reference.count, "Cell summaries preserve exact live sheep membership")
	# Grouped sums change float accumulation order, not which sheep contribute.
	# The tolerance bounds the mean error to 0.001 pixels per nonempty result.
	var sum_tolerance: float = 0.001 * maxi(1, reference.count)
	_check(actual.position_sum.distance_to(reference.position_sum) <= sum_tolerance, "Grouped positions match the full-scan sum within float tolerance")

func _test_snapshot_reference() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 20261029
	for snapshot: int in 100:
		var store := AgentStore.new()
		var grid := SpatialGrid.new(Vector2(1600, 1000), 80.0)
		for index: int in random.randi_range(0, 240):
			var kind: int = random.randi_range(0, 2)
			var position := Vector2(random.randf_range(-100, 1800), random.randf_range(-100, 1200))
			var handle: AgentHandle = store.create_agent(kind, position)
			if index % 17 == 0:
				store.mark_dead(handle)
		grid.rebuild(store)
		for query: int in 12:
			var center := Vector2(random.randf_range(-150, 1850), random.randf_range(-150, 1250))
			var radius: float = random.randf_range(0, 700)
			_compare_flock(grid, store, center, radius)

func _test_boundaries_and_empty() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	grid.rebuild(store)
	_compare_flock(grid, store, Vector2.ZERO, 0.0)
	store.create_agent(SimTypes.Species.SHEEP, Vector2(80, 80))
	store.create_agent(SimTypes.Species.SHEEP, Vector2(160, 80))
	store.create_agent(SimTypes.Species.SHEEP, Vector2(0, 80))
	store.create_agent(SimTypes.Species.SHEEP, Vector2(160.01, 80))
	store.create_agent(SimTypes.Species.WOLF, Vector2(80, 80))
	store.create_agent(SimTypes.Species.DOG, Vector2(80, 80))
	grid.rebuild(store)
	_compare_flock(grid, store, Vector2(80, 80), 80.0)
	_compare_flock(grid, store, Vector2(80, 80), 0.0)
	var sample := SpatialGrid.FlockSample.new()
	grid.query_flock(Vector2(80, 80), 80.0, store, sample)
	_check(sample.count == 3, "The observer and sheep exactly on the radius are included; other species are excluded")
	grid.query_flock(Vector2(80, 80), -1.0, store, sample)
	_check(sample.count == 0 and sample.position_sum == Vector2.ZERO, "Negative radius clears a reused output without accepting candidates")
	grid.query_flock(Vector2(1000, 900), 1.0, store, sample)
	_check(sample.count == 0 and sample.position_sum == Vector2.ZERO, "An empty query clears the previous aggregate")

func _test_clamped_edge_cells() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	for position: Vector2 in [Vector2(-200, -200), Vector2(-30, 40), Vector2(0, 40), Vector2(60, 60), Vector2(1590, 990), Vector2(1700, 900), Vector2(2000, 1500)]:
		store.create_agent(SimTypes.Species.SHEEP, position)
	grid.rebuild(store)
	_compare_flock(grid, store, Vector2(20, 20), 70.0)
	_compare_flock(grid, store, Vector2(-200, -200), 0.0)
	_compare_flock(grid, store, Vector2(-30, 40), 30.0)
	_compare_flock(grid, store, Vector2(2000, 1500), 1.0)
	_compare_flock(grid, store, Vector2(1600, 1000), 120.0)
	_compare_flock(grid, store, Vector2(1700, 900), 600.0)
	var sample := SpatialGrid.FlockSample.new()
	grid.query_flock(Vector2(-200, -200), 0.0, store, sample)
	_check(sample.count == 1 and sample.position_sum == Vector2(-200, -200), "Actual edge-cell bounds preserve out-of-world geometry rather than the clamped nominal rectangle")

func _test_dense_cells() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	for index: int in 2000:
		store.create_agent(SimTypes.Species.SHEEP, Vector2(110 + index % 20, 110 + index % 17))
	grid.rebuild(store)
	var sample := SpatialGrid.FlockSample.new()
	grid.query_flock(Vector2(120, 120), 30.0, store, sample)
	_check(sample.count == 2000 and grid.candidate_count == 0 and grid.aggregated_cell_count == 1, "A dense enclosed cell merges all sheep without per-member candidate visits")
	_compare_flock(grid, store, Vector2(120, 120), 30.0)
	store.reset()
	for index: int in 2000:
		var position := Vector2(90, 80) if index % 2 == 0 else Vector2(130, 80)
		store.create_agent(SimTypes.Species.SHEEP, position)
	grid.rebuild(store)
	grid.query_flock(Vector2(80, 80), 20.0, store, sample)
	_check(sample.count == 1000 and grid.candidate_count == 2000 and grid.aggregated_cell_count == 0, "A dense boundary cell checks every member instead of truncating the exact query")
	_compare_flock(grid, store, Vector2(80, 80), 20.0)

func _test_lifecycle_rebuild() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	var removed: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	store.create_agent(SimTypes.Species.SHEEP, Vector2(120, 100))
	grid.rebuild(store)
	_compare_flock(grid, store, Vector2(100, 100), 180.0)
	store.mark_dead(removed)
	grid.rebuild(store)
	_compare_flock(grid, store, Vector2(100, 100), 180.0)
	store.remove_agent(removed)
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	grid.rebuild(store)
	var sample := SpatialGrid.FlockSample.new()
	grid.query_flock(Vector2(100, 100), 180.0, store, sample)
	_check(replacement.slot == removed.slot and sample.count == 1 and sample.position_sum == Vector2(120, 100), "Rebuild discards dead and reused sheep identities after dense swap removal")
	store.reset()
	grid.rebuild(store)
	grid.query_flock(Vector2(100, 100), 180.0, store, sample)
	_check(sample.count == 0 and grid.candidate_count == 0 and grid.aggregated_cell_count == 0, "World reset and rebuild clear aggregate data and diagnostic counters")

func _test_bounded_peers() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	var sheep: Array[AgentHandle] = []
	for index: int in 100:
		sheep.append(store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100)))
	grid.rebuild(store)
	var peers: Array[AgentHandle] = []
	var self_alias := AgentHandle.new(sheep[-1].slot, sheep[-1].generation, sheep[-1].world_epoch)
	grid.query_peers(Vector2(100, 100), 5.0, SimTypes.Species.SHEEP, store, peers, 4, self_alias)
	_check(peers.size() == 4 and grid.candidate_count == 5, "Peer query stops after four matches and excludes an equal-value self handle")
	for index: int in peers.size():
		_check(peers[index].same_life(sheep[98 - index]), "Bounded peers retain current grid traversal order as full life handles")
	var candidates_before: int = grid.candidate_count
	grid.query_peers(Vector2(100, 100), 5.0, SimTypes.Species.SHEEP, store, peers, 0, null)
	_check(peers.is_empty() and grid.candidate_count == candidates_before, "Zero peer limit clears output and does no candidate work")
	grid.query_peers(Vector2(100, 100), 5.0, SimTypes.Species.SHEEP, store, peers, -1, null)
	_check(peers.is_empty() and grid.candidate_count == candidates_before, "Negative peer limit is empty without walking the grid")
	grid.query_peers(Vector2(100, 100), -1.0, SimTypes.Species.SHEEP, store, peers, 4, null)
	_check(peers.is_empty() and grid.candidate_count == candidates_before, "Negative peer radius cannot select a recipient")

func _test_peer_identity_and_geometry() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	var old: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	store.remove_agent(old)
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	var boundary: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(105, 100))
	store.create_agent(SimTypes.Species.SHEEP, Vector2(105.01, 100))
	var dead: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	store.mark_dead(dead)
	store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	store.create_agent(SimTypes.Species.DOG, Vector2(100, 100))
	grid.rebuild(store)
	var peers: Array[AgentHandle] = []
	grid.query_peers(Vector2(100, 100), 5.0, SimTypes.Species.SHEEP, store, peers, 8, old)
	_check(peers.size() == 2 and peers.has(replacement) and peers.has(boundary), "Stale self identity does not exclude its replacement; peers obey exact radius, species and liveness")
	grid.query_peers(Vector2(100, 100), 0.0, SimTypes.Species.SHEEP, store, peers, 8, replacement)
	_check(peers.is_empty(), "Zero-radius peer lookup excludes the observer and all noncoincident positions")
	var outside: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(-200, -200))
	grid.rebuild(store)
	grid.query_peers(Vector2(-200, -200), 0.0, SimTypes.Species.SHEEP, store, peers, 4, null)
	_check(peers.size() == 1 and peers[0].same_life(outside), "Peer geometry remains exact for an out-of-world center and clamped edge cell")
