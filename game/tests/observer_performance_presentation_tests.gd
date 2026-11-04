extends SceneTree
## Actual HUD binding in both executors. This is a functional check, not a benchmark.
var _checks: int = 0
var _failures: int = 0
var _main: Node2D

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _until(predicate: Callable, message: String) -> void:
	var deadline: int = Time.get_ticks_usec() + 6000000
	while not predicate.call() and Time.get_ticks_usec() < deadline:
		await process_frame
	_check(predicate.call(), message)

func _run() -> void:
	var inline: bool = OS.get_cmdline_user_args().has("--simulation=inline")
	root.size = Vector2i(1024, 640)
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node2D
	if inline:
		_main.set_meta("inline_simulation", true)
	root.add_child(_main)
	current_scene = _main
	await _until(func() -> bool: return _main._access != null and _main._access.store.count > 0, "Scene publishes a population")
	if _main._access == null or _main._runner == null:
		_main.queue_free()
		await process_frame
		quit(1)
		return
	var access: SimulationAccess = _main._access
	var runner: SimulationRunner = _main._runner
	var readout: ObserverPerformance = _main.observer._performance
	await _until(func() -> bool: return readout.actual_speed >= 0.0, "Actual HUD receives a completed rate window")
	_check(readout.actual_speed > 0.0 and _main.hud.perf_progress.text.contains("目标 1.00×"), "Live HUD separates completed simulation rate and requested speed")
	_check(runner.has_display_sample() and _main.hud.perf_progress.text.contains("显示年龄"), "Live HUD has an actual displayed simulation endpoint")
	var handle: AgentHandle = access.store.handle_at(0)
	_main.observer.select(handle)
	await _until(func() -> bool: return access.inspect(handle) != null, "Selected-life inspection crosses the read boundary")
	_main.observer.refresh_panel()
	for frame: int in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	_check(_main.hud.perf_decision.text.contains("所选决策") and not _main.hud.stats.visible, "Selected decision service is visible without expanding debug statistics")
	_check(_main.hud.perf_card.get_global_rect().end.x < _main.hud.right_panel.get_global_rect().position.x, "Compact performance card does not cover the selected-life sidebar")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			var path: String = argument.trim_prefix("--capture=")
			_check(root.get_texture().get_image().save_png(path) == OK, "Live performance screenshot saved")
	runner.request_pause(true)
	await _until(func() -> bool: return runner.paused, "Pause reaches the executor")
	_main.observer.refresh_panel()
	_check(readout.actual_speed < 0.0 and _main.hud.perf_progress.text.contains("已冻结"), "Paused HUD clears the rate and labels the frozen display")
	var tick: int = access.tick
	runner.request_single_step()
	await _until(func() -> bool: return access.tick == tick + 1, "Single step completes")
	_main.observer.refresh_panel()
	_check(readout.actual_speed < 0.0 and _main.hud.perf_status.text.contains("不判过载"), "Single-step progress does not become an overload sample")
	var epoch: int = access.store.epoch
	_main.observer.reset_scenario()
	await _until(func() -> bool: return access.store.epoch > epoch, "Reset advances the scene epoch")
	_main.observer.refresh_panel()
	_check(readout.actual_speed < 0.0 and _main.hud.perf_decision.text.contains("选中角色"), "Reset discards the old rate and selected-life metric")
	print("OBSERVER_PERFORMANCE_PRESENTATION_TESTS mode=%s checks=%d failures=%d" % ["inline" if inline else "worker", _checks, _failures])
	_main.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)
