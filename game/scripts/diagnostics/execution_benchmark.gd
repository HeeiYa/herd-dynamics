class_name ExecutionBenchmark
extends Node
## Actual observer scene, complete GPU path, and an independent deferred pulse.
## Pulse latency measures main-loop dispatch, not OS/device-to-photon latency.
var _options: Dictionary[String, String] = {}
var _main: Node2D
var _access: SimulationAccess
var _sampling: bool = false
var _started_usec: int = 0
var _frames: Array[PackedStringArray] = []
var _steps: Array[PackedStringArray] = []
var _pulses: Array[PackedStringArray] = []
var _receipts: Array[PackedStringArray] = []
var _faults: Array[PackedStringArray] = []
var _frame_times: Array[float] = []
var _display_ages: Array[float] = []
var _receipt_latencies: Array[float] = []
var _budget_overruns: int = 0
var _maximum_overrun_usec: int = 0
var _maximum_commit_usec: int = 0
var _submitted_controls: int = 0
var _received_controls: int = 0
var _rejected_controls: int = 0
var _controls: Dictionary[int, bool] = {}
var _dispatch_times: Array[float] = []
var _pulse_thread := Thread.new()
var _pulse_mutex := Mutex.new()
var _stop_pulses: bool = false
var _actions: Array[PackedStringArray] = []
var _previous_probe_sums := PackedInt64Array()
var _regeneration_epoch: int = -1
var _regeneration_usec: int = 0
var _first_new_epoch_ms: float = -1.0
var _population_ready_ms: float = -1.0
var _regeneration_count: int = 0

func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var pair: PackedStringArray = argument.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2:
			_options[pair[0]] = pair[1]
	call_deferred("_run")

