extends SceneTree
## Exercises the default worker through the real observer and rendered viewport.
var _checks: int = 0
var _failures: int = 0
var _main: Node2D
var _access: SimulationAccess

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _until(predicate: Callable, message: String) -> void:
	var deadline: int = Time.get_ticks_usec() + 5000000
	while not predicate.call() and Time.get_ticks_usec() < deadline:
		await process_frame
	_check(predicate.call(), message)

func _pointer(point: Vector2, pressed: bool) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion)
	var button := InputEventMouseButton.new()
	button.position = point
	button.global_position = point
	button.button_index = MOUSE_BUTTON_LEFT
	button.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	button.pressed = pressed
	root.push_input(button)

func _run() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node2D
	root.add_child(_main)
	current_scene = _main
	await _until(func() -> bool: return _main._access != null, "Default scene initializes")
	_access = _main._access
	_check(_main._world == null and _access.executor != null, "Default scene has no main-thread authoritative world")
	await _until(func() -> bool: return _access.tick >= 30, "Worker completes GPU simulation steps")
	_check(_access.motion_backend_status == "gpu" and _main._view.visible_count > 0, "Actual GPU publications appear on screen")
	var runner: SimulationRunner = _main._runner
	runner.request_pause(true)
	await _until(func() -> bool: return runner.paused, "Pause is acknowledged")
	var tick: int = _access.tick
	_access.queue_place(SimTypes.Species.SHEEP, Vector2(500, 450))
	runner.request_single_step()
	await _until(func() -> bool: return _access.tick == tick + 1, "Single step applies placement")
	await process_frame
	var camera: ObserverCamera = _main._camera
	var screen: Vector2 = camera.world_to_screen(Vector2(500, 442))
	var handle: AgentHandle = _main._view.pick(camera.screen_to_world(screen))
	_check(handle != null, "The placed body can be picked")
	if handle == null:
		_main.queue_free()
		await process_frame
		quit(1)
		return
	var origin: Vector2 = _access.store.position_current[_access.store.resolve(handle)]
	var zoom_before: float = camera.zoom_level
	_main._set_tool(_main.Tool.GRAB)
	_pointer(screen, true)
	for frame: int in 5:
		await process_frame
	_check(_main._grab.is_busy() and not _main._panel_open, "First grab does not expand the panel underneath the pointer")
	_check(is_equal_approx(zoom_before, camera.zoom_level), "Stationary grab preserves overview scale")
	_pointer(screen, false)
	runner.request_single_step()
	await _until(func() -> bool: return not _main._grab.is_busy(), "Drop receipt completes the grab")
	_check(origin.distance_to(_access.store.position_current[_access.store.resolve(handle)]) < 2.0, "Stationary body click preserves the foot anchor (apart from one motion step)")
	_main._select(handle)
	await _until(func() -> bool: return _access.inspect(handle) != null, "Selected inspection is published without borrowing a BT instance")
	camera.show_overview(false)
	_check(camera.follow(handle), "Follow takes over the overview animation")
	_check(not camera._animating_focus and not camera._anchored_zoom, "Follow clears incompatible camera transitions")
	for frame: int in 30:
		await process_frame
	camera.stop_follow()
	var stopped: Vector2 = camera.focus
	for frame: int in 20:
		await process_frame
	_check(camera.focus.distance_to(stopped) < 0.1, "Stopping follow does not resume an obsolete overview animation")
	var stall := SimulationCommand.new()
	stall.kind = SimulationCommand.Kind.STALL
	stall.integer = 200
	stall.scalar = 1.0
	_access.submit(stall)
	var started: int = Time.get_ticks_usec()
	var frames: int = 0
	var prior_focus: Vector2 = camera.focus
	while Time.get_ticks_usec() - started < 150000:
		camera.pan_screen(Vector2(1, 0))
		frames += 1
		await process_frame
	_check(frames >= 3 and camera.focus.distance_to(prior_focus) > 0.5, "Camera continues moving during a CPU-busy worker stall")
	await _until(func() -> bool: return not _access.has_pending_control(SimulationCommand.Kind.STALL), "Worker stall completes")
	var old_epoch: int = _access.store.epoch
	_main._reset_scenario()
	await _until(func() -> bool: return _access.store.epoch > old_epoch, "Reset replaces the publication epoch")
	_check(_main._selected == null and not _main._grab.is_busy(), "Reset clears frontend references to the old life")
	runner.request_pause(false)
	await _until(func() -> bool: return _access.tick >= 60, "Reset scene resumes with populated publications")
	_main._set_tool(_main.Tool.SELECT)
	_main._camera.show_overview(true)
	if _main._panel_open:
		_main._toggle_panel()
	_main._refresh_panel()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			var path: String = argument.trim_prefix("--capture=")
			_check(root.get_texture().get_image().save_png(path) == OK, "Screenshot saved")
	print("THREADED_PRESENTATION_TESTS checks=%d failures=%d stall_frames=%d" % [_checks, _failures, frames])
	_main.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)
