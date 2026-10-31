extends SceneTree
## Real-device differential tests. Every comparison replays exactly the same
## S(n), identities and intents through the production CPU and GPU backends.
var _checks: int = 0
var _failures: int = 0
var _maximum_velocity_error: float = 0.0
var _maximum_position_error: float = 0.0
var _results: Array[Dictionary] = []
var _layout: String = ""
var _worst: Dictionary = {}

class Fixture extends RefCounted:
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	var config := SimulationConfig.new()
	var gpu_config := SimulationConfig.new()
	var scalar_config := SimulationConfig.new()
	var cpu := MotionSystem.new()
	var gpu := MotionSystem.new()
	var scalar_gpu := MotionSystem.new()
	var grid: SpatialGrid

	func _init(sparse: bool = false) -> void:
		config.spatial_backend = SimulationConfig.SpatialBackend.DENSE
		gpu_config.spatial_backend = SimulationConfig.SpatialBackend.SPARSE if sparse else SimulationConfig.SpatialBackend.DENSE
		scalar_config.spatial_backend = gpu_config.spatial_backend
		if sparse:
			config.world_size = Vector2(6400, 4000)
			gpu_config.world_size = config.world_size
			scalar_config.world_size = config.world_size
		grid = SpatialGrid.new(config.world_size, config.cell_size)
		gpu_config.motion_backend = SimulationConfig.MotionBackend.GPU
		scalar_config.motion_backend = SimulationConfig.MotionBackend.GPU
		scalar_config.gpu_bulk_upload = false
		cpu.setup(store, grid, intents, config)
		gpu.setup(store, grid, intents, gpu_config)
		scalar_gpu.setup(store, grid, intents, scalar_config)

	func close() -> void:
		gpu.close()
		scalar_gpu.close()

	func populate(count: int, layout: String) -> void:
		var random := RandomNumberGenerator.new()
		random.seed = 42
		for index: int in count:
			var position := Vector2(random.randf_range(13.0, 1587.0), random.randf_range(13.0, 987.0))
			if layout == "dense":
				position = Vector2(800.0, 500.0) + (position - Vector2(800.0, 500.0)) * 0.12
			elif layout == "corner":
				position = Vector2(13.0, 13.0)
			elif layout == "coincident":
				position = Vector2(800.0, 500.0)
			var handle: AgentHandle = store.create_agent(index % 3, position, config.agent_radius)
			var dense: int = store.resolve(handle)
			store.velocity_current[dense] = Vector2(random.randf_range(-20.0, 20.0), random.randf_range(-20.0, 20.0))
			if index % 17 == 0:
				continue
			var intent := MotionIntent.new()
			intent.mode = index % 6
			intent.destination = Vector2(random.randf_range(0.0, 1600.0), random.randf_range(0.0, 1000.0))
			intent.speed = 0.0 if intent.mode == SimTypes.IntentMode.GRAZE else 70.0
			intent.behavior = SimTypes.Behavior.RETREAT if index % 7 == 0 else SimTypes.Behavior.CHASE
			intent.expires_tick = 100
			intents.write(handle, intent)

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		if _failures < 15:
			push_error(message)

