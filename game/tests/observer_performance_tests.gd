extends SceneTree
## Deterministic readout contracts, independent of wall-budget performance.
const Readout = preload("res://scripts/presentation/observer_performance.gd")
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _run() -> void:
	_check_rate_windows()
	_check_selected_inspection()
	_check_inline_display_clock()
	await _check_programmatic_spinbox_boundary()
	var hud: ObserverHud = preload("res://scenes/ui/observer_hud.tscn").instantiate() as ObserverHud
	root.add_child(hud)
	await process_frame
	_check(not hud.stats.visible and hud.perf_progress.visible and hud.perf_decision.visible and hud.perf_population.visible and hud.perf_status.visible, "Core service readouts stay visible while detailed statistics are collapsed")
	_check(hud.perf_progress.tooltip_text.contains("显示tick") and hud.perf_decision.tooltip_text.contains("仅所选角色"), "The scene states the rate and selected-decision measurement scopes")
	hud.free()
	print("OBSERVER_PERFORMANCE_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_rate_windows() -> void:
	var status := Readout.new()
	status.observe(1, 0, 1000000, false, 1.0, 1.0 / 60.0, 0)
	_check(status.actual_speed < 0.0, "A new world waits for a complete rate window")
	status.observe(1, 120, 3000000, false, 1.0, 1.0 / 60.0, 0)
	_check(is_equal_approx(status.actual_speed, 1.0) and not status.has_load_warning(40.0, 5.0), "Realtime completed-step throughput is independent of the frontend frame rate")
	_check(status.status_text(40.0, 5.0, 0.02).contains("意图欠服务"), "Realtime world progress cannot conceal a measured missing-intent fraction")
	status.observe(1, 180, 5000000, false, 1.0, 1.0 / 60.0, 0)
	_check(is_equal_approx(status.actual_speed, 0.5) and status.status_text(40.0, 5.0).contains("模拟欠速"), "High frontend FPS cannot conceal half-speed simulation")
	status.observe(1, 180, 5100000, false, 0.5, 1.0 / 60.0, 0)
	_check(status.actual_speed < 0.0, "Changing requested speed discards the mixed-speed window")
	status.observe(1, 240, 7100000, false, 0.5, 1.0 / 60.0, 0)
	_check(is_equal_approx(status.actual_speed, 0.5) and not status.has_load_warning(40.0, 5.0), "Half speed chosen by the observer is not overload")
	status.observe(1, 240, 7200000, true, 0.5, 1.0 / 60.0, 0)
	status.observe(1, 241, 10200000, true, 0.5, 1.0 / 60.0, 0)
	_check(status.actual_speed < 0.0 and not status.has_load_warning(4000.0, 100.0) and status.rate_text().contains("单步"), "Paused single steps do not produce a fake slow-motion rate or stale-display warning")
	status.observe(1, 241, 10300000, false, 2.0, 1.0 / 60.0, 0)
	status.observe(1, 481, 12300000, false, 2.0, 1.0 / 60.0, 0)
	_check(is_equal_approx(status.actual_speed, 2.0) and not status.has_load_warning(40.0, 5.0), "Resume starts a new window and uses the applied acceleration target")
	status.observe(2, 500, 12400000, false, 2.0, 1.0 / 60.0, 0)
	_check(status.actual_speed < 0.0, "Epoch change clears rate even when worker cumulative steps never reset")
	status.observe(2, 740, 14400000, false, 2.0, 1.0 / 60.0, 500000)
	_check(is_equal_approx(status.backpressure_fraction, 0.25) and status.status_text(40.0, 5.0).contains("可靠交付等待"), "Backpressure has its own measured cause instead of being assumed from slow AI")
	_check(status.status_text(150.0, 20.0).contains("显示滞后") and status.status_text(150.0, 20.0).contains("前端帧慢"), "Display and frontend frame delays remain separate causes")

func _check_selected_inspection() -> void:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.detached_ai = true
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 1
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	world._apply_commands()
	var access: SimulationAccess = SimulationAccess.local(world)
	var handle: AgentHandle = world.store.handle_at(0)
	_check(Readout.selected_decision_text(access, null).contains("选中角色"), "Unselected UI does not claim a global decision age")
	_check(Readout.selected_decision_text(access, handle).contains("等待首次"), "Birth's elapsed-time initializer is not presented as a completed decision")
	world.tick = 12
	var context: AgentContext = world.ai.inspect(handle)
	context.task_name = &"graze_grass"
	context.last_decision_tick = 9
	context.decision_queued = true
	var inspection: AgentInspection = access.inspect(handle)
	_check(inspection.last_decision_tick == 9, "Inspection copies the selected life's current decision service tick")
	var decision_text: String = Readout.selected_decision_text(access, handle)
	_check(decision_text.contains("50 ms") and decision_text.contains("模拟时间") and decision_text.contains("排队中"), "Decision age uses current selected tick rather than historical maximum lateness")
	world.queue_hold(handle)
	world._apply_commands()
	_check(Readout.selected_decision_text(access, handle).contains("提起"), "Held lives have an explicit suspended-service state")
	_check(Readout.intent_text(access).contains("未采样"), "Inline mode does not fabricate an unmeasured global missing-intent rate")
	var worker_access := SimulationAccess.new()
	worker_access.executor = SimulationExecutor.new()
	worker_access.publication = SimulationPublication.capture(world, handle)
	worker_access.control_status = SimulationTelemetry.new()
	worker_access.control_status.epoch = world.store.epoch
	worker_access.control_status.active_agents = 100
	worker_access.control_status.missing_intents = 2
	_check(Readout.intent_text(worker_access).contains("2 / 100（2.00%）"), "Global intent quality preserves its actual active denominator")
	worker_access.control_status.epoch -= 1
	_check(Readout.intent_text(worker_access).contains("新场景"), "Old epoch quality is not shown for a new world")
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_inline_display_clock() -> void:
	var runner := SimulationRunner.new()
	_check(not runner.has_display_sample(), "Unpublished inline state has no invented display-age sample")
	runner._inline_displayed_usec = 1000000.0
	_check(runner.has_display_sample() and is_equal_approx(runner.display_age_msec(1040000), 40.0), "Inline display age is based on completed simulation wall endpoints")
	runner.free()

func _check_programmatic_spinbox_boundary() -> void:
	var spin := SpinBox.new()
	spin.max_value = 9999
	root.add_child(spin)
	spin.value = 40
	await process_frame
	spin.value = 1000
	var text_before_apply: String = spin.get_line_edit().text
	spin.apply()
	print("SPINBOX_SYNC_PROBE " + JSON.stringify({"assigned_value": 1000, "text_before_apply": text_before_apply, "value_after_immediate_apply": spin.value}))
	spin.value = 1000
	await process_frame
	spin.apply()
	_check(spin.value == 1000, "A programmatic Range value settles before its pending text is committed")
	spin.free()
