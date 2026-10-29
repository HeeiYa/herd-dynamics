class_name BenchmarkSession
extends Node
## Explicit CPU, rendered-scene and response measurements share the production kernel.
var _options: Dictionary[String, String] = {}

func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var pair: PackedStringArray = argument.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2:
			_options[pair[0]] = pair[1]
	call_deferred("_run")

func _run() -> void:
	if _options.get("benchmark", "") == "threat-cohort":
		var cohort_benchmark := preload("res://scripts/diagnostics/threat_cohort_benchmark.gd").new()
		var exit_code: int = await cohort_benchmark.run(self, _options)
		get_tree().quit(exit_code)
		return
	if _options.get("benchmark", "") == "threat":
		await _run_threat_scan()
		return
	if _options.get("rendered", "0") == "1" or _options.get("benchmark", "cpu") == "frames":
		await _run_rendered()
		return
	var config := SimulationConfig.new()
	config.instrument_enabled = _options.get("instrument", "1") == "1"
	config.compact_flock_knowledge = _options.get("compact-flock", "1") == "1"
	_configure_backends(config)
	config.cell_size = float(_options.get("cell-size", "80"))
	config.ai_budget_usec = int(_options.get("ai-budget-usec", str(config.ai_budget_usec)))
	var scenario := ScenarioConfig.new()
	scenario.random_seed = int(_options.get("seed", "42"))
	scenario.layout = int(_options.get("layout", "0")) as ScenarioConfig.Layout
	scenario.sheep_count = int(_options.get("sheep", str(scenario.sheep_count)))
	scenario.wolf_count = int(_options.get("wolves", str(scenario.wolf_count)))
	scenario.dog_count = int(_options.get("dogs", str(scenario.dog_count)))
	var warmup: int = int(_options.get("warmup", "600"))
	var samples: int = int(_options.get("samples", "3600"))
	var output: String = _options.get("output", "user://benchmark")
	var world := SimulationWorld.new()
	get_tree().root.add_child(world)
	world.setup(config, scenario)
	await get_tree().process_frame
	for step: int in range(warmup):
		world.ai.begin_frame()
		world.step()
	world.probes.reset_window()
	var timings: Array[float] = []
	var rows: Array[PackedStringArray] = []
	var started: int = Time.get_ticks_usec()
	for sample: int in range(samples):
		world.ai.begin_frame()
		var step_start: int = Time.get_ticks_usec()
		world.step()
		var elapsed: float = float(Time.get_ticks_usec() - step_start) / 1000.0
		timings.append(elapsed)
		var counts: PackedInt32Array = world.counts()
		var row := PackedStringArray([str(world.tick), str(elapsed), str(counts[0]), str(counts[1]), str(counts[2]), str(world.capture_count), str(world.grid.candidate_count), str(world.grid.max_occupancy)])
		for phase: int in range(world.phase_usec.size()):
			row.append(str(world.phase_usec[phase]))
		row.append(str(world.ai.last_perception_jobs))
		row.append(str(world.ai.last_decision_jobs))
		row.append(str(world.ai.max_perception_delay_ticks))
		row.append(str(world.ai.max_decision_delay_ticks))
		row.append_array(world.probes.step_columns())
		row.append_array(_activity_columns(world))
		rows.append(row)
	var wall_seconds: float = float(Time.get_ticks_usec() - started) / 1000000.0
	timings.sort()
	var summary: Dictionary = {
		"instrumentation": world.probes.summary(),
		"compact_flock_knowledge": world.config.compact_flock_knowledge,
		"shared_cell_candidates": world.config.shared_cell_candidates,
		"crowd_motion_enabled": world.config.crowd_motion_enabled,
		"retained_observations_by_species": Array(world.ai.knowledge_observation_counts()),
		"mode": "headless fixed-step CPU; not rendered FPS",
		"engine": Engine.get_version_info(), "debug_build": OS.is_debug_build(),
		"processor": OS.get_processor_name(), "logical_processors": OS.get_processor_count(),
		"os": OS.get_name(), "os_version": OS.get_version(),
		"seed": scenario.random_seed, "layout": scenario.layout, "initial": [scenario.sheep_count, scenario.wolf_count, scenario.dog_count],
		"final": Array(world.counts()), "world_size": [config.world_size.x, config.world_size.y],
		"fixed_dt": config.fixed_dt, "grid_cell_size": config.cell_size,
		"max_perception_delay_ticks": world.ai.max_perception_delay_ticks,
		"max_decision_delay_ticks": world.ai.max_decision_delay_ticks,
		"budget_exhaustions": world.ai.budget_exhaustions, "ai_budget_usec_per_step_frame": config.ai_budget_usec,
		"warmup_ticks": warmup, "sample_ticks": samples, "wall_seconds": wall_seconds,
		"simulation_seconds_per_wall_second": samples * config.fixed_dt / wall_seconds,
		"step_p50_ms": timings[floori((samples - 1) * 0.5)],
		"step_p95_ms": timings[floori((samples - 1) * 0.95)],
		"step_p99_ms": timings[floori((samples - 1) * 0.99)],
		"step_max_ms": timings[-1], "captures": world.capture_count,
		"sampling_overhead": "counts and in-memory CSV row construction included in wall time; excluded from step timer"
	}
	DirAccess.make_dir_recursive_absolute(output)
	world.probes.export_jobs(output)
	world.probes.export_queues(output)
	var csv: FileAccess = FileAccess.open(output.path_join("steps.csv"), FileAccess.WRITE)
	if csv == null:
		push_error("Cannot write benchmark output: " + output)
		get_tree().quit(1)
		return
	csv.store_csv_line(PackedStringArray(["tick", "step_ms", "sheep", "wolves", "dogs", "captures", "grid_candidates", "max_cell_occupancy", "commands_us", "coordination_us", "grid_us", "ai_us", "motion_us", "interaction_us", "publish_us", "perception_jobs", "decision_jobs", "max_perception_delay_ticks", "max_decision_delay_ticks"]) + world.probes.column_names() + _activity_names())
	for row: PackedStringArray in rows:
		csv.store_csv_line(row)
	csv.close()
	var json: FileAccess = FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	json.store_string(JSON.stringify(summary, "  "))
	json.close()
	print(JSON.stringify(summary))
	world.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)