func _compare(fixture: Fixture, tick: int) -> void:
	var before: PackedVector2Array = fixture.store.position_current.duplicate()
	var facing: PackedVector2Array = fixture.store.facing.duplicate()
	fixture.cpu.step(tick, fixture.config.fixed_dt)
	var expected_positions: PackedVector2Array = fixture.store.position_next.duplicate()
	var expected_velocities: PackedVector2Array = fixture.store.velocity_next.duplicate()
	var expected_facing: PackedVector2Array = fixture.store.facing.duplicate()
	fixture.store.facing = facing.duplicate()
	fixture.scalar_gpu.step(tick, fixture.config.fixed_dt)
	_check(fixture.scalar_gpu.backend_status == "gpu", "Scalar baseline requires actual GPU execution")
	var scalar_positions: PackedVector2Array = fixture.store.position_next.duplicate()
	var scalar_velocities: PackedVector2Array = fixture.store.velocity_next.duplicate()
	var scalar_facing: PackedVector2Array = fixture.store.facing.duplicate()
	fixture.store.facing = facing
	fixture.gpu.step(tick, fixture.config.fixed_dt)
	_check(fixture.gpu.backend_status == "gpu", "Test requires actual GPU execution, never a CPU fallback")
	_check(fixture.store.position_current == before, "GPU leaves S(n) unchanged")
	_check(fixture.cpu.field_agent_count == fixture.gpu.field_agent_count, "Density hysteresis chooses the same bodies")
	_check(fixture.cpu.exact_agent_count == fixture.gpu.exact_agent_count, "Same complete exact queries")
	_check(fixture.cpu.exact_neighbor_visits == fixture.gpu.exact_neighbor_visits, "Same exact neighbor membership")
	for dense: int in fixture.store.count:
		var position_error: float = fixture.store.position_next[dense].distance_to(expected_positions[dense])
		var velocity_error: float = fixture.store.velocity_next[dense].distance_to(expected_velocities[dense])
		if velocity_error > _maximum_velocity_error:
			_worst = {"layout": _layout, "tick": tick, "dense": dense, "position": str(before[dense]), "expected_velocity": str(expected_velocities[dense]), "gpu_velocity": str(fixture.store.velocity_next[dense])}
		_maximum_position_error = maxf(_maximum_position_error, position_error)
		_maximum_velocity_error = maxf(_maximum_velocity_error, velocity_error)
		_check(fixture.store.position_next[dense].is_finite() and position_error < 0.001, "Position differential at row %d: %f" % [dense, position_error])
		_check(fixture.store.velocity_next[dense].is_finite() and velocity_error < 0.003, "Velocity differential at row %d: %f" % [dense, velocity_error])
		_check(fixture.store.facing[dense].distance_to(expected_facing[dense]) < 0.001, "Facing differential")
		_check(fixture.store.position_next[dense] == scalar_positions[dense], "Both uploads produce identical positions")
		_check(fixture.store.velocity_next[dense] == scalar_velocities[dense], "Both uploads produce identical velocities")
		_check(fixture.store.facing[dense] == scalar_facing[dense], "Both uploads produce identical facing")

func _run() -> void:
	for layout: String in ["sparse", "dense", "coincident", "corner"]:
		_layout = layout
		var fixture := Fixture.new()
		fixture.populate(1000, layout)
		for tick: int in 20:
			_compare(fixture, tick)
			fixture.store.publish_motion()
		# Held, expired, swap deletion, stale intent and slot reuse share this path.
		var held: AgentHandle = fixture.store.handle_at(4)
		fixture.store.set_held(held, true)
		_compare(fixture, 21)
		fixture.store.set_held(held, false)
		var removed: AgentHandle = fixture.store.handle_at(9)
		fixture.store.remove_agent(removed)
		fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(900, 500), 13.0)
		_compare(fixture, 22)
		_compare(fixture, 100)
		fixture.store.reset()
		fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100), 13.0)
		_compare(fixture, 0)
		fixture.store.reset()
		_compare(fixture, 0)
		fixture.close()
		await process_frame
	# Sparse exact coincidence across the 360-slot hash reduction boundary.
	var overlap := Fixture.new()
	overlap.populate(400, "sparse")
	for dense: int in overlap.store.count:
		overlap.store.set_held(overlap.store.handle_at(dense), true)
	for dense: int in [2, 367]:
		overlap.store.set_held(overlap.store.handle_at(dense), false)
		overlap.store.relocate(overlap.store.handle_at(dense), Vector2(500, 500))
	_compare(overlap, 0)
	overlap.close()
	_test_capacity_and_cache()
	_test_sparse_projection()
	for population: int in [1000, 3000, 5000]:
		for layout: String in ["sparse", "dense"]:
			var fixture := Fixture.new()
			fixture.populate(population, layout)
			_measure(fixture, population, layout)
			fixture.close()
			await process_frame
	var report: Dictionary = {"checks": _checks, "failures": _failures,
		"worst_differential": _worst,
		"maximum_position_error": _maximum_position_error, "maximum_velocity_error": _maximum_velocity_error,
		"engine": Engine.get_version_info(), "gpu": RenderingServer.get_video_adapter_name(),
		"debug_build": OS.is_debug_build(), "benchmarks": _results,
		"scope": "Identical-input motion replay. CPU field build and GPU transfers included; BT, interaction and rendering excluded. Not full-scene FPS."}
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--gpu-results="):
			var file: FileAccess = FileAccess.open(argument.trim_prefix("--gpu-results="), FileAccess.WRITE)
			assert(file != null)
			file.store_string(JSON.stringify(report, "  "))
	print("GPU_MOTION_TESTS " + JSON.stringify(report))
	quit(0 if _failures == 0 else 1)

