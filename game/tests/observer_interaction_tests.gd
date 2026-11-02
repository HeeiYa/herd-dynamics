extends SceneTree
## Real viewport input covers first-grab layout and interrupted camera transitions.
var _checks: int = 0
var _failures: int = 0

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
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node2D
	root.add_child(main)
	current_scene = main
	await _until(func() -> bool: return main._world != null, "Scene initializes")
	var world: SimulationWorld = main._world
	var runner: SimulationRunner = main._runner
	await _until(func() -> bool: return world.tick >= 30, "Simulation starts")
	runner.request_pause(true)
	await _until(func() -> bool: return runner.paused, "Pause applies")
	var tick: int = world.tick
	world.queue_place(SimTypes.Species.SHEEP, Vector2(500, 450))
	runner.request_single_step()
	await _until(func() -> bool: return world.tick == tick + 1, "Single step applies placement")
	await process_frame
	var camera: ObserverCamera = main._camera
	var screen: Vector2 = camera.world_to_screen(Vector2(500, 442))
	var handle: AgentHandle = main._view.pick(camera.screen_to_world(screen))
	_check(handle != null, "Placed body can be picked")
	if handle == null:
		main.queue_free()
		await process_frame
		quit(1)
		return
	var origin: Vector2 = world.store.position_current[world.store.resolve(handle)]
	var zoom_before: float = camera.zoom_level
	main.observer.set_tool(main.observer.Tool.GRAB)
	_pointer(screen, true)
	for frame: int in 5:
		await process_frame
	_check(main._grab.is_busy() and not main.hud.panel_open, "First grab keeps the panel closed")
	_check(is_equal_approx(zoom_before, camera.zoom_level), "Stationary grab preserves overview scale")
	_pointer(screen, false)
	runner.request_single_step()
	await _until(func() -> bool: return not main._grab.is_busy(), "Drop completes")
	_check(origin.distance_to(world.store.position_current[world.store.resolve(handle)]) < 2.0, "Stationary body click preserves the foot anchor")
	main.observer.select(handle)
	camera.show_overview(false)
	_check(camera.follow(handle), "Follow interrupts overview")
	_check(not camera._animating_focus and not camera._anchored_zoom, "Follow clears incompatible camera transitions")
	for frame: int in 30:
		await process_frame
	camera.stop_follow()
	var stopped: Vector2 = camera.focus
	for frame: int in 20:
		await process_frame
	_check(camera.focus.distance_to(stopped) < 0.1, "Stopping follow does not resume obsolete overview movement")
	print("OBSERVER_INTERACTION_TESTS checks=%d failures=%d" % [_checks, _failures])
	main.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)
