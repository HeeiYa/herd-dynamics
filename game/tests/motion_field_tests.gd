extends SceneTree
## Run the same production motion system with immutable input replays and short
## trajectories. Timing output is evidence, never a machine-dependent assertion.

enum Layout { SPARSE, DENSE, COINCIDENT, CORNER, CROSSING }

class Fixture extends RefCounted:
	var config: SimulationConfig = SimulationConfig.new()
	var store: AgentStore = AgentStore.new()
	var intents: IntentBuffer = IntentBuffer.new()
	var grid: SpatialGrid
	var motion: MotionSystem = MotionSystem.new()

	func _init(field_enabled: bool, field_width: float = 32.0) -> void:
		config.crowd_motion_enabled = field_enabled
		config.crowd_cell_size = field_width
		config.instrument_enabled = false
		grid = SpatialGrid.new(config.world_size, config.cell_size)
		motion.setup(store, grid, intents, config)

	func add_agent(position: Vector2, destination: Vector2, mode: int = SimTypes.IntentMode.MOVE,
			kind: int = SimTypes.Species.SHEEP, initial_velocity: Vector2 = Vector2.ZERO) -> AgentHandle:
		var handle: AgentHandle = store.create_agent(kind, position, config.agent_radius)
		store.velocity_current[store.resolve(handle)] = initial_velocity
		var intent: MotionIntent = MotionIntent.new()
		intent.mode = mode
		intent.destination = destination
		intent.speed = 70.0
		intent.expires_tick = 10000
		intents.write(handle, intent)
		return handle

	func step(tick: int, publish: bool = false) -> void:
		grid.rebuild(store)
		motion.step(tick, config.fixed_dt)
		if publish:
			store.publish_motion()

