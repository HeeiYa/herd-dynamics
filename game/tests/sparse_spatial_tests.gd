extends SceneTree
## Sparse storage is checked against both dense indexing and a full-scan oracle.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		if _failures < 12:
			push_error(description)

func _run() -> void:
	var config := SimulationConfig.new()
	config.world_size = Vector2(6400, 4000)
	var store := AgentStore.new()
	var random := RandomNumberGenerator.new()
	random.seed = 791
	for index: int in 600:
		var position := Vector2(random.randf_range(13, 6387), random.randf_range(13, 3987))
		if index < 100:
			position = Vector2(127, 127) + Vector2(random.randf_range(-15, 15), random.randf_range(-15, 15))
		store.create_agent(index % 3, position, 13.0)
	var dense_grid := SpatialGrid.new(config.world_size, config.cell_size, false)
	var sparse_grid := SpatialGrid.new(config.world_size, config.cell_size, true)
	var dense_field := CrowdMotionField.new(config.world_size, config.crowd_cell_size, false)
	var sparse_field := CrowdMotionField.new(config.world_size, config.crowd_cell_size, true)
	for phase: int in 3:
		if phase == 1:
			for index: int in 30:
				store.remove_agent(store.handle_at(0))
			for index: int in 50:
				store.set_held(store.handle_at(index), true)
			for index: int in range(100, 130):
				store.relocate(store.handle_at(index), Vector2(6399, 3999))
		elif phase == 2:
			for index: int in 50:
				store.set_held(store.handle_at(index), false)
				store.relocate(store.handle_at(index), Vector2(129, 129))
		dense_grid.rebuild(store)
		sparse_grid.rebuild(store)
		dense_field.rebuild(store)
		sparse_field.rebuild(store)
		_check(sparse_field.cell_map.storage_count < dense_field.cell_map.storage_count, "Large sparse field allocates only occupied blocks")
		for index: int in range(0, store.count, 3):
			var center: Vector2 = store.position_current[index]
			var radius: float = [0.0, 38.0, 180.0, 320.0][index % 4]
			var expected: Array[int] = []
			var actual: Array[int] = []
			var reference: Array[int] = []
			dense_grid.query(center, radius, -1, store, expected)
			sparse_grid.query(center, radius, -1, store, actual)
			_check(actual == expected, "Sparse indexing preserves full membership and traversal order")
			for candidate: int in store.count:
				if store.alive[candidate] != 0 and store.held[candidate] == 0 and center.distance_squared_to(store.position_current[candidate]) <= radius * radius:
					reference.append(candidate)
			actual.sort()
			_check(actual == reference, "Sparse query matches a full scan without truncation")
			var first := SpatialGrid.FlockSample.new()
			var second := SpatialGrid.FlockSample.new()
			dense_grid.query_flock(center, radius, store, first)
			sparse_grid.query_flock(center, radius, store, second)
			_check(first.count == second.count and first.position_sum.is_equal_approx(second.position_sum), "Flock summaries are representation-independent")
			dense_grid.query_protection_flock(center, radius, center, true, store, first)
			sparse_grid.query_protection_flock(center, radius, center, true, store, second)
			_check(first.count == second.count and first.position_sum.is_equal_approx(second.position_sum), "Protection chooses the same occupied local region")
			if store.held[index] != 0:
				continue
			var dense_mode: bool = dense_field.uses_dense_sample(index, config.neighbor_radius, config.crowd_enter_count, config.crowd_exit_count)
			var sparse_mode: bool = sparse_field.uses_dense_sample(index, config.neighbor_radius, config.crowd_enter_count, config.crowd_exit_count)
			_check(dense_mode == sparse_mode, "Sparse counting preserves density hysteresis including self")
			if dense_mode:
				var dense_steering: Vector2 = dense_field.sample_steering(index, SimTypes.IntentMode.MOVE, config)
				var sparse_steering: Vector2 = sparse_field.sample_steering(index, SimTypes.IntentMode.MOVE, config)
				_check(dense_steering.is_equal_approx(sparse_steering), "Crowd summaries preserve the existing motion approximation")
			else:
				dense_field.query_exact(index, config.neighbor_radius, expected)
				sparse_field.query_exact(index, config.neighbor_radius, actual)
				_check(actual == expected, "Exact motion queries preserve all neighbors and order")
	store.reset()
	sparse_grid.rebuild(store)
	sparse_field.rebuild(store)
	_check(sparse_grid.cell_map.storage_count == 0 and sparse_field.cell_map.storage_count == 0, "Reset releases all occupied block mappings")
	print("SPARSE_SPATIAL_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