func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var scenario := ScenarioConfig.new()
	scenario.random_seed = int(_options.get("seed", "42"))
	scenario.layout = int(_options.get("layout", "3")) as ScenarioConfig.Layout
	scenario.sheep_count = int(_options.get("sheep", "1000"))
	scenario.wolf_count = int(_options.get("wolves", "12"))
	scenario.dog_count = int(_options.get("dogs", "8"))
	var config := SimulationConfig.new()
	if not PastureBenchmarkOptions.apply_to(config, _options):
		push_error("Invalid pasture benchmark options")
		get_tree().quit(1)
		return
	config.motion_backend = SimulationConfig.MotionBackend.GPU
	config.instrument_enabled = _options.get("instrument", "0") == "1"
	config.ai_budget_usec = int(_options.get("ai-budget-usec", "2000"))
	config.worker_ai_budget_usec = int(_options.get("worker-ai-budget-usec", "6000"))
	var worker: bool = _options.get("simulation", "worker") != "inline"
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node2D
	_main.set_meta("benchmark_view", true)
	_main.set_meta("worker_benchmark", worker)
	_main.set_meta("initial_scenario", scenario)
	_main.set_meta("initial_config", config)
	get_tree().root.add_child(_main)
	get_tree().current_scene = _main
	await get_tree().process_frame
	await get_tree().process_frame
	_main.observer.set_process_input(false)
	_main.observer.set_process_unhandled_input(false)
	get_tree().root.gui_disable_input = true
	_access = _main._access
	var output: String = _options.get("output", "user://execution-benchmark")
	DirAccess.make_dir_recursive_absolute(output)
	if _options.get("observer-log", "0") == "1":
		_main._session_log = ObserverSessionLog.new()
		_main._session_log.start(_access, _main._runner, output.path_join("observer.jsonl"))
	if worker:
		_access.delivery_completed.connect(_on_publication)
	else:
		_main._runner.step_completed.connect(_on_inline_step)
	_access.command_completed.connect(_on_receipt)
	var warmup_start: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - warmup_start < int(float(_options.get("warmup-seconds", "10")) * 1000000.0):
		await RenderingServer.frame_post_draw
	# Optional diagnostics affect frontend probes only in worker mode. Keep
	# expensive worker job instrumentation out of capacity measurements.
	var frontend_probes: bool = _options.get("frontend-probes", "0") == "1"
	_access.probes.enabled = frontend_probes or config.instrument_enabled
	_access.probes.reset_window()
	_previous_probe_sums = _access.probes.sums.duplicate()
	var measure_gpu: bool = _options.get("measure-gpu", "0") == "1"
	var viewport_rid: RID = get_tree().root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, measure_gpu)
	if _access.motion_backend_status != "gpu":
		push_error("Execution benchmark requires actual GPU execution: " + _access.motion_backend_status)
		get_tree().quit(1)
		return
	var thread_result: Error = _pulse_thread.start(_produce_pulses)
	if thread_result != OK:
		push_error("Cannot start dispatch probe")
		get_tree().quit(1)
		return
	_started_usec = Time.get_ticks_usec()
	var start_tick: int = _access.tick
	var start_counts: PackedInt32Array = _access.counts()
	_sampling = true
	var previous_usec: int = _started_usec
	var next_fault: int = _started_usec + 1000000
	var fault_msec: int = clampi(int(_options.get("stall-ms", "0")), 0, 500)
	var busy: bool = _options.get("stall-busy", "0") == "1"
	var sample_usec: int = int(float(_options.get("sample-seconds", "20")) * 1000000.0)
	var next_action_usec: int = _started_usec + 1500000
	var action_index: int = 0
	var control_hz: float = clampf(float(_options.get("control-hz", "0")), 0.0, 20.0)
	var next_control_usec: int = _started_usec
	var start_committed: int = _main._runner.committed_frames
	var start_skipped: int = _access.skipped_states
	var start_display_skipped: int = _main._runner.skipped_display_states
	var regenerate: int = int(_options.get("regenerate", "0"))
	var action_mode: String = _options.get("ui-actions", "none")
	while Time.get_ticks_usec() - _started_usec < sample_usec:
		if control_hz > 0.0 and Time.get_ticks_usec() >= next_control_usec:
			next_control_usec = Time.get_ticks_usec() + int(1000000.0 / control_hz)
			var command := SimulationCommand.new()
			# Alternate immediate control and a stage-zero command. Reapply the
			# same parameter so the benchmark does not change AI quality/load.
			if _submitted_controls % 2 == 0:
				command.kind = SimulationCommand.Kind.SPEED
				command.scalar = 1.0
			else:
				command.kind = SimulationCommand.Kind.TUNING
				command.tuning = TuningCatalog.Change.new(TuningCatalog.Param.PERCEPTION_RADIUS, _access.config.perception_radius)
			if _access.submit(command):
				_controls[command.request_id] = true
				_submitted_controls += 1
		if regenerate > 0 and _regeneration_usec == 0 and Time.get_ticks_usec() - _started_usec >= 1000000:
			_regenerate(regenerate)
		if action_mode != "none" and Time.get_ticks_usec() >= next_action_usec:
			next_action_usec += 500000
			_observer_action(action_index, action_mode)
			action_index += 1
		if fault_msec > 0 and Time.get_ticks_usec() >= next_fault:
			next_fault += 1000000
			_inject_fault(worker, fault_msec, busy)
		await RenderingServer.frame_post_draw
		var now: int = Time.get_ticks_usec()
		var frame_ms: float = float(now - previous_usec) / 1000.0
		previous_usec = now
		_frame_times.append(frame_ms)
		var runner: SimulationRunner = _main._runner
		_track_generation(now)
		var display_age: float = runner.display_age_msec(now) if worker else 0.0
		_display_ages.append(display_age)
		_budget_overruns += int(runner.budget_overrun_usec > 0)
		_maximum_overrun_usec = maxi(_maximum_overrun_usec, runner.budget_overrun_usec)
		_maximum_commit_usec = maxi(_maximum_commit_usec, runner.commit_usec)
		var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid) if measure_gpu else 0.0
		var frame_row := PackedStringArray([str(now - _started_usec), str(_access.tick), str(frame_ms), str(runner.cpu_frame_msec), str(display_age), str(runner.accumulator_seconds), str(_main._view.visible_count), str(_access.store.epoch), str(_access.store.count), str(_main._view.render_build_usec), str(_main._view.sort_usec), str(runner.last_step_count), str(gpu_ms)])
		for tag: Probes.Tag in [Probes.Tag.VISUAL_PUBLISH, Probes.Tag.BODY_PREPARE, Probes.Tag.SHADOWS, Probes.Tag.BODY_SUBMIT, Probes.Tag.OBSERVER_UPDATE, Probes.Tag.HUD_REFRESH]:
			frame_row.append(str(_access.probes.sums[tag] - _previous_probe_sums[tag]))
		_previous_probe_sums = _access.probes.sums.duplicate()
		frame_row.append_array(PackedStringArray([str(runner.event_usec), str(runner.prepare_usec), str(runner.commit_usec), str(runner.budget_overrun_usec), str(runner.display_sequence), str(_access.delivered_sequence), str(_access.skipped_states)]))
		_frames.append(frame_row)
	var elapsed_seconds: float = float(Time.get_ticks_usec() - _started_usec) / 1000000.0
	# Drain submitted control receipts while sampling remains on; do not add drain
	# frames to the steady display/frame window. Missing receipts fail the gate.
	var drain_deadline: int = Time.get_ticks_usec() + 2000000
	while _received_controls < _submitted_controls and Time.get_ticks_usec() < drain_deadline:
		await get_tree().process_frame
	_sampling = false
	_pulse_mutex.lock()
	_stop_pulses = true
	_pulse_mutex.unlock()
	_pulse_thread.wait_to_finish()
	var summary: Dictionary = {
		"control_hz": control_hz, "controls_submitted": _submitted_controls, "controls_received": _received_controls,
		"controls_rejected": _rejected_controls, "control_workload": "alternate speed=1 and stage-zero current perception radius",
		"receipt_p99_ms": _percentile(_receipt_latencies, 0.99), "receipt_max_ms": _percentile(_receipt_latencies, 1.0),
		"display_age_p99_ms": _percentile(_display_ages, 0.99), "display_age_max_ms": _percentile(_display_ages, 1.0),
		"frontend_budget_us": SimulationRunner.FRONTEND_BUDGET_USEC,
		"budget_overrun_frames": _budget_overruns, "maximum_overrun_us": _maximum_overrun_usec,
		"maximum_commit_us": _maximum_commit_usec,
		"display_commits": _main._runner.committed_frames - start_committed,
		"skipped_states": _access.skipped_states - start_skipped,
		"skipped_display_states": _main._runner.skipped_display_states - start_display_skipped,
		"latency_gate_100ms": control_hz > 0.0 and _submitted_controls > 0 and _rejected_controls == 0 and _main._runner.committed_frames > start_committed and _received_controls == _submitted_controls and _percentile(_receipt_latencies, 1.0) <= 100.0 and _percentile(_display_ages, 1.0) <= 100.0,
		"pasture": PastureBenchmarkOptions.describe(_access.config),
		"mode": "worker" if worker else "inline", "engine": Engine.get_version_info(),
		"debug_build": OS.is_debug_build(), "processor": OS.get_processor_name(),
		"gpu": RenderingServer.get_video_adapter_name(), "rendering_method": RenderingServer.get_current_rendering_method(),
		"resolution": str(get_viewport().get_visible_rect().size), "screen_hz": DisplayServer.screen_get_refresh_rate(),
		"vsync": DisplayServer.window_get_vsync_mode(), "instrument": config.instrument_enabled,
		"seed": scenario.random_seed, "layout": scenario.layout,
		"initial": [scenario.sheep_count, scenario.wolf_count, scenario.dog_count],
		"start_counts": Array(start_counts), "final_counts": Array(_access.counts()), "captures": _access.capture_count,
		"motion_backend": _access.motion_backend_status, "gpu_bulk": config.gpu_bulk_upload,
		"presentation_backend": "gpu_instances" if config.gpu_presentation else "cpu_canvas",
		"ai_budget_usec": config.worker_ai_budget_usec if worker else config.ai_budget_usec,
		"ai_budget_clock": "fixed step" if worker else "render frame",
		"warmup_seconds": float(_options.get("warmup-seconds", "10")), "wall_seconds": elapsed_seconds,
		"simulation_seconds_per_wall_second": float(_access.tick - start_tick) * config.fixed_dt / elapsed_seconds,
		"frame_p50_ms": _percentile(_frame_times, 0.5), "frame_p95_ms": _percentile(_frame_times, 0.95),
		"frame_p99_ms": _percentile(_frame_times, 0.99), "frame_max_ms": _percentile(_frame_times, 1.0),
		"dispatch_p95_ms": _percentile(_dispatch_times, 0.95), "dispatch_p99_ms": _percentile(_dispatch_times, 0.99),
		"dispatch_max_ms": _percentile(_dispatch_times, 1.0), "dispatch_samples": _pulses.size(),
		"stall_ms": fault_msec, "stall_busy": busy,
		"frontend_probes": frontend_probes, "measure_gpu": measure_gpu,
		"observer_log": _options.get("observer-log", "0") == "1",
		"ui_actions": action_mode, "regenerate_sheep": regenerate,
		"reset_first_publication_ms": _first_new_epoch_ms, "reset_population_ready_ms": _population_ready_ms,
		"regeneration_warning": "Whole-window tick/wall ratio is not valid across reset; derive post-generation throughput from epoch-labelled rows." if regenerate > 0 else "none",
		"frontend_profile": _access.probes.summary(),
		"limitations": "10ms independent deferred pulses measure main-loop dispatch, not hardware input latency. Per-step quality scans and in-memory CSV collection are included in workload. CSV files are written after sampling; optional observer logs are written during sampling. Worker snapshots add their own cost. Wall-budget AI is not deterministic."
	}
	_write_csv(output.path_join("frames.csv"), "elapsed_us,tick,frame_ms,frontend_cpu_ms,snapshot_age_ms,backlog_seconds,visible,epoch,population,render_build_us,sort_us,published_steps,gpu_render_ms,visual_publish_us,body_prepare_us,shadows_us,body_submit_us,observer_update_us,hud_refresh_us,event_us,prepare_us,commit_us,budget_overrun_us,display_sequence,delivered_sequence,skipped_states", _frames)
	_write_csv(output.path_join("steps.csv"), "tick,step_us,snapshot_us,ai_used_us,active,missing_intents,max_perception_delay_ticks,max_decision_delay_ticks,motion_us,epoch,commands_us,coordination_us,grid_us,interaction_us,grass_food,perception_cells,motion_cells,pose_us,store_copy_usec,intent_copy_usec,resource_copy_usec,metadata_copy_usec,quality_usec,pose_changed,pose_allocations,pose_buffer_allocations", _steps)
	_write_csv(output.path_join("pulses.csv"), "sent_us,received_us,dispatch_ms", _pulses)
	_write_csv(output.path_join("receipts.csv"), "request_id,submitted_us,completed_us,delivered_us,accepted,reason", _receipts)
	_write_csv(output.path_join("faults.csv"), "submitted_us,inline_finished_us,duration_ms,busy", _faults)
	_write_csv(output.path_join("actions.csv"), "started_us,handler_us,action,epoch,tick", _actions)
	var file: FileAccess = FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "  "))
	file.close()
	print(JSON.stringify(summary))
	_main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)

