class_name ProductionBehaviorBenchmark
extends Node
## Frontend host for the worker-owned protocol. No live World/context access.
var _main: Node2D

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var options: Dictionary[String, String] = {}
	for argument: String in OS.get_cmdline_user_args():
		var pair: PackedStringArray = argument.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2:
			options[pair[0]] = pair[1]
	var sheep_count: int = int(options.get("sheep", "80"))
	var behavior_case: String = options.get("behavior-case", "two-flocks")
	var seed_value: int = int(options.get("seed", "42"))
	var forage_error: String = ProductionForageCohort.argument_error(OS.get_cmdline_user_args(), behavior_case, sheep_count, seed_value)
	if not forage_error.is_empty():
		push_error(forage_error)
		get_tree().quit(1)
		return
	var geometry_error: String = ProductionHuntGeometry.argument_error(OS.get_cmdline_user_args(), behavior_case, sheep_count)
	if not geometry_error.is_empty():
		push_error(geometry_error)
		get_tree().quit(1)
		return
	var hunt_layout_error: String = ProductionHuntCohort.argument_error(OS.get_cmdline_user_args(), behavior_case, sheep_count, seed_value)
	if not hunt_layout_error.is_empty():
		push_error(hunt_layout_error)
		get_tree().quit(1)
		return
	var dog_error: String = ProductionDogProtectionGeometry.argument_error(OS.get_cmdline_user_args(), behavior_case, sheep_count, seed_value)
	if dog_error.is_empty():
		dog_error = ProductionDogWithdrawal.argument_error(OS.get_cmdline_user_args(), behavior_case, sheep_count, seed_value)
	if not dog_error.is_empty():
		push_error(dog_error)
		get_tree().quit(1)
		return
	if behavior_case not in ["two-flocks", "dog-protection", "dog-withdrawal", "hunt-cooperation", "forage-migration", "forage-empty"]:
		push_error("Unknown production behavior case: " + behavior_case)
		get_tree().quit(1)
		return
	if sheep_count < 8 or sheep_count > 1000:
		push_error("Production behavior protocol accepts 8..1000 sheep; counts are not silently clamped.")
		get_tree().quit(1)
		return
	if options.get("simulation", "worker") != "worker" or int(options.get("worker-ai-budget-usec", "6000")) != 6000 or options.get("motion-backend", "gpu") != "gpu":
		push_error("Production behavior protocol requires worker, GPU and the unchanged 6000us allowance.")
		get_tree().quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.motion_backend = SimulationConfig.MotionBackend.GPU
	config.worker_ai_budget_usec = 6000
	config.instrument_enabled = false
	if behavior_case in ["forage-migration", "forage-empty"]:
		config.grass_recovery_rate = 0.0
	var scenario := ScenarioConfig.new()
	scenario.random_seed = seed_value
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node2D
	_main.set_meta("benchmark_view", true)
	_main.set_meta("worker_benchmark", true)
	_main.set_meta("initial_config", config)
	_main.set_meta("initial_scenario", scenario)
	get_tree().root.add_child(_main)
	get_tree().current_scene = _main
	await get_tree().process_frame
	await get_tree().process_frame
	_main.observer.set_process_input(false)
	_main.observer.set_process_unhandled_input(false)
	get_tree().root.gui_disable_input = true
	var access: SimulationAccess = _main._access
	var timeout_usec: int = Time.get_ticks_usec() + 180000000
	var report: Dictionary = {}
	while report.is_empty() and Time.get_ticks_usec() < timeout_usec:
		await get_tree().process_frame
		report = access.executor.take_behavior_report()
	if report.is_empty():
		push_error("Production behavior protocol timed out; incomplete run must not be treated as a pass.")
		get_tree().quit(1)
		return
	report["engine"] = Engine.get_version_info()
	report["debug_build"] = OS.is_debug_build()
	report["processor"] = OS.get_processor_name()
	report["gpu"] = RenderingServer.get_video_adapter_name()
	report["rendering_method"] = RenderingServer.get_current_rendering_method()
	report["resolution"] = str(get_viewport().get_visible_rect().size)
	report["screen_hz"] = DisplayServer.screen_get_refresh_rate()
	report["vsync"] = DisplayServer.window_get_vsync_mode()
	report["execution"] = "actual worker; frontend continues rendering; completed immutable report transferred once"
	if not report.get("fixture_valid", true):
		var failure_output: String = options.get("output", "user://production-behavior")
		DirAccess.make_dir_recursive_absolute(failure_output)
		var failure_saved: bool = _write_json(failure_output.path_join("summary.json"), report)
		if not failure_saved:
			push_error("Fixture rejection report could not be saved; diagnostic evidence is incomplete.")
		push_error("Production behavior fixture rejected: " + str(report["fixture_error"]))
		_main.queue_free()
		await get_tree().process_frame
		get_tree().quit(1)
		return
	var valid_backend: bool = report["motion_backend"] == "gpu" and report["detached_ai"] and int(report["ai_budget_usec"]) == 6000
	report["production_backend_valid"] = valid_backend
	var output: String = options.get("output", "user://production-behavior")
	DirAccess.make_dir_recursive_absolute(output)
	var saved: bool = _write_json(output.path_join("summary.json"), report)
	saved = _write_records(output.path_join("responses.csv"), report["records"]) and saved
	saved = _write_records(output.path_join("quality.csv"), report["quality"]) and saved
	if behavior_case == "two-flocks":
		saved = _write_records(output.path_join("sheep-terminal.csv"), report["sheep_terminal"]) and saved
		saved = _write_records(output.path_join("sheep-recovery-v2.csv"), report["sheep_recovery_v2"]) and saved
		saved = _write_records(output.path_join("exposure-episodes.csv"), report["exposure_episodes"]) and saved
		saved = _write_records(output.path_join("dog-contexts.csv"), report["dog_contexts"]) and saved
		saved = _write_records(output.path_join("dog-threats.csv"), report["dog_threats"]) and saved
	else:
		saved = _write_records(output.path_join("terminal.csv"), report["terminal"]) and saved
		if behavior_case in ["dog-protection", "dog-withdrawal"]:
			saved = _write_records(output.path_join("initial-roster.csv"), report["initial_roster"]) and saved
			saved = _write_records(output.path_join("preflight.csv"), report["preflight"]) and saved
			saved = _write_records(output.path_join("dog-contexts.csv"), report["dog_contexts"]) and saved
			saved = _write_records(output.path_join("dog-threats.csv"), report["dog_threats"]) and saved
			saved = _write_records(output.path_join("wolf-steps.csv"), report["wolf_steps"]) and saved
			saved = _write_records(output.path_join("anchor-changes.csv"), report["anchor_changes"]) and saved
			saved = _write_records(output.path_join("cohort-samples.csv"), report["cohort_samples"]) and saved
			saved = _write_records(output.path_join("captures.csv"), report["captures"]) and saved
			if behavior_case == "dog-withdrawal":
				saved = _write_records(output.path_join("withdrawal-records.csv"), report["withdrawal_records"]) and saved
				saved = _write_records(output.path_join("withdrawal-pre299.csv"), report["withdrawal_pre299"]) and saved
				saved = _write_records(output.path_join("withdrawal-boundary.csv"), report["withdrawal_boundary"]) and saved
				saved = _write_records(output.path_join("withdrawal-dog-controls.csv"), report["withdrawal_dog_controls"]) and saved
		elif behavior_case == "hunt-cooperation":
			saved = _write_records(output.path_join("roles.csv"), report["roles"]) and saved
			saved = _write_records(output.path_join("hunt-contexts.csv"), report["samples"]) and saved
			saved = _write_records(output.path_join("attack-steps.csv"), report["attack_steps"]) and saved
			saved = _write_records(output.path_join("captures.csv"), report["captures"]) and saved
			if report.get("layout", "") == "fixed-cohort80":
				saved = _write_records(output.path_join("initial-cohort.csv"), report["initial_cohort"]) and saved
				saved = _write_records(output.path_join("initial-background.csv"), report["initial_background"]) and saved
				saved = _write_records(output.path_join("background-quality.csv"), report["background_quality"]) and saved
				saved = _write_records(output.path_join("sheep-terminal.csv"), report["sheep_terminal"]) and saved
				saved = _write_records(output.path_join("hunter-body-preflight.csv"), report["hunter_body_preflight"]) and saved
		else:
			saved = _write_records(output.path_join("first-intake.csv"), report["first_intake"]) and saved
			saved = _write_records(output.path_join("forage-diagnostics.csv"), report["forage_diagnostics"]) and saved
			saved = _write_records(output.path_join("forage-samples.csv"), report["forage_samples"]) and saved
			saved = _write_records(output.path_join("forage-events.csv"), report["forage_events"]) and saved
			saved = _write_records(output.path_join("forage-terminal-context.csv"), report["forage_terminal_context"]) and saved
			if report.get("layout", "") == "fixed-cohort80":
				saved = _write_records(output.path_join("initial-cohort.csv"), report["initial_cohort"]) and saved
				saved = _write_records(output.path_join("initial-background.csv"), report["initial_background"]) and saved
				saved = _write_records(output.path_join("background-quality.csv"), report["background_quality"]) and saved
				saved = _write_records(output.path_join("background-intrusions.csv"), report["background_intrusions"]) and saved
	print(JSON.stringify({"protocol": report["protocol"], "seed": report["seed"], "sheep": sheep_count,
		"production_backend_valid": valid_backend, "outcomes": report["outcomes"], "behavior_case": behavior_case,
		"target_invalidation": report.get("target_invalidation", {}), "output": output}))
	_main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if valid_backend and saved else 1)

func _write_json(path: String, record: Dictionary) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write diagnostic report: " + path)
		return false
	file.store_string(JSON.stringify(record, "  "))
	file.close()
	return true

func _write_records(path: String, records: Array) -> bool:
	if records.is_empty():
		return true
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write diagnostic records: " + path)
		return false
	var columns := PackedStringArray()
	for key: String in records[0]:
		columns.append(key)
	file.store_csv_line(columns)
	for record: Dictionary in records:
		var values := PackedStringArray()
		for key: String in columns:
			values.append(str(record[key]))
		file.store_csv_line(values)
	file.close()
	return true