var _checks: int = 0
var _failures: int = 0
var _benchmark_results: Array[Dictionary] = []
var _trajectory_results: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_sparse_equivalence_and_isolation()
	_test_hysteresis_and_identity()
	_test_dense_bounds_and_coincidence()
	_test_expired_and_stopped_intents()
	_test_species_and_intent_boundaries()
	_test_committed_advance()
	_measure_fixed_input()
	_measure_trajectories()
	var report: Dictionary = {
		"input_contract": "Identical S(n), live identities and valid intents; no BT or interaction in motion-only replay.",
		"timing_contract": "Uninstrumented motion.step only, field build included, shared SpatialGrid build excluded from both backends.",
		"quality_contract": "Soft separation, not collision avoidance; approximate paths need not match exact paths.",
		"engine": Engine.get_version_info(),
		"cpu": OS.get_processor_name(),
		"debug_build": OS.is_debug_build(),
		"fixed_dt": 1.0 / 60.0,
		"benchmarks": _benchmark_results,
		"trajectories": _trajectory_results,
		"checks": _checks,
		"failures": _failures,
	}
	print("MOTION_FIELD_RESULTS " + JSON.stringify(report))
	_write_requested_report(report)
	print("MOTION_FIELD_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_sparse_equivalence_and_isolation() -> void:
	for width: float in [24.0, 32.0]:
		var exact: Fixture = Fixture.new(false, width)
		var hybrid: Fixture = Fixture.new(true, width)
		var random: RandomNumberGenerator = RandomNumberGenerator.new()
		random.seed = 42
		for index: int in range(100):
			var position: Vector2 = Vector2(random.randf_range(20.0, 1580.0), random.randf_range(20.0, 980.0))
			var velocity: Vector2 = Vector2(random.randf_range(-25.0, 25.0), random.randf_range(-25.0, 25.0))
			var destination: Vector2 = Vector2(800.0, 500.0)
			var kind: int = index % 3
			exact.add_agent(position, destination, SimTypes.IntentMode.MOVE, kind, velocity)
			hybrid.add_agent(position, destination, SimTypes.IntentMode.MOVE, kind, velocity)
		var before_positions: PackedVector2Array = hybrid.store.position_current.duplicate()
		var before_velocities: PackedVector2Array = hybrid.store.velocity_current.duplicate()
		exact.step(0)
		hybrid.step(0)
		_check(hybrid.motion.field_agent_count == 0, "Sparse actors retain the complete exact neighbor path")
		_check(hybrid.motion.exact_agent_count == 100, "Every valid sparse intent receives exact steering")
		_check(hybrid.motion.exact_candidate_visits <= 100 * (hybrid.config.crowd_enter_count - 1), "Sparse candidate visits obey the switching threshold")
		for dense: int in range(hybrid.store.count):
			_check(hybrid.store.position_current[dense] == before_positions[dense], "Field leaves current positions unchanged")
			_check(hybrid.store.velocity_current[dense] == before_velocities[dense], "Field leaves current velocities unchanged")
			_check(hybrid.store.velocity_next[dense].distance_to(exact.store.velocity_next[dense]) < 0.001,
				"Sparse fine-grid queries preserve exact steering within floating accumulation tolerance")
		_check(hybrid.motion.exact_neighbor_visits == exact.motion.exact_neighbor_visits, "Sparse exact query retains every contributing neighbor")

func _test_hysteresis_and_identity() -> void:
	var fixture: Fixture = Fixture.new(true)
	var handles: Array[AgentHandle] = []
	for index: int in range(24):
		handles.append(fixture.add_agent(Vector2(500.0, 500.0), Vector2(800.0, 500.0)))
	var field: CrowdMotionField = CrowdMotionField.new(fixture.config.world_size, fixture.config.crowd_cell_size)
	field.rebuild(fixture.store)
	_check(field.uses_dense_sample(0, 38.0, 24, 16), "Entering threshold activates the dense backend")
	for index: int in range(20, 24):
		fixture.store.remove_agent(handles[index])
	field.rebuild(fixture.store)
	_check(field.uses_dense_sample(fixture.store.resolve(handles[0]), 38.0, 24, 16), "Density inside the hysteresis band retains dense mode")
	fixture.store.remove_agent(handles[0])
	var replacement: AgentHandle = fixture.add_agent(Vector2(500.0, 500.0), Vector2(800.0, 500.0))
	field.rebuild(fixture.store)
	_check(replacement.slot == handles[0].slot and replacement.generation != handles[0].generation, "Fixture reuses a slot with a new generation")
	_check(not field.uses_dense_sample(fixture.store.resolve(replacement), 38.0, 24, 16), "A recycled life does not inherit the previous dense mode")
	fixture.store.reset()
	fixture.intents.clear()
	for index: int in range(20):
		fixture.add_agent(Vector2(500.0, 500.0), Vector2(800.0, 500.0))
	field.rebuild(fixture.store)
	_check(not field.uses_dense_sample(0, 38.0, 24, 16), "World reset clears hysteresis for reused slots")
	for index: int in range(4):
		fixture.add_agent(Vector2(500.0, 500.0), Vector2(800.0, 500.0))
	field.rebuild(fixture.store)
	_check(field.uses_dense_sample(0, 38.0, 24, 16), "Fresh dense population re-enters the field")
	for dense: int in range(16, 24):
		fixture.store.mark_dead(fixture.store.handle_at(dense))
	field.rebuild(fixture.store)
	_check(field.built_agent_count == 16, "Logical death is excluded before structural compaction")
	_check(not field.uses_dense_sample(0, 38.0, 24, 16), "Exit threshold returns to exact neighbors")
	var neighbors: Array[int] = []
	field.query_exact(0, 38.0, neighbors)
	_check(neighbors.size() == 16 and field.exact_candidate_visits == 16, "Exact linked candidates exclude dead rows")

func _test_dense_bounds_and_coincidence() -> void:
	for width: float in [24.0, 32.0]:
		for layout: int in [Layout.COINCIDENT, Layout.CORNER, Layout.DENSE, Layout.CROSSING]:
			var fixture: Fixture = _make_fixture(true, 96, layout, width)
			var repeated: Fixture = _make_fixture(true, 96, layout, width)
			fixture.step(0)
			repeated.step(0)
			_check(fixture.motion.field_agent_count > 0, "Crowded layouts exercise aggregate steering")
			_check(fixture.motion.moving_agent_count == fixture.store.count, "Coincidence and walls do not stall the entire initial population")
			_check(fixture.motion.exact_candidate_visits <= fixture.motion.exact_agent_count * (fixture.config.crowd_enter_count - 1),
				"Hybrid traversal bounds exact candidate visits even in crowded layouts")
			var maximum_axis_cells: int = ceili(2.0 * fixture.config.neighbor_radius / width) + 1
			var maximum_visits: int = 2 * fixture.store.count * maximum_axis_cells * maximum_axis_cells
			_check(fixture.motion.field_cell_visits <= maximum_visits, "Density selection and steering have a fixed cell-visit bound")
			for dense: int in range(fixture.store.count):
				_assert_motion_bounds(fixture, dense)
				_check(fixture.store.velocity_next[dense] == repeated.store.velocity_next[dense], "Identical lives and snapshots yield repeatable field tie breaking")

func _test_expired_and_stopped_intents() -> void:
	var fixture: Fixture = _make_fixture(true, 32, Layout.COINCIDENT)
	for dense: int in range(fixture.store.count):
		var intent: MotionIntent = fixture.intents.get_intent(fixture.store.handle_at(dense), 0)
		if dense % 2 == 0:
			intent.mode = SimTypes.IntentMode.STOP
		else:
			intent.expires_tick = 0
	fixture.step(0)
	_check(fixture.motion.field_agent_count == 0 and fixture.motion.exact_agent_count == 0, "Stopped or expired intents do not activate anonymous movement")
	_check(fixture.motion.moving_agent_count == 0, "The field cannot create behavior without a valid movement intent")

func _test_committed_advance() -> void:
	for mode: int in [SimTypes.IntentMode.FLEE, SimTypes.IntentMode.ATTACK]:
		var fixture: Fixture = _make_fixture(true, 64, Layout.COINCIDENT)
		for dense: int in range(fixture.store.count):
			var intent: MotionIntent = fixture.intents.get_intent(fixture.store.handle_at(dense), 0)
			intent.mode = mode
			intent.destination = fixture.store.position_current[dense] + Vector2(200.0, 0.0)
		fixture.step(0)
		for dense: int in range(fixture.store.count):
			_check(fixture.store.velocity_next[dense].x > 0.0, "Anonymous pressure cannot cancel urgent escape or committed attack approach")

func _test_species_and_intent_boundaries() -> void:
	var fixture: Fixture = Fixture.new(true)
	fixture.config.separation_strength = 0.0
	fixture.config.cohesion_weight = 0.0
	fixture.config.alignment_weight = 1.0
	var position: Vector2 = Vector2(800.0, 500.0)
	fixture.add_agent(position, position, SimTypes.IntentMode.MOVE, SimTypes.Species.WOLF)
	fixture.add_agent(position, position, SimTypes.IntentMode.MOVE, SimTypes.Species.SHEEP)
	fixture.add_agent(position, position, SimTypes.IntentMode.MOVE, SimTypes.Species.DOG)
	fixture.add_agent(position, position, SimTypes.IntentMode.GRAZE, SimTypes.Species.SHEEP)
	for index: int in range(28):
		fixture.add_agent(position, position, SimTypes.IntentMode.MOVE, SimTypes.Species.SHEEP, Vector2(0.0, 30.0))
	fixture.step(0)
	_check(fixture.motion.field_agent_count == fixture.store.count, "Mixed-species fixture exercises the anonymous field")
	_check(fixture.store.velocity_next[0].is_zero_approx(), "A wolf does not align with anonymous sheep velocities")
	_check(fixture.store.velocity_next[1].y > 0.0, "A moving sheep aligns with sheep-only velocity aggregates")
	_check(fixture.store.velocity_next[2].is_zero_approx(), "A dog does not inherit flock cohesion or alignment")
	_check(fixture.store.velocity_next[3].is_zero_approx(), "A grazing sheep does not resume travel through alignment")

func _measure_fixed_input() -> void:
	const REPETITIONS: int = 20
	for layout: int in [Layout.SPARSE, Layout.DENSE]:
		var exact: Fixture = _make_fixture(false, 1000, layout)
		var field_32: Fixture = _make_fixture(true, 1000, layout, 32.0)
		var field_24: Fixture = _make_fixture(true, 1000, layout, 24.0)
		var fixtures: Array[Fixture] = [exact, field_32, field_24]
		var timings: Array[PackedFloat64Array] = [PackedFloat64Array(), PackedFloat64Array(), PackedFloat64Array()]
		for fixture: Fixture in fixtures:
			fixture.grid.rebuild(fixture.store)
			for warmup: int in range(3):
				fixture.motion.step(0, fixture.config.fixed_dt)
		# Rotate execution order, with no publication, so every timed call sees the
		# same input and the same number of live bodies and actionable intents.
		for repetition: int in range(REPETITIONS):
			for order: int in range(fixtures.size()):
				var variant: int = (repetition + order) % fixtures.size()
				var fixture: Fixture = fixtures[variant]
				var started_usec: int = Time.get_ticks_usec()
				fixture.motion.step(0, fixture.config.fixed_dt)
				var elapsed_usec: int = Time.get_ticks_usec() - started_usec
				var samples: PackedFloat64Array = timings[variant]
				samples.append(float(elapsed_usec))
				timings[variant] = samples
		for variant: int in range(fixtures.size()):
			var fixture: Fixture = fixtures[variant]
			var samples: PackedFloat64Array = timings[variant]
			samples.sort()
			var elapsed_sum: float = 0.0
			for elapsed: float in samples:
				elapsed_sum += elapsed
			# One separately instrumented replay supplies substage times. It is not
			# mixed with the uninstrumented mean/P95 above.
			fixture.config.instrument_enabled = true
			fixture.motion.step(0, fixture.config.fixed_dt)
			var record: Dictionary = _motion_record(fixture)
			record["layout"] = Layout.keys()[layout]
			record["agent_count"] = fixture.store.count
			record["valid_intent_count"] = fixture.store.count
			record["species_counts"] = [1000, 0, 0]
			record["world_size"] = [fixture.config.world_size.x, fixture.config.world_size.y]
			record["placement"] = "40 columns, 39px spacing" if layout == Layout.SPARSE else "40 columns, 10px spacing"
			record["repetitions"] = REPETITIONS
			record["mean_motion_usec"] = elapsed_sum / samples.size()
			record["p95_motion_usec"] = samples[ceili(samples.size() * 0.95) - 1]
			record["samples_usec"] = Array(samples)
			record["next_velocity_rmse_vs_exact"] = _velocity_rmse(exact, fixture)
			_benchmark_results.append(record)

func _measure_trajectories() -> void:
	const TRAJECTORY_TICKS: int = 120
	for layout: int in [Layout.DENSE, Layout.COINCIDENT, Layout.CORNER, Layout.CROSSING]:
		var exact: Fixture = _make_fixture(false, 64, layout)
		var field: Fixture = _make_fixture(true, 64, layout)
		var initial_positions: PackedVector2Array = exact.store.position_current.duplicate()
		var fixtures: Array[Fixture] = [exact, field]
		var maximum_stuck_ticks: PackedInt32Array = PackedInt32Array([0, 0])
		var stuck_streaks: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
		for variant: int in range(fixtures.size()):
			var streaks: PackedInt32Array = PackedInt32Array()
			streaks.resize(fixtures[variant].store.count)
			stuck_streaks[variant] = streaks
		for tick: int in range(TRAJECTORY_TICKS):
			for variant: int in range(fixtures.size()):
				var fixture: Fixture = fixtures[variant]
				fixture.step(tick)
				var streaks: PackedInt32Array = stuck_streaks[variant]
				for dense: int in range(fixture.store.count):
					var movement: float = fixture.store.position_current[dense].distance_to(fixture.store.position_next[dense])
					streaks[dense] = streaks[dense] + 1 if movement < 0.01 else 0
					maximum_stuck_ticks[variant] = maxi(maximum_stuck_ticks[variant], streaks[dense])
					_assert_motion_bounds(fixture, dense)
				stuck_streaks[variant] = streaks
				fixture.store.publish_motion()
		for variant: int in range(fixtures.size()):
			var fixture: Fixture = fixtures[variant]
			var net_displacement_sum: float = 0.0
			var net_moved_count: int = 0
			var limited_progress: Array[Dictionary] = []
			for dense: int in range(fixture.store.count):
				var net_displacement: float = initial_positions[dense].distance_to(fixture.store.position_current[dense])
				net_displacement_sum += net_displacement
				if net_displacement >= 1.0:
					net_moved_count += 1
				elif limited_progress.size() < 16:
					var endpoint: Vector2 = fixture.store.position_current[dense]
					limited_progress.append({"slot": fixture.store.handle_at(dense).slot,
						"endpoint": [endpoint.x, endpoint.y], "net_displacement_px": net_displacement})
			var record: Dictionary = _motion_record(fixture)
			record["layout"] = Layout.keys()[layout]
			record["ticks"] = TRAJECTORY_TICKS
			record["agent_count"] = fixture.store.count
			record["mean_net_displacement_px"] = net_displacement_sum / fixture.store.count
			record["net_moved_at_least_1px_count"] = net_moved_count
			record["limited_progress_examples"] = limited_progress
			record["longest_stuck_ticks_below_0_01px_per_step"] = maximum_stuck_ticks[variant]
			record["overlapping_pair_count"] = _overlapping_pairs(fixture)
			record["total_pairs"] = fixture.store.count * (fixture.store.count - 1) / 2
			record["endpoint_rmse_vs_exact_px"] = _position_rmse(exact, fixture)
			_trajectory_results.append(record)
			if fixture.config.crowd_motion_enabled and (layout == Layout.COINCIDENT or layout == Layout.CORNER):
				_check(net_moved_count == fixture.store.count, "Coincident populations make real progress over the trajectory window")

func _make_fixture(field_enabled: bool, count: int, layout: int, width: float = 32.0) -> Fixture:
	var fixture: Fixture = Fixture.new(field_enabled, width)
	var layout_columns: int = 40 if count > 100 else 12
	for index: int in range(count):
		var position: Vector2
		var column: int = index % layout_columns
		var row: int = floori(float(index) / layout_columns)
		if layout == Layout.SPARSE:
			position = Vector2(20.0 + column * 39.0, 20.0 + row * 39.0)
		elif layout == Layout.COINCIDENT:
			position = Vector2(800.0, 500.0)
		elif layout == Layout.CORNER:
			position = Vector2.ONE * fixture.config.agent_radius
		else:
			position = Vector2(600.0 + column * 10.0, 400.0 + row * 10.0)
		var direction: Vector2 = Vector2.RIGHT
		if layout == Layout.CROSSING and index % 2 == 0:
			direction = Vector2.LEFT
		var mode: int = SimTypes.IntentMode.MOVE
		if layout == Layout.COINCIDENT or layout == Layout.CORNER:
			mode = SimTypes.IntentMode.GRAZE
		var destination: Vector2 = position + direction * 400.0
		destination = destination.clamp(Vector2.ONE * fixture.config.agent_radius,
			fixture.config.world_size - Vector2.ONE * fixture.config.agent_radius)
		fixture.add_agent(position, destination, mode)
	return fixture

func _assert_motion_bounds(fixture: Fixture, dense: int) -> void:
	var position: Vector2 = fixture.store.position_next[dense]
	var velocity: Vector2 = fixture.store.velocity_next[dense]
	var body_radius: float = fixture.store.radius[dense]
	_check(position.is_finite() and velocity.is_finite(), "Field motion remains finite")
	_check(velocity.length() <= 70.001, "Field respects the configured intent speed limit")
	_check(position.x >= body_radius and position.y >= body_radius and
		position.x <= fixture.config.world_size.x - body_radius and position.y <= fixture.config.world_size.y - body_radius,
		"Field stays inside body-aware world bounds")

func _motion_record(fixture: Fixture) -> Dictionary:
	return {
		"crowd_motion_enabled": fixture.config.crowd_motion_enabled,
		"crowd_cell_size": fixture.config.crowd_cell_size,
		"crowd_enter_count": fixture.config.crowd_enter_count,
		"crowd_exit_count": fixture.config.crowd_exit_count,
		"field_build_usec": fixture.motion.field_build_usec,
		"field_sample_usec": fixture.motion.field_sample_usec,
		"exact_sample_usec": fixture.motion.exact_sample_usec,
		"field_agent_count": fixture.motion.field_agent_count,
		"exact_agent_count": fixture.motion.exact_agent_count,
		"field_cell_visits": fixture.motion.field_cell_visits,
		"exact_candidate_visits": fixture.motion.exact_candidate_visits,
		"exact_neighbor_visits": fixture.motion.exact_neighbor_visits,
		"aggregate_agent_contributions": fixture.motion.aggregate_agent_contributions,
		"moving_agent_count": fixture.motion.moving_agent_count,
		"displacement_sum": fixture.motion.displacement_sum,
	}

func _velocity_rmse(reference: Fixture, candidate: Fixture) -> float:
	var squared_error: float = 0.0
	for dense: int in range(reference.store.count):
		squared_error += reference.store.velocity_next[dense].distance_squared_to(candidate.store.velocity_next[dense])
	return sqrt(squared_error / reference.store.count)

func _position_rmse(reference: Fixture, candidate: Fixture) -> float:
	var squared_error: float = 0.0
	for dense: int in range(reference.store.count):
		squared_error += reference.store.position_current[dense].distance_squared_to(candidate.store.position_current[dense])
	return sqrt(squared_error / reference.store.count)

func _overlapping_pairs(fixture: Fixture) -> int:
	# Small trajectory fixtures only; quality diagnostics are outside timing loops.
	var pairs: int = 0
	for first: int in range(fixture.store.count):
		for second: int in range(first + 1, fixture.store.count):
			var distance_squared: float = fixture.store.position_current[first].distance_squared_to(fixture.store.position_current[second])
			var contact_distance: float = fixture.store.radius[first] + fixture.store.radius[second]
			if distance_squared < contact_distance * contact_distance:
				pairs += 1
	return pairs

func _write_requested_report(report: Dictionary) -> void:
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--motion-results="):
			continue
		var output_path: String = argument.trim_prefix("--motion-results=")
		var output: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
		if output == null:
			push_error("Cannot write motion results to %s: %s" % [output_path, error_string(FileAccess.get_open_error())])
			_failures += 1
			return
		output.store_string(JSON.stringify(report, "  "))