func _produce_pulses() -> void:
	while true:
		_pulse_mutex.lock()
		var stopping: bool = _stop_pulses
		_pulse_mutex.unlock()
		if stopping:
			return
		_receive_pulse.call_deferred(Time.get_ticks_usec())
		OS.delay_msec(10)

func _receive_pulse(sent_usec: int) -> void:
	if not _sampling or sent_usec < _started_usec:
		return
	var now: int = Time.get_ticks_usec()
	var latency: float = float(now - sent_usec) / 1000.0
	_dispatch_times.append(latency)
	_pulses.append(PackedStringArray([str(sent_usec - _started_usec), str(now - _started_usec), str(latency)]))

func _inject_fault(worker: bool, milliseconds: int, busy: bool) -> void:
	var started: int = Time.get_ticks_usec()
	var finished: int = 0
	if worker:
		var command := SimulationCommand.new()
		command.kind = SimulationCommand.Kind.STALL
		command.integer = milliseconds
		command.scalar = float(busy)
		_access.submit(command)
	elif busy:
		var deadline: int = started + milliseconds * 1000
		while Time.get_ticks_usec() < deadline:
			var busy_work: float = sin(float(Time.get_ticks_usec()))
			assert(is_finite(busy_work))
		finished = Time.get_ticks_usec() - _started_usec
	else:
		OS.delay_msec(milliseconds)
		finished = Time.get_ticks_usec() - _started_usec
	_faults.append(PackedStringArray([str(started - _started_usec), str(finished), str(milliseconds), str(busy)]))

