class_name EnduranceBenchmark
extends Node
## Bounded long-run host for the actual observer scene and worker/GPU path.
var _main: Node2D
var _access: SimulationAccess
var _logger: ObserverSessionLog
var _options: Dictionary[String, String] = {}
var _start_usec: int = 0
var _end_usec: int = 0
var _frame_times := EnduranceHistogram.new()
var _display_ages := EnduranceHistogram.new()
var _receipt_times := EnduranceHistogram.new()
var _step_times: Dictionary[String, EnduranceHistogram] = {}
var _steps: int = 0
var _first_step_sequence: int = -1
var _last_step_sequence: int = -1
var _inflight_request: int = 0
var _controls_submitted: int = 0
var _controls_received: int = 0
var _controls_rejected: int = 0
var _samples_rejected: int = 0
var _missed_worker_samples: int = 0
var _last_worker_sample: int = 0
var _budget_overruns: int = 0
var _maximum_overrun_usec: int = 0
var _output: String
var _clock_pair_usec: int = 0
var _clock_pair_unix_seconds: float = 0.0

func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var pair: PackedStringArray = argument.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2:
			_options[pair[0]] = pair[1]
	call_deferred("_run")

func _run() -> void:
	var mode: String = _options.get("endurance-mode", "natural")
	var warmup_seconds: float = float(_options.get("warmup-seconds", "30"))
	var sample_seconds: float = float(_options.get("sample-seconds", "600"))
	var smoke: bool = _options.get("endurance-smoke", "0") == "1"
	var scenario := ScenarioConfig.new()
	scenario.layout = ScenarioConfig.Layout.NATURAL
	scenario.random_seed = int(_options.get("seed", "42"))
	scenario.sheep_count = int(_options.get("sheep", "1000"))
	scenario.wolf_count = int(_options.get("wolves", "12"))
	scenario.dog_count = int(_options.get("dogs", "8"))
	var targets := PackedInt32Array([scenario.sheep_count, scenario.wolf_count, scenario.dog_count])
	var valid: bool = mode in ["natural", "turnover"] and scenario.validated_copy() != null
	valid = valid and warmup_seconds >= 1.0 and sample_seconds >= 1.0 and sample_seconds <= 3600.0
	valid = valid and _options.get("simulation", "worker") == "worker" and _options.get("motion-backend", "gpu") == "gpu"
	valid = valid and int(_options.get("worker-ai-budget-usec", "6000")) == 6000
	valid = valid and _options.get("presentation", "gpu") != "cpu" and _options.get("gpu-bulk", "1") == "1"
	valid = valid and int(_options.get("pose-samples", "0")) == 0
	valid = valid and int(_options.get("turnover-ticks", "1800")) > 0
	if not smoke:
		valid = valid and warmup_seconds == 30.0 and sample_seconds == 600.0 and targets == PackedInt32Array([1000, 12, 8])
		valid = valid and _options.get("endurance-observe", "1") == "1" and not _options.has("turnover-ticks")
	if not valid:
		push_error("Invalid endurance protocol; nonstandard durations/counts require --endurance-smoke=1.")
		get_tree().quit(1)
		return
	for name: String in ["step", "snapshot", "ai", "motion", "interaction"]:
		_step_times[name] = EnduranceHistogram.new()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var config := SimulationConfig.new()
	config.motion_backend = SimulationConfig.MotionBackend.GPU
	config.worker_ai_budget_usec = 6000
	config.instrument_enabled = false
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
	_access = _main._access
	_output = _options.get("output", "user://endurance")
	_logger = ObserverSessionLog.new()
	if not _logger.start(_access, _main._runner, _output.path_join("samples.jsonl")):
		await _abort("cannot_start_endurance_log")
		return
	_main._session_log = _logger
	_access.delivery_completed.connect(_on_delivery)
	_access.command_completed.connect(_on_receipt)
	var warmup_end: int = Time.get_ticks_usec() + int(warmup_seconds * 1000000.0)
	while Time.get_ticks_usec() < warmup_end:
		await RenderingServer.frame_post_draw
	var initial_status: Dictionary = _access.executor.endurance_status()
	var sample: Dictionary = initial_status.get("sample", {})
	var ready: bool = _access.motion_backend_status == "gpu" and not sample.is_empty()
	ready = ready and int(sample.get("pending_sheep", -1)) == 0 and int(sample.get("pending_wolves", -1)) == 0 and int(sample.get("pending_dogs", -1)) == 0
	if mode == "turnover":
		ready = ready and int(sample.get("sheep", -1)) == targets[0] and int(sample.get("wolves", -1)) == targets[1] and int(sample.get("dogs", -1)) == targets[2]
	if not ready:
		await _abort("backend_or_initial_population_not_ready")
		return
	_last_worker_sample = int(sample.get("sample_sequence", 0))
	# Both threads use the same monotonic clock. A future boundary allows the
	# owner to acknowledge the request without losing the first frontend frames.
	_start_usec = Time.get_ticks_usec() + 1000000
	_end_usec = _start_usec + int(sample_seconds * 1000000.0)
	_clock_pair_usec = Time.get_ticks_usec()
	_clock_pair_unix_seconds = Time.get_unix_time_from_system()
	if not _access.executor.arm_endurance_window(_start_usec, _end_usec):
		await _abort("cannot_arm_owner_window")
		return
	while Time.get_ticks_usec() < _start_usec:
		await RenderingServer.frame_post_draw
	var armed: Dictionary = _access.executor.endurance_status()
	if int(armed.get("start_usec", 0)) != _start_usec:
		await _abort("owner_did_not_acknowledge_window")
		return
	var first_counters: Dictionary = _access.executor.diagnostic_counters()
	var next_sample: int = _start_usec
	var next_control: int = _start_usec
	var previous_frame_usec: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() < _end_usec:
		await RenderingServer.frame_post_draw
		var now: int = Time.get_ticks_usec()
		# Include only complete frame intervals whose endpoints belong to this window.
		if now <= _end_usec:
			_frame_times.add(float(now - previous_frame_usec) / 1000.0)
			_display_ages.add(_main._runner.display_age_msec(now))
			_budget_overruns += int(_main._runner.budget_overrun_usec > 0)
			_maximum_overrun_usec = maxi(_maximum_overrun_usec, _main._runner.budget_overrun_usec)
		previous_frame_usec = now
		if now < _end_usec and now >= next_sample:
			next_sample = now + 1000000
			_append_sample(now)
		if now < _end_usec and now >= next_control and _inflight_request == 0:
			next_control = now + 1000000
			_submit_control()
	var last_counters: Dictionary = _access.executor.diagnostic_counters()
	var observed_end_usec: int = Time.get_ticks_usec()
	var owner_report: Dictionary = {}
	var drain_deadline: int = observed_end_usec + 5000000
	while (owner_report.is_empty() or _inflight_request != 0) and Time.get_ticks_usec() < drain_deadline:
		await get_tree().process_frame
		if owner_report.is_empty():
			owner_report = _access.executor.take_endurance_report()
	# Shutdown-only join/drain. Late reliable metrics are timestamp-filtered by
	# _on_delivery, so this cannot enlarge the throughput numerator or wall window.
	_access.close()
	if owner_report.is_empty():
		owner_report = _access.executor.take_endurance_report()
	var complete: bool = not owner_report.is_empty()
	complete = complete and bool(owner_report.get("valid_window", false))
	complete = complete and int(owner_report.get("steps", -1)) == _steps and int(owner_report.get("error_count", 1)) == 0
	complete = complete and int(owner_report.get("first_step_sequence", -2)) == _first_step_sequence and int(owner_report.get("last_step_sequence", -2)) == _last_step_sequence
	complete = complete and owner_report.get("motion_backend", "") == "gpu" and int(owner_report.get("ai_budget_usec", 0)) == 6000
	complete = complete and _inflight_request == 0 and _controls_rejected == 0 and _samples_rejected == 0 and _missed_worker_samples == 0
	_logger.try_append_endurance_sample({"event": "endurance_complete", "in_window": false,
		"steps": _steps, "complete_before_log_close": complete, "end_usec": _end_usec})
	_logger.close()
	var log_status: Dictionary = _logger.writer_status()
	complete = complete and not log_status["failed"] and int(log_status["dropped"]) == 0 and log_status["accepted"] == log_status["written"]
	var step_histograms: Dictionary = {}
	for name: String in _step_times:
		step_histograms[name] = _step_times[name].summary(true)
	var report: Dictionary = {"protocol": "endurance-v1", "smoke": smoke,
		"complete": complete, "mode": mode, "seed": scenario.random_seed,
		"targets": Array(targets), "warmup_seconds": warmup_seconds,
		"start_usec": _start_usec, "end_usec": _end_usec, "sample_seconds": sample_seconds,
		"frontend_end_observed_usec": observed_end_usec, "owner": owner_report,
		"clock_pair_usec": _clock_pair_usec, "clock_pair_unix_seconds": _clock_pair_unix_seconds,
		"frames": _frame_times.summary(true), "display_age": _display_ages.summary(true),
		"receipt_latency": _receipt_times.summary(true), "step_histograms": step_histograms,
		"reliable_steps": _steps, "first_step_sequence": _first_step_sequence,
		"last_step_sequence": _last_step_sequence, "worker_counters_start": first_counters,
		"worker_counters_end": last_counters, "log_status": log_status,
		"controls_submitted": _controls_submitted, "controls_received": _controls_received,
		"controls_rejected": _controls_rejected, "control_unresponded": int(_inflight_request != 0),
		"samples_rejected": _samples_rejected, "missed_worker_samples": _missed_worker_samples,
		"sample_coverage_complete": _samples_rejected == 0 and _missed_worker_samples == 0,
		"sample_coverage_scope": "Independent 1Hz owner/frontend clocks may skip a latest sample through phase drift. Such a gap fails conservative detail coverage, not reliable-step delivery; owner histograms still include the skipped observation.",
		"budget_overrun_frames": _budget_overruns, "maximum_overrun_usec": _maximum_overrun_usec,
		"engine": Engine.get_version_info(), "debug_build": OS.is_debug_build(),
		"processor": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"resolution": str(get_viewport().get_visible_rect().size), "screen_hz": DisplayServer.screen_get_refresh_rate(),
		"motion_backend": _access.motion_backend_status, "worker_ai_budget_usec": config.worker_ai_budget_usec,
		"pasture": PastureBenchmarkOptions.describe(config),
		"storage": "Fixed histogram arrays and one current sample; no per-frame/step/life CSV history in process.",
		"clock_semantics": "Frames are complete intervals inside [start,end]. Reliable steps use publication timestamps in [start,end). Receipt cohort uses submitted time; drain latency is retained separately from window throughput. Diagnostic mutex snapshots have their own read_usec endpoints.",
		"limitations": "1Hz service observations are not all-job or threat-response latency. GRAZE count is intent; actual grass food is independent. OS memory must be sampled externally. Occupied background runs do not establish clean capacity."}
	var saved: bool = _write_report(report)
	print(JSON.stringify({"protocol": "endurance-v1", "complete": complete, "steps": _steps, "output": _output}))
	_main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if complete and saved else 1)