func _run_rendered() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn") as PackedScene
	var main: Node2D = packed.instantiate() as Node2D
	main.set_meta("benchmark_view", true)
	get_tree().root.add_child(main)
	get_tree().current_scene = main
	await get_tree().process_frame
	await get_tree().process_frame
	main._seed.value = int(_options.get("seed", "42"))
	main._sheep.value = int(_options.get("sheep", str(main._world.scenario.sheep_count)))
	main._wolves.value = int(_options.get("wolves", str(main._world.scenario.wolf_count)))
	main._dogs.value = int(_options.get("dogs", str(main._world.scenario.dog_count)))
	main._layout.select(int(_options.get("layout", "0")))
	main._reset_scenario()
	main._zoom = float(_options.get("view-scale", str(main._zoom)))
	main._fit_camera()
	var world: SimulationWorld = main._world
	world.config.ai_budget_usec = int(_options.get("ai-budget-usec", str(world.config.ai_budget_usec)))
	world.config.compact_flock_knowledge = _options.get("compact-flock", "1") == "1"
	_configure_backends(world.config)
	world.probes.enabled = _options.get("instrument", "1") == "1"
	world.config.instrument_enabled = world.probes.enabled
	var runner: SimulationRunner = main._runner
	var view: WorldPresentation = main._view
	var warmup_seconds: float = float(_options.get("warmup-seconds", "10"))
	var sample_seconds: float = float(_options.get("sample-seconds", "60"))
	var warmup_start: int = Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - warmup_start) / 1000000.0 < warmup_seconds:
		await RenderingServer.frame_post_draw
	world.probes.reset_window()
	var timings: Array[float] = []
	var rows: Array[PackedStringArray] = []
	var start_tick: int = world.tick
	var start_time: int = Time.get_ticks_usec()
	var previous_time: int = start_time
	var min_visible: int = view.visible_count
	var max_visible: int = view.visible_count
	var max_backlog: float = 0.0
	while float(Time.get_ticks_usec() - start_time) / 1000000.0 < sample_seconds:
		await RenderingServer.frame_post_draw
		var now: int = Time.get_ticks_usec()
		var interval_ms: float = float(now - previous_time) / 1000.0
		previous_time = now
		timings.append(interval_ms)
		var counts: PackedInt32Array = world.counts()
		min_visible = mini(min_visible, view.visible_count)
		max_visible = maxi(max_visible, view.visible_count)
		max_backlog = maxf(max_backlog, runner.accumulator_seconds)
		var row := PackedStringArray([
			str(world.tick), str(interval_ms), str(runner.cpu_frame_msec),
			str(view.render_build_usec), str(view.sort_usec),
			str(counts[0]), str(counts[1]), str(counts[2]), str(view.visible_count),
			str(runner.accumulator_seconds), str(runner.last_step_count),
			str(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		])
		for phase: int in range(runner.frame_phase_usec.size()):
			row.append(str(runner.frame_phase_usec[phase]))
		row.append_array(world.probes.step_columns())
		row.append_array(_activity_columns(world))
		rows.append(row)
	var elapsed: float = float(Time.get_ticks_usec() - start_time) / 1000000.0
	timings.sort()
	var summary: Dictionary = {
		"instrumentation": world.probes.summary(),
		"compact_flock_knowledge": world.config.compact_flock_knowledge,
		"shared_cell_candidates": world.config.shared_cell_candidates,
		"crowd_motion_enabled": world.config.crowd_motion_enabled,
		"activity_sampling": "Cache and activity columns are last-published-step snapshots, not totals across catch-up steps. moved counts require >0.01 pixel actual displacement.",
		"retained_observations_by_species": Array(world.ai.knowledge_observation_counts()),
		"mode": "rendered real scene including observer UI and sampler",
		"engine": Engine.get_version_info(), "debug_build": OS.is_debug_build(),
		"processor": OS.get_processor_name(), "logical_processors": OS.get_processor_count(),
		"gpu": RenderingServer.get_video_adapter_name(), "rendering_method": RenderingServer.get_current_rendering_method(),
		"os": OS.get_name(), "os_version": OS.get_version(),
		"resolution": [get_tree().root.size.x, get_tree().root.size.y], "camera_zoom": main._camera.zoom.x,
		"vsync_mode": DisplayServer.window_get_vsync_mode(), "engine_max_fps": Engine.max_fps,
		"seed": world.scenario.random_seed, "layout": world.scenario.layout,
		"initial": [world.scenario.sheep_count, world.scenario.wolf_count, world.scenario.dog_count],
		"final": Array(world.counts()), "world_size": [world.config.world_size.x, world.config.world_size.y],
		"fixed_dt": world.config.fixed_dt, "grid_cell_size": world.config.cell_size,
		"ai_budget_usec_per_render_frame": world.config.ai_budget_usec,
		"warmup_seconds": warmup_seconds, "sample_wall_seconds": elapsed, "sample_frames": timings.size(),
		"simulation_seconds_per_wall_second": (world.tick - start_tick) * world.config.fixed_dt / elapsed,
		"frame_p50_ms": _percentile(timings, 0.5), "frame_p95_ms": _percentile(timings, 0.95),
		"frame_p99_ms": _percentile(timings, 0.99), "frame_max_ms": timings[-1],
		"max_backlog_seconds": max_backlog, "visible_min": min_visible, "visible_max": max_visible,
		"max_perception_delay_ticks": world.ai.max_perception_delay_ticks,
		"max_decision_delay_ticks": world.ai.max_decision_delay_ticks,
		"budget_exhaustions": world.ai.budget_exhaustions, "captures": world.capture_count,
		"sampling_overhead": "Read counters and population scan once per frame; in-memory rows, final file IO excluded. Frame intervals include sampler and UI, and may include vsync waiting. CPU timings do not measure GPU execution."
	}
	var output: String = _options.get("output", "user://benchmark-rendered")
	DirAccess.make_dir_recursive_absolute(output)
	world.probes.export_jobs(output)
	world.probes.export_queues(output)
	var csv: FileAccess = FileAccess.open(output.path_join("frames.csv"), FileAccess.WRITE)
	if csv == null:
		push_error("Cannot write rendered benchmark output: " + output)
		get_tree().quit(1)
		return
	csv.store_csv_line(PackedStringArray([
		"tick", "frame_interval_ms", "runner_cpu_ms", "render_build_us", "sort_us",
		"sheep", "wolves", "dogs", "visible", "backlog_seconds", "steps",
		"engine_draw_calls", "commands_us", "coordination_us", "grid_us", "ai_us", "motion_us", "interaction_us", "publish_us"
	]) + world.probes.column_names() + _activity_names())
	for row: PackedStringArray in rows:
		csv.store_csv_line(row)
	csv.close()
	var json: FileAccess = FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	json.store_string(JSON.stringify(summary, "  "))
	json.close()
	get_tree().root.get_texture().get_image().save_png(output.path_join("final-frame.png"))
	print(JSON.stringify(summary))
	main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)