func _on_publication(snapshot: SimulationTelemetry) -> void:
	if _sampling and snapshot.step_usec > 0:
		_steps.append(PackedStringArray([str(snapshot.tick), str(snapshot.step_usec), str(snapshot.snapshot_usec), str(snapshot.ai_used_usec), str(snapshot.active_agents), str(snapshot.missing_intents), str(snapshot.max_perception_delay_ticks), str(snapshot.max_decision_delay_ticks), str(snapshot.phase_usec[4]), str(snapshot.epoch), str(snapshot.phase_usec[0]), str(snapshot.phase_usec[1]), str(snapshot.phase_usec[2]), str(snapshot.phase_usec[5]), str(snapshot.grass_consumed), str(snapshot.perception_cells), str(snapshot.motion_cells), str(snapshot.pose_usec), str(snapshot.store_copy_usec), str(snapshot.intent_copy_usec), str(snapshot.resource_copy_usec), str(snapshot.metadata_copy_usec), str(snapshot.quality_usec), str(snapshot.pose_changed), str(snapshot.pose_allocations), str(snapshot.pose_buffer_allocations)]))

func _on_inline_step(elapsed_usec: int) -> void:
	if not _sampling:
		return
	var world: SimulationWorld = _main._world
	var active: int = 0
	var missing: int = 0
	for dense: int in world.store.count:
		var handle: AgentHandle = world.store.handle_at(dense)
		if world.store.is_active(handle):
			active += 1
			missing += int(world.intents.get_intent(handle, world.tick) == null)
	_steps.append(PackedStringArray([str(world.tick), str(elapsed_usec), "0", str(world.ai.frame_used_usec), str(active), str(missing), str(world.ai.max_perception_delay_ticks), str(world.ai.max_decision_delay_ticks), str(world.phase_usec[4]), str(world.store.epoch), str(world.phase_usec[0]), str(world.phase_usec[1]), str(world.phase_usec[2]), str(world.phase_usec[5]), str(world.interaction.grass_consumed), str(world.grid.cell_map.storage_count), str(world.motion._crowd_field.cell_map.storage_count), "0", "0", "0", "0", "0", "0", "0", "0", "0"]))