func _on_delivery(metrics: SimulationTelemetry) -> void:
	if _start_usec == 0 or metrics.published_usec < _start_usec or metrics.published_usec >= _end_usec or metrics.step_usec <= 0:
		return
	_steps += 1
	if _first_step_sequence < 0:
		_first_step_sequence = metrics.sequence
	_last_step_sequence = metrics.sequence
	_step_times["step"].add(metrics.step_usec / 1000.0)
	_step_times["snapshot"].add(metrics.snapshot_usec / 1000.0)
	_step_times["ai"].add(metrics.ai_used_usec / 1000.0)
	_step_times["motion"].add(metrics.phase_usec[4] / 1000.0)
	_step_times["interaction"].add(metrics.phase_usec[5] / 1000.0)

func _append_sample(now: int) -> void:
	var state: Dictionary = _access.executor.endurance_status()
	var row: Dictionary = state.get("sample", {}).duplicate(true)
	var sequence: int = int(row.get("sample_sequence", 0))
	var fresh: bool = _observe_sample_sequence(sequence)
	var counters: Dictionary = _access.executor.diagnostic_counters()
	row.merge({"event": "endurance_sample", "frontend_usec": now, "unix_seconds": Time.get_unix_time_from_system(),
		"worker_sample_fresh": fresh, "worker_sample_age_usec": now - int(row.get("sample_usec", now)),
		"frames_to_date": _frame_times.count, "frame_p99_upper_ms": _frame_times.percentile(0.99)["upper"],
		"frame_max_ms": _frame_times.maximum if _frame_times.count > 0 else 0.0,
		"display_age_ms": _main._runner.display_age_msec(now),
		"worker_tick": counters["tick"], "worker_steps_total": counters["steps"],
		"worker_read_usec": counters["read_usec"], "backpressure_wait_usec": counters["backpressure_wait_usec"],
		"queue_depth": counters["queue_depth"], "queue_peak_lifetime": counters["queue_peak"],
		"backlog_seconds": _access.control_status.backlog_seconds if _access.control_status != null else 0.0,
		"diagnostic_observer_usec": state.get("observer_usec", 0)}, true)
	if not _logger.try_append_endurance_sample(row):
		_samples_rejected += 1

