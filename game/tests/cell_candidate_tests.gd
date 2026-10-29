extends SceneTree
## A shared broad phase must preserve each observer's exact ordered result.
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
	_test_center_counterexample()
	_test_snapshot_reference()
	_test_rebuild_and_capacity()
	_test_protection_region()
	print("CELL_CANDIDATE_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _compare(grid: SpatialGrid, store: AgentStore, origin: Vector2, radius: float, kind: int) -> void:
	var exact: Array[int] = []
	var shared: Array[int] = []
	grid.query(origin, radius, kind, store, exact)
	grid.query_shared(origin, radius, kind, store, shared)
	_check(exact == shared, "Shared candidates preserve ordered individual circle membership")
	var full_scan: Array[int] = []
	if radius >= 0.0:
		for dense: int in store.count:
			if store.alive[dense] != 0 and (kind < 0 or store.species[dense] == kind) and origin.distance_squared_to(store.position_current[dense]) <= radius * radius:
				full_scan.append(dense)
	shared.sort()
	_check(shared == full_scan, "Shared query membership matches an independent full snapshot scan")

func _test_center_counterexample() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	store.create_agent(SimTypes.Species.WOLF, Vector2(290, 440))
	var visible: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(640, 440))
	grid.rebuild(store)
	var result: Array[int] = []
	grid.query_shared(Vector2(440, 440), 180.0, SimTypes.Species.WOLF, store, result)
	grid.query_shared(Vector2(479, 440), 180.0, SimTypes.Species.WOLF, store, result)
	_check(result == [store.resolve(visible)], "The cell center's nearest wolf must not hide a different member's visible wolf")
	_check(grid.shared_hits == 1 and grid.shared_builds == 1, "Two same-cell scans reuse a complete batch")
	_compare(grid, store, Vector2(479, 440), 161.0, SimTypes.Species.WOLF)
	_compare(grid, store, Vector2(479, 440), -1.0, SimTypes.Species.WOLF)

func _test_snapshot_reference() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 20261029
	for snapshot: int in 40:
		var store := AgentStore.new()
		var grid := SpatialGrid.new()
		for index: int in 160:
			var handle: AgentHandle = store.create_agent(index % 3, Vector2(random.randf_range(-80, 1680), random.randf_range(-80, 1100)))
			if index % 19 == 0:
				store.mark_dead(handle)
		grid.rebuild(store)
		for sample: int in 30:
			var origin := Vector2(random.randf_range(-50, 1650), random.randf_range(-50, 1100))
			var radius: float = random.randf_range(0, 500)
			_compare(grid, store, origin, radius, sample % 4 - 1)
			_compare(grid, store, origin + Vector2(1, 1), radius, sample % 4 - 1)

func _test_rebuild_and_capacity() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	var old: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(500, 500))
	grid.rebuild(store)
	_compare(grid, store, Vector2(500, 500), 180.0, SimTypes.Species.WOLF)
	store.remove_agent(old)
	store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500))
	grid.rebuild(store)
	_check(grid.shared_candidate_references == 0, "Lifecycle rebuild invalidates all private dense references")
	_compare(grid, store, Vector2(500, 500), 180.0, SimTypes.Species.WOLF)
	store.reset()
	for index: int in 400:
		store.create_agent(SimTypes.Species.WOLF, Vector2(800, 500))
	grid.rebuild(store)
	for index: int in 80:
		_compare(grid, store, Vector2((index % 20) * 80 + 40, (index / 20) * 80 + 40), 1800.0, SimTypes.Species.WOLF)
	_check(grid.shared_fallbacks > 0 and grid.shared_candidate_references <= SpatialGrid.MAX_CACHED_CANDIDATES, "Full cache falls back to a complete query without dropping candidates")

func _test_protection_region() -> void:
	var store := AgentStore.new()
	var grid := SpatialGrid.new()
	for index: int in 2:
		store.create_agent(SimTypes.Species.SHEEP, Vector2(400 + index, 500))
	for index: int in 6:
		store.create_agent(SimTypes.Species.SHEEP, Vector2(620 + index, 500))
	store.create_agent(SimTypes.Species.SHEEP, Vector2(700, 500))
	grid.rebuild(store)
	var sample := SpatialGrid.FlockSample.new()
	grid.query_protection_flock(Vector2(510, 500), 180.0, Vector2.ZERO, false, store, sample)
	_check(sample.count == 6 and sample.position_sum.x / sample.count > 620.0, "Protection picks a visible occupied group rather than the empty midpoint")
	grid.query_protection_flock(Vector2(510, 500), 180.0, Vector2(400, 500), true, store, sample, 10.0)
	_check(sample.count == 2, "A configurable commitment bonus keeps a still-visible local group")
	grid.query_protection_flock(Vector2(1300, 900), 180.0, Vector2(400, 500), true, store, sample)
	_check(sample.count == 0, "A previous anchor never grants knowledge of an out-of-range group")