func _test_capacity_and_cache() -> void:
	_layout = "capacity_and_cache"
	var fixture := Fixture.new()
	fixture.populate(8, "corner")
	_compare(fixture, 0)
	fixture.gpu.reset_backend_metrics()
	_compare(fixture, 1)
	_check(fixture.gpu.backend_metrics()["identity_cache_rebuilds"] == 0, "Steady lives reuse identity directions")
	# Grow after device allocation, including fractional radii near all four walls.
	fixture.populate(140, "corner")
	for dense: int in fixture.store.count:
		var radius: float = 13.2
		fixture.store.radius[dense] = radius
		var soft_wall: float = float(fixture.store.radius[dense]) * 2.0
		var position := Vector2(soft_wall, soft_wall)
		if dense % 2 == 0:
			position.x = fixture.config.world_size.x - soft_wall
		if dense % 4 < 2:
			position.y = fixture.config.world_size.y - soft_wall
		fixture.store.relocate(fixture.store.handle_at(dense), position)
	_compare(fixture, 2)
	_check(fixture.gpu.backend_metrics()["identity_cache_rebuilds"] == 1, "Capacity and lifecycle changes refresh once")
	fixture.store.mark_dead(fixture.store.handle_at(2))
	_compare(fixture, 3)
	fixture.gpu_config.gpu_bulk_upload = false
	_compare(fixture, 4)
	fixture.gpu_config.gpu_bulk_upload = true
	_compare(fixture, 5)
	fixture.close()

func _measure(fixture: Fixture, population: int, layout: String) -> void:
	for warmup: int in 4:
		fixture.cpu.step(0, fixture.config.fixed_dt)
		fixture.gpu.step(0, fixture.config.fixed_dt)
		fixture.scalar_gpu.step(0, fixture.config.fixed_dt)
	fixture.gpu.reset_backend_metrics()
	fixture.scalar_gpu.reset_backend_metrics()
	_check(fixture.gpu.backend_status == "gpu", "Timing requires GPU, not a fallback")
	var original_facing: PackedVector2Array = fixture.store.facing.duplicate()
	var cpu_us: int = 0
	var gpu_us: int = 0
	var scalar_us: int = 0
	const REPETITIONS: int = 20
	for repetition: int in REPETITIONS:
		# Interleave both orders to avoid always charging one side first.
		for offset: int in 3:
			var backend: int = (repetition + offset) % 3
			fixture.store.facing = original_facing.duplicate()
			var started: int = Time.get_ticks_usec()
			if backend == 0:
				fixture.gpu.step(0, fixture.config.fixed_dt)
				gpu_us += Time.get_ticks_usec() - started
			elif backend == 1:
				fixture.scalar_gpu.step(0, fixture.config.fixed_dt)
				scalar_us += Time.get_ticks_usec() - started
			else:
				fixture.cpu.step(0, fixture.config.fixed_dt)
				cpu_us += Time.get_ticks_usec() - started
	_results.append({"population": population, "layout": layout, "repetitions": REPETITIONS,
		"cpu_mean_us": float(cpu_us) / REPETITIONS, "gpu_chain_mean_us": float(gpu_us) / REPETITIONS,
		"scalar_gpu_chain_mean_us": float(scalar_us) / REPETITIONS,
		"gpu_breakdown": fixture.gpu.backend_metrics(), "scalar_breakdown": fixture.scalar_gpu.backend_metrics()})

func _test_sparse_projection() -> void:
	_layout = "occupied-block projection and growth"
	var fixture := Fixture.new(true)
	fixture.populate(600, "dense")
	for dense: int in fixture.store.count:
		fixture.store.set_held(fixture.store.handle_at(dense), true)
	_compare(fixture, 0)
	for dense: int in fixture.store.count:
		fixture.store.set_held(fixture.store.handle_at(dense), false)
	_compare(fixture, 0)
	# The same actor capacity now occupies many more blocks: GPU allocation must
	# track cell/lookup capacity independently of the unchanged actor count.
	for dense: int in fixture.store.count:
		var position := Vector2(13 + (dense % 60) * 103, 13 + (dense / 60) * 390)
		fixture.store.relocate(fixture.store.handle_at(dense), position)
	_compare(fixture, 1)
	for dense: int in fixture.store.count:
		fixture.store.relocate(fixture.store.handle_at(dense), Vector2(6387, 3987))
	_compare(fixture, 2)
	fixture.close()