func _observe_sample_sequence(sequence: int) -> bool:
	if sequence <= _last_worker_sample:
		return false
	_missed_worker_samples += maxi(0, sequence - _last_worker_sample - 1)
	_last_worker_sample = sequence
	return true

func _submit_control() -> void:
	var command := SimulationCommand.new()
	command.kind = SimulationCommand.Kind.SPEED
	command.scalar = 1.0
	if _access.submit(command):
		_inflight_request = command.request_id
		_controls_submitted += 1
	else:
		_controls_rejected += 1

func _on_receipt(receipt: SimulationCommand.Receipt) -> void:
	if receipt.request_id != _inflight_request:
		return
	_inflight_request = 0
	_controls_received += 1
	_controls_rejected += int(not receipt.accepted)
	_receipt_times.add(float(Time.get_ticks_usec() - receipt.submitted_usec) / 1000.0)

func _write_report(report: Dictionary) -> bool:
	var file: FileAccess = FileAccess.open(_output.path_join("summary.json"), FileAccess.WRITE)
	if file == null:
		push_error("Cannot write endurance summary")
		return false
	file.store_string(JSON.stringify(report, "  "))
	var valid: bool = file.get_error() == OK
	file.close()
	return valid

func _abort(reason: String) -> void:
	push_error("Endurance protocol failed: " + reason)
	if _main != null:
		_main.queue_free()
		await get_tree().process_frame
	get_tree().quit(1)
