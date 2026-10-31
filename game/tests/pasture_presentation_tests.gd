extends SceneTree
## Reset through the actual panel while paused, carrying and following a life.
var _checks: int = 0
var _failures: int = 0
var _main: Node2D
var _source: SimulationAccess

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

func _run() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node2D
	root.add_child(_main)
	current_scene = _main
	await _until(func() -> bool: return _main._access != null, "Scene services initialize")
	_source = _main._access
	await _until(func() -> bool: return _source.tick >= 30, "Simulation starts")
	var runner: SimulationRunner = _main._runner
	runner.request_pause(true)
	await _until(func() -> bool: return runner.paused, "Pause acknowledged")
	var handle: AgentHandle = _source.store.handle_at(0)
	_main.observer.select(handle)
	_main.observer.follow_selected()
	_check(_main._camera.mode == ObserverCamera.Mode.FOLLOW, "Follow starts before geometry changes")
	_main._grab.begin(handle, _main._view.display_foot(handle))
	var before: int = _source.tick
	runner.request_single_step()
	await _until(func() -> bool: return _source.tick == before + 1, "Hold applies on single step")
	_check(_source.store.is_held(handle), "The selected life is held before reset")
	var epoch: int = _source.store.epoch
	await _regenerate(Vector2(3200, 2000), 40.0, 0.2)
	_check(_source.store.epoch == epoch + 1 and not _source.store.is_alive(handle), "Generation invalidates old complete identities")
	_check(not _main._grab.is_busy() and _main.observer._selected == null, "Generation clears carry and selection")
	_check(_main._camera.mode == ObserverCamera.Mode.OVERVIEW, "Generation stops follow and refits the overview")
	var amount: float = _source.resources.get_effective_amount(0, _source.tick)
	for frame: int in 10:
		await process_frame
	_check(_source.tick == 0 and is_equal_approx(_source.resources.get_effective_amount(0, 0), amount), "Paused generation does not advance grass recovery")
	await _capture("large")
	# Upper bounds, clipped boundary cells, then shrink: exercise storage lifecycle.
	await _regenerate(Vector2(6400, 4000), 160.0, 0.9)
	runner.request_pause(false)
	await _until(func() -> bool: return _source.tick >= 20, "Large regenerated world resumes simulation")
	runner.request_pause(true)
	await _until(func() -> bool: return runner.paused, "Second pause acknowledged")
	await _regenerate(Vector2(803, 487), 80.0, 0.4)
	runner.request_single_step()
	await _until(func() -> bool: return _source.tick == 1, "Shrunk world supports single step")
	_check(_source.store.count == 46, "Population is regenerated once")
	await _capture("cropped")
	_source.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.GRASS_RECOVERY, 0.005))
	_source.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.GRAZING_SPEED, 0.5))
	runner.set_speed(2.0)
	runner.request_pause(false)
	# Several seconds of actual BT/food/motion, without editing displayed grass.
	var deadline: int = Time.get_ticks_usec() + 16000000
	while _source.tick < 900 and Time.get_ticks_usec() < deadline:
		await process_frame
	_check(_source.tick >= 900, "Ecological scene advances fifteen simulated seconds")
	runner.request_pause(true)
	await _until(func() -> bool: return runner.paused, "Ecological evidence is paused")
	var depleted: int = 0
	for cell: int in _source.resources.cell_count:
		if _source.resources.get_effective_amount(cell, _source.tick) < 0.3:
			depleted += 1
	_check(depleted > 0, "Actual eating produces visible depleted cells")
	_main.observer.refresh_panel()
	await _capture("grazed")
	print("PASTURE_PRESENTATION_TESTS checks=%d failures=%d" % [_checks, _failures])
	_main.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)

func _regenerate(size: Vector2, cell_size: float, coverage: float) -> void:
	var epoch: int = _source.store.epoch
	var panel: TuningPanel = _main.hud.tuning
	var draft: PastureSettings = PastureSettings.from_config(_source.config)
	draft.world_size = size
	draft.grass_cell_size = cell_size
	draft.initial_coverage = coverage
	panel.apply_generation_draft(draft)
	_check(_source.config.world_size != size, "Draft leaves current geometry unchanged")
	_main.hud.sheep.value = 40
	_main.hud.wolves.value = 4
	_main.hud.dogs.value = 2
	panel.regeneration_requested.emit()
	await _until(func() -> bool: return _source.store.epoch > epoch, "Generation command acknowledged")
	await process_frame
	_check(_source.config.world_size == size and _main._camera._world_size == size, "Simulation and camera adopt the same bounds")
	var ground: GroundLayer = _main._view._ground
	_check(ground._world_size == size and ground._image.get_size() == Vector2i(ceili(size.x / cell_size), ceili(size.y / cell_size)), "One texture texel represents each resource cell including cropped edges")
	_check(_source.resources.columns == ceili(size.x / cell_size), "Published resources use the new resolution")
	_check(panel.generation_draft().world_size == size, "Panel acknowledgement retains applied generation values")

func _capture(suffix: String) -> void:
	if not _main.hud.panel_open:
		_main.hud.toggle_panel()
	_main.hud.tabs.current_tab = 1
	await process_frame
	var scroll: ScrollContainer = _main.hud.tabs.get_node("参数") as ScrollContainer
	if suffix == "grazed":
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
	else:
		scroll.ensure_control_visible(_main.hud.tuning._rows[TuningCatalog.Param.WORLD_WIDTH].slider)
	await process_frame
	await RenderingServer.frame_post_draw
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			var path: String = argument.trim_prefix("--capture=").get_basename() + "-" + suffix + ".png"
			_check(root.get_texture().get_image().save_png(path) == OK, "Screenshot saved")
