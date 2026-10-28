class_name BenchmarkSession
extends Node
## Two explicit modes: headless fixed-step CPU throughput and the actual rendered scene.
var _options: Dictionary[String, String] = {}

func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var pair: PackedStringArray = argument.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2:
			_options[pair[0]] = pair[1]
	call_deferred("_run")

func _run() -> void:
	if _options.get("rendered", "0") == "1" or _options.get("benchmark", "cpu") == "frames":
		await _run_rendered()
		return
	var config := SimulationConfig.new()
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
		rows.append(row)
	var wall_seconds: float = float(Time.get_ticks_usec() - started) / 1000000.0
	timings.sort()
	var summary: Dictionary = {
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
	var csv: FileAccess = FileAccess.open(output.path_join("steps.csv"), FileAccess.WRITE)
	if csv == null:
		push_error("Cannot write benchmark output: " + output)
		get_tree().quit(1)
		return
	csv.store_csv_line(PackedStringArray(["tick", "step_ms", "sheep", "wolves", "dogs", "captures", "grid_candidates", "max_cell_occupancy", "commands_us", "coordination_us", "grid_us", "ai_us", "motion_us", "interaction_us", "publish_us", "perception_jobs", "decision_jobs", "max_perception_delay_ticks", "max_decision_delay_ticks"]))
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
	var world: SimulationWorld = main._world
	world.config.ai_budget_usec = int(_options.get("ai-budget-usec", str(world.config.ai_budget_usec)))
	var runner: SimulationRunner = main._runner
	var view: WorldPresentation = main._view
	var warmup_seconds: float = float(_options.get("warmup-seconds", "10"))
	var sample_seconds: float = float(_options.get("sample-seconds", "60"))
	var warmup_start: int = Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - warmup_start) / 1000000.0 < warmup_seconds:
		await RenderingServer.frame_post_draw
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
		rows.append(row)
	var elapsed: float = float(Time.get_ticks_usec() - start_time) / 1000000.0
	timings.sort()
	var summary: Dictionary = {
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
	var csv: FileAccess = FileAccess.open(output.path_join("frames.csv"), FileAccess.WRITE)
	if csv == null:
		push_error("Cannot write rendered benchmark output: " + output)
		get_tree().quit(1)
		return
	csv.store_csv_line(PackedStringArray([
		"tick", "frame_interval_ms", "runner_cpu_ms", "render_build_us", "sort_us",
		"sheep", "wolves", "dogs", "visible", "backlog_seconds", "steps",
		"engine_draw_calls", "commands_us", "coordination_us", "grid_us", "ai_us", "motion_us", "interaction_us", "publish_us"
	]))
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