func _percentile(sorted: Array[float], fraction: float) -> float:
	return sorted[clampi(ceili(sorted.size() * fraction) - 1, 0, sorted.size() - 1)]

func _configure_backends(config: SimulationConfig) -> void:
	config.shared_cell_candidates = _options.get("shared-candidates", str(int(config.shared_cell_candidates))) == "1"
	config.crowd_motion_enabled = _options.get("crowd-field", str(int(config.crowd_motion_enabled))) == "1"

func _activity_names() -> PackedStringArray:
	return PackedStringArray([
		"shared_hits_last_step", "shared_builds_last_step", "shared_fallbacks_last_step", "shared_candidates_last_step", "shared_filter_visits_last_step",
		"moved_sheep_last_step", "moved_wolves_last_step", "moved_dogs_last_step", "displacement_pixels_last_step",
		"field_build_us_last_step", "field_sample_us_last_step", "exact_sample_us_last_step",
		"field_agents_last_step", "exact_agents_last_step", "field_cell_visits_last_step", "exact_candidates_last_step", "exact_neighbors_last_step", "aggregate_contributions_last_step"
	])

func _activity_columns(world: SimulationWorld) -> PackedStringArray:
	var moved := PackedInt32Array([0, 0, 0])
	var displacement: float = 0.0
	for dense: int in world.store.count:
		if world.store.alive[dense] == 0:
			continue
		var distance: float = world.store.position_previous[dense].distance_to(world.store.position_current[dense])
		if distance > 0.01:
			moved[world.store.species[dense]] += 1
		displacement += distance
	return PackedStringArray([
		str(world.grid.shared_hits), str(world.grid.shared_builds), str(world.grid.shared_fallbacks), str(world.grid.shared_candidate_references), str(world.grid.shared_filter_visits),
		str(moved[0]), str(moved[1]), str(moved[2]), str(displacement),
		str(world.motion.field_build_usec), str(world.motion.field_sample_usec), str(world.motion.exact_sample_usec),
		str(world.motion.field_agent_count), str(world.motion.exact_agent_count), str(world.motion.field_cell_visits), str(world.motion.exact_candidate_visits), str(world.motion.exact_neighbor_visits), str(world.motion.aggregate_agent_contributions)
	])