func _regenerate(sheep_count: int) -> void:
	_regeneration_count = sheep_count + int(_main.hud.wolves.value) + int(_main.hud.dogs.value)
	_regeneration_epoch = _access.store.epoch + 1
	_regeneration_usec = Time.get_ticks_usec()
	_main.hud.sheep.value = sheep_count
	var started: int = Time.get_ticks_usec()
	# Same callback as the scene panel's generation button; the timer covers
	# submission, while epoch-labelled frames cover planning and staged births.
	_main.observer.reset_scenario()
	_actions.append(PackedStringArray([str(started - _started_usec), str(Time.get_ticks_usec() - started), "generate", str(_access.store.epoch), str(_access.tick)]))

func _track_generation(now: int) -> void:
	if _regeneration_usec == 0 or _access.store.epoch < _regeneration_epoch:
		return
	if _first_new_epoch_ms < 0.0:
		_first_new_epoch_ms = float(now - _regeneration_usec) / 1000.0
	if _population_ready_ms < 0.0 and _access.store.count + _access.capture_count >= _regeneration_count:
		_population_ready_ms = float(now - _regeneration_usec) / 1000.0

func _observer_action(index: int, mode: String) -> void:
	var started: int = Time.get_ticks_usec()
	var action: String = ""
	if mode == "camera":
		_main._camera.pan_screen(Vector2(8.0 if index % 2 == 0 else -8.0, 0.0))
		action = "camera_pan"
	else:
		match index % 4:
			0:
				_main.hud.toggle_panel()
				action = "panel_toggle"
			1:
				_main.hud.tabs.current_tab = 1
				action = "parameter_tab"
			2:
				if _access.store.count > 0:
					_main.observer.select(_access.store.handle_at(0))
				_main._camera.pan_screen(Vector2(8, 0))
				action = "select_and_pan"
			3:
				# Change only the gesture draft: no altered AI radius/load in an
				# otherwise comparable UI responsiveness measurement.
				var row: TuningPanel.Row = _main.hud.tuning._rows[0]
				_main.hud.tuning._begin_drag(row)
				_main.hud.tuning._on_value(row, row.slider.value)
				_main.hud.tuning._end_drag(row, false)
				action = "slider_preview"
	_actions.append(PackedStringArray([str(started - _started_usec), str(Time.get_ticks_usec() - started), action, str(_access.store.epoch), str(_access.tick)]))

func _on_receipt(receipt: SimulationCommand.Receipt) -> void:
	if _controls.has(receipt.request_id):
		_controls.erase(receipt.request_id)
		_received_controls += 1
		_rejected_controls += int(not receipt.accepted)
	if _sampling:
		_receipt_latencies.append(float(Time.get_ticks_usec() - receipt.submitted_usec) / 1000.0)
		_receipts.append(PackedStringArray([str(receipt.request_id), str(receipt.submitted_usec - _started_usec), str(receipt.completed_usec - _started_usec), str(Time.get_ticks_usec() - _started_usec), str(receipt.accepted), receipt.reason]))

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var ordered: Array[float] = values.duplicate()
	ordered.sort()
	return ordered[clampi(ceili(fraction * ordered.size()) - 1, 0, ordered.size() - 1)]

func _write_csv(path: String, header: String, rows: Array[PackedStringArray]) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_csv_line(header.split(","))
	for row: PackedStringArray in rows:
		file.store_csv_line(row)
	file.close()