func _run_threat_scan() -> void:
	var output: String = _options.get("output", "user://threat-scan")
	DirAccess.make_dir_recursive_absolute(output)
	var results: Array[Dictionary] = []
	for budget: int in [2000, 4000, 8000]:
		for seed_value: int in [42, 1337, 2026]:
			var config := SimulationConfig.new()
			config.instrument_enabled = true
			config.compact_flock_knowledge = _options.get("compact-flock", "1") == "1"
			_configure_backends(config)
			config.ai_budget_usec = 100000 # Fixture warm-up is identical across budget variants.
			var scenario := ScenarioConfig.new()
			scenario.random_seed = seed_value
			scenario.sheep_count = 0
			scenario.wolf_count = 0
			scenario.dog_count = 0
			var world := SimulationWorld.new()
			get_tree().root.add_child(world)
			world.setup(config, scenario)
			var fixture_random := RandomNumberGenerator.new()
			fixture_random.seed = seed_value
			for index: int in int(_options.get("sheep", "80")):
				var position := Vector2(700, 500) + Vector2(fixture_random.randf_range(-40, 40), fixture_random.randf_range(-40, 40))
				var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, position)
				world.store.hunger[world.store.resolve(sheep)] = 0.9
			await get_tree().process_frame
			var spawn_tick: int = int(_options.get("threat-tick", "240"))
			for step: int in spawn_tick:
				world.ai.begin_frame()
				world.step()
			var marked: Array[AgentHandle] = []
			var rightmost: float = 0.0
			var center := Vector2.ZERO
			for slot: int in world.ai.contexts:
				var context: AgentContext = world.ai.contexts[slot]
				if context.task_name == &"graze_grass" and marked.size() < int(_options.get("threat-sheep", "20")):
					marked.append(context.handle)
					rightmost = maxf(rightmost, context.position().x)
					center += context.position()
			assert(marked.size() == int(_options.get("threat-sheep", "20")), "Threat fixture requires the requested number of calm grazers")
			var keep_slots: Dictionary[int, bool] = {}
			for sheep: AgentHandle in marked:
				keep_slots[sheep.slot] = true
			for slot: int in world.ai.contexts.keys():
				if not keep_slots.has(slot):
					world._remove(world.ai.contexts[slot].handle)
			config.ai_budget_usec = budget
			center /= float(marked.size())
			var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(rightmost + 200.0, center.y))
			# Fixture stimulus: initialize an inward search destination, then leave the
			# normal wolf tree and movement untouched. No observer writes after this.
			world.ai.contexts[wolf.slot].wander_destination = center
			world.ai.contexts[wolf.slot].wander_until = world.tick + 900
			world.probes.reset_window()
			var visible_tick: int = -1
			var discovered: Dictionary[int, int] = {}
			var first_discovery: int = -1
			var first_response: int = -1
			var response_discovery: int = -1
			for step: int in 900:
				var at_tick: int = world.tick
				var wolf_dense: int = world.store.resolve(wolf)
				for sheep: AgentHandle in marked:
					var dense: int = world.store.resolve(sheep)
					if dense >= 0 and wolf_dense >= 0 and world.store.position_current[dense].distance_squared_to(world.store.position_current[wolf_dense]) <= config.perception_radius * config.perception_radius:
						if visible_tick < 0:
							visible_tick = at_tick
				world.ai.begin_frame()
				world.step()
				for sheep: AgentHandle in marked:
					var context: AgentContext = world.ai.contexts.get(sheep.slot)
					if context == null or not context.handle.same_life(sheep):
						continue
					var observation: LocalObservation = context.observations.get(wolf.slot)
					if observation != null and observation.handle.same_life(wolf) and observation.last_direct_tick >= spawn_tick and not discovered.has(sheep.slot):
						discovered[sheep.slot] = observation.last_direct_tick
						if first_discovery < 0:
							first_discovery = observation.last_direct_tick
					if visible_tick >= 0 and first_response < 0 and context.task_name == &"flee_threat":
						first_response = at_tick
						response_discovery = discovered.get(sheep.slot, -1)
				if first_response >= 0:
					break
			var result: Dictionary = {
				"seed": seed_value,
				"budget_us": budget,
				"compact_flock_knowledge": config.compact_flock_knowledge,
				"shared_cell_candidates": config.shared_cell_candidates,
				"crowd_motion_enabled": config.crowd_motion_enabled,
				"marked_grazing": marked.size(),
				"spawn_tick": spawn_tick,
				"geometric_visible_tick": visible_tick,
				"response_tick": first_response,
				"responding_sheep_direct_discovery_tick": response_discovery,
				"total_ticks": first_response - visible_tick if first_response >= 0 else -1,
				"first_cohort_discovery_tick": first_discovery,
				"discovery_ticks": first_discovery - visible_tick if first_discovery >= 0 else -1,
				"decision_ticks": first_response - first_discovery if first_discovery >= 0 else -1,
				"shared_response_without_direct_discovery": first_response >= 0 and response_discovery < 0,
				"censored": first_response < 0,
			}
			results.append(result)
			var run_output: String = output.path_join("%d-%d" % [budget, seed_value])
			DirAccess.make_dir_recursive_absolute(run_output)
			world.probes.export_jobs(run_output)
			world.probes.export_queues(run_output)
			var run_file: FileAccess = FileAccess.open(run_output.path_join("summary.json"), FileAccess.WRITE)
			run_file.store_string(JSON.stringify({"response": result, "instrumentation": world.probes.summary()}, "  "))
			run_file.close()
			world.queue_free()
			await get_tree().process_frame
	var json: FileAccess = FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	json.store_string(JSON.stringify({"runs": results, "engine": Engine.get_version_info(), "debug_build": OS.is_debug_build(), "observer": "Read-only full scan of marked grazers before each step; observer and probes overhead included in wall time. Start is first geometric visibility, not sensing. 200 px is outside 180 px radius; wolf approaches from outside. Cohort split: first direct discovery by any marked sheep to first flee; decision segment includes local communication. Only selected calm grazers remain at stimulus; identical 100ms-budget warm-up, then switch to the swept budget."}, "  "))
	json.close()
	var csv: FileAccess = FileAccess.open(output.path_join("responses.csv"), FileAccess.WRITE)
	var header := PackedStringArray()
	for key: String in results[0]:
		header.append(key)
	csv.store_csv_line(header)
	for result: Dictionary in results:
		var row := PackedStringArray()
		for key: String in header:
			row.append(str(result[key]))
		csv.store_csv_line(row)
	csv.close()
	print(JSON.stringify(results))
	get_tree().quit(0)
