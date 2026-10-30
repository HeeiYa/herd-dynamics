extends SceneTree
## Exercises the actual scene, runner and graphics; captures evidence after rendering.
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	var main: Node2D = scene.instantiate() as Node2D
	root.add_child(main)
	current_scene = main
	for frame: int in range(120):
		await process_frame
	var world: SimulationWorld = main._world
	var runner: SimulationRunner = main._runner
	var view: WorldPresentation = main._view
	_check(world.tick > 0 and world.store.count > 0, "Actual scene advances and populates")
	_check(view.visible_count > 0, "Presentation includes visible agents")
	runner.request_pause(true)
	await process_frame
	await process_frame
	var paused_tick: int = world.tick
	for frame: int in range(10):
		await process_frame
	_check(world.tick == paused_tick, "Pause stops the simulation clock")
	runner.request_single_step()
	await process_frame
	await process_frame
	_check(world.tick == paused_tick + 1 and runner.paused, "Single step publishes exactly one tick and stays paused")
	var prior_epoch: int = world.store.epoch
	main._reset_scenario()
	await process_frame
	await process_frame
	_check(world.tick == 0 and world.store.epoch > prior_epoch, "Reset at frame boundary advances epoch and resets clock")
	runner.request_single_step()
	await process_frame
	await process_frame
	_check(world.store.count > 0, "Paused reset applies pending spawn on single step")
	var handle: AgentHandle = world.store.handle_at(0)
	main._selected = handle
	view.set_selected(handle)
	main._refresh_panel()
	var picked: AgentHandle = view.pick(world.store.position_current[0])
	_check(picked != null and world.store.is_alive(picked), "Picking returns a live complete handle")
	await _test_observer_scene(main, world, runner, view)
	await _test_pointer_cancel_and_compact_layout(main, world, runner, view)
	runner.request_pause(false)
	for frame: int in range(4000):
		if world.tick >= 600:
			break
		await process_frame
	runner.request_pause(true)
	# Evidence uses the default layout: detail panel collapsed.
	if main._panel_open:
		main._toggle_panel()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			var path: String = argument.trim_prefix("--capture=")
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			var result: Error = root.get_texture().get_image().save_png(path)
			_check(result == OK, "Rendered screenshot saved")
			await _capture_views(main, world, view, path)
	_test_presentation_contracts()
	print("PRESENTATION_TESTS failures=%d tick=%d visible=%d" % [_failures, world.tick, view.visible_count])
	main.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)

## Real HUD, camera, grab and overlay wiring in the running scene.
func _test_observer_scene(main: Node2D, world: SimulationWorld, runner: SimulationRunner, view: WorldPresentation) -> void:
	var camera: ObserverCamera = main._camera
	var viewport: Rect2 = main.get_viewport_rect()
	var collapsed: Rect2 = camera.usable_rect()
	_check(not main._right_panel.visible, "Detail panel starts collapsed")
	var collapsed_zoom: float = camera.zoom_level
	main._toggle_panel()
	await process_frame
	await process_frame
	var usable: Rect2 = camera.usable_rect()
	_check(usable.size.x < collapsed.size.x and camera.zoom_level < collapsed_zoom, "Opening the panel shrinks and refits the pasture")
	_check(usable.size.x < viewport.size.x and usable.position.y > 0.0, "Docked panels shrink the usable pasture rectangle")
	_check(main._right_panel.get_global_rect().position.x >= usable.end.x, "Usable area does not extend under the right panel")
	# A screen point over the right panel is consumed by the GUI.
	var panel_point: Vector2 = main._right_panel.get_global_rect().get_center()
	_check(main._right_panel.mouse_filter == Control.MOUSE_FILTER_STOP and main._right_panel.get_global_rect().has_point(panel_point), "Panels stop pointer input from reaching the pasture")
	_check(main._hud.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Full-screen HUD root never swallows pasture input")

	main._toggle_ui()
	await process_frame
	_check(not main._top_bar.visible and main._restore_button.visible and camera.usable_rect().size == viewport.size, "Hiding the UI keeps a visible restore control")
	main._toggle_ui()
	await process_frame
	await process_frame
	# Picking through camera conversions selects what is drawn under the cursor.
	var dense: int = -1
	for candidate: int in world.store.count:
		if usable.has_point(camera.world_to_screen(world.store.position_current[candidate])):
			dense = candidate
			break
	_check(dense >= 0, "A body is visible in the usable area")
	if dense < 0:
		return
	var handle: AgentHandle = world.store.handle_at(dense)
	var foot: Vector2 = view.display_foot(handle)
	var screen: Vector2 = camera.world_to_screen(foot + Vector2(0, -8))
	_check(view.pick(camera.screen_to_world(screen)) != null, "Screen-space picking through the camera finds a body")
	main._select(handle)
	main._follow_selected()
	_check(camera.mode == ObserverCamera.Mode.FOLLOW, "F follows the selected life")
	main._refresh_panel()
	_check(main._inspector._summary.text.contains("原因"), "Character card explains the selected behavior")
	# Grab while paused: preview first, command applies on the next step.
	main._set_tool(main.Tool.GRAB)
	var lifted: bool = main._grab.begin(handle, foot)
	_check(lifted and world.is_hold_pending(handle) and not world.store.is_held(handle), "Paused grab is a pending preview")
	runner.request_single_step()
	await process_frame
	await process_frame
	_check(world.store.is_held(handle), "Single step applies the paused hold")
	var drop_point: Vector2 = world.config.world_size * 0.5
	main._grab.pointer_world = drop_point
	main._grab.pointer_valid = true
	main._grab.release()
	runner.request_single_step()
	await process_frame
	await process_frame
	_check(not world.store.is_held(handle) and world.store.position_previous[world.store.resolve(handle)] == drop_point, "Release drops at the previewed point on the next step")
	_check(main._grab.state == GrabTool.State.IDLE, "Grab tool returns to idle after the drop applies")
	main._set_tool(main.Tool.GRAB)
	main._grab.begin(handle, drop_point)
	main._escape()
	_check(main._grab.state == GrabTool.State.IDLE and not world.is_hold_pending(handle), "Esc withdraws a hold that has not applied yet")
	main._set_tool(main.Tool.SELECT)
	main._grab.begin(handle, drop_point)
	runner.request_single_step()
	await process_frame
	await process_frame
	var prior_epoch: int = world.store.epoch
	main._reset_scenario()
	await process_frame
	await process_frame
	_check(world.store.epoch > prior_epoch and main._grab.state == GrabTool.State.IDLE and main._selected == null, "Reset ends grab and selection")
	_check(camera.mode == ObserverCamera.Mode.OVERVIEW and camera.follow_handle == null, "Reset returns the camera to the overview")
	runner.request_single_step()
	await process_frame
	await process_frame

## Pointer input traverses the real scene, then checks a compact viewport.
func _test_pointer_cancel_and_compact_layout(main: Node2D, world: SimulationWorld, runner: SimulationRunner, view: WorldPresentation) -> void:
	var handle: AgentHandle = world.store.handle_at(0)
	var origin: Vector2 = world.store.position_current[world.store.resolve(handle)]
	var foot: Vector2 = view.display_foot(handle)
	var screen: Vector2 = main._camera.world_to_screen(foot + Vector2(0, -8))
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_G
	root.push_input(key)
	var motion := InputEventMouseMotion.new()
	motion.position = screen
	motion.global_position = screen
	root.push_input(motion)
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.button_mask = MOUSE_BUTTON_MASK_LEFT
	button.pressed = true
	button.position = screen
	button.global_position = screen
	root.push_input(button)
	_check(main._grab.state == GrabTool.State.CARRYING, "Actual pointer input starts the grab tool")
	button = button.duplicate()
	button.pressed = false
	button.button_mask = 0
	button.position += Vector2(40, 30)
	button.global_position = button.position
	root.push_input(button)
	_check(main._grab.state == GrabTool.State.DROP_PENDING, "Actual pointer release leaves a paused drop pending")
	key = key.duplicate()
	key.keycode = KEY_ESCAPE
	root.push_input(key)
	_check(main._grab.state == GrabTool.State.IDLE and not world.has_pending_observer_commands(), "Esc through the scene cancels the paused drop")
	runner.request_single_step()
	await process_frame
	await process_frame
	_check(world.store.position_previous[world.store.resolve(handle)] == origin, "A cancelled pointer drop does not teleport on the next step")
	var original_size: Vector2i = root.size
	root.size = Vector2i(1024, 640)
	for frame: int in 4:
		await process_frame
	_check(main._top_bar.get_global_rect().end.x <= root.get_visible_rect().size.x + 1.0, "Top bar controls fit the compact window")
	_check(main._camera.usable_rect().size.x > 400.0, "Compact window keeps a useful pasture area with the panel open")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(argument.trim_prefix("--capture=").get_basename() + "-compact.png")
	root.size = original_size
	for frame: int in 4:
		await process_frame

## Extra evidence images next to --capture: selected follow view and hidden UI.
func _capture_views(main: Node2D, world: SimulationWorld, view: WorldPresentation, path: String) -> void:
	var wolf: AgentHandle
	for dense: int in world.store.count:
		if world.store.species[dense] == SimTypes.Species.WOLF and world.store.held[dense] == 0:
			wolf = world.store.handle_at(dense)
			break
	if wolf != null:
		main._select(wolf)
		main._overlay_buttons[&"perception"].button_pressed = true
		main._sync_overlays()
		main._follow_selected()
		main._camera.zoom_at(main._camera.usable_rect().get_center(), 2)
		main._refresh_panel()
		for frame: int in 90:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(path.get_basename() + "-follow.png")
	main._tabs.current_tab = 1
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path.get_basename() + "-tuning.png")
	main._tabs.current_tab = 0
	main._camera.show_overview(true)
	main._toggle_ui()
	for frame: int in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path.get_basename() + "-clean.png")
	main._toggle_ui()
	# A thousand-body natural pasture, paused after its initial spread.
	main._layout.select(main._layout.get_item_index(ScenarioConfig.Layout.NATURAL))
	main._sheep.value = 1000
	main._wolves.value = 12
	main._dogs.value = 6
	main._reset_scenario()
	# The reset applies on the next frame; do not read the old tick.
	await process_frame
	await process_frame
	main._runner.request_pause(false)
	for frame: int in 600:
		if world.tick >= 240:
			break
		await process_frame
	main._runner.request_pause(true)
	for frame: int in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	_check(world.store.count == 1018, "Thousand-body natural layout spawns completely")
	root.get_texture().get_image().save_png(path.get_basename() + "-thousand.png")

func _test_presentation_contracts() -> void:
	var catalog := AnimationCatalog.new()
	catalog.load_assets()
	_check(catalog.clips.size() == 184, "All 23 actions and eight directions are loaded")
	for clip_index: int in catalog.clips.size():
		var clip: AnimationCatalog.Clip = catalog.clips[clip_index]
		var direction: int = clip_index % 8
		var expected_pivot: Vector2 = Vector2(19, 34) if direction in [3, 4, 5] else Vector2(20, 34)
		_check(clip.pivot == expected_pivot, "Mirrored directions retain their authored one-pixel pivot")
		_check(clip.frame_at(-1.0) == clip.rectangles[0], "Negative display time clamps to the first frame")
		for frame_index: int in range(clip.rectangles.size() - 1):
			var boundary: float = clip.cumulative_ms[frame_index]
			_check(clip.frame_at(boundary - 0.001) == clip.rectangles[frame_index], "Variable-duration frame owns the instant before its boundary")
			_check(clip.frame_at(boundary) == clip.rectangles[frame_index + 1], "Exact millisecond boundary advances to the next frame")
		if clip.loop:
			_check(clip.frame_at(clip.duration_ms) == clip.rectangles[0], "Loop wraps exactly at authored duration")
		else:
			_check(clip.frame_at(clip.duration_ms + 10000.0) == clip.rectangles.back(), "Non-loop animation holds its last frame")
	_test_direction_and_capture_lifetimes()
	_test_mixed_species_order()
	_test_incremental_order()
	_test_resume_interpolation()

func _test_resume_interpolation() -> void:
	var config := SimulationConfig.new()
	config.max_catchup_steps = 1
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	var view := WorldPresentation.new()
	root.add_child(view)
	view.hide()
	view.setup(world.store, world.intents, world.resources, config)
	var runner := SimulationRunner.new()
	root.add_child(runner)
	runner.set_process(false)
	runner.setup(world, view)
	# The fixture supplies one moving interval without involving AI scheduling.
	var sheep: AgentHandle = world.store.create_agent(SimTypes.Species.SHEEP, Vector2(200, 200))
	world.store.position_previous[0] = Vector2(199, 200)
	world.store.velocity_current[0] = Vector2(60, 0)
	var intent := MotionIntent.new()
	intent.mode = SimTypes.IntentMode.MOVE
	intent.behavior = SimTypes.Behavior.SEARCH
	intent.destination = Vector2(600, 200)
	intent.speed = 60.0
	intent.expires_tick = 1000
	world.intents.write(sheep, intent)
	world.tick = 10
	runner.paused = true
	runner.accumulator_seconds = config.fixed_dt * 0.25
	runner._process(0.0)
	var paused_foot: Vector2 = view._states[sheep.slot].drawing.foot
	runner.request_pause(false)
	runner._process(0.0)
	_check(world.tick == 10 and view._states[sheep.slot].drawing.foot == paused_foot, "Resume without a publication does not rewind the last paused position")
	runner.request_pause(false)
	runner._process(0.0)
	_check(world.tick == 10 and view._states[sheep.slot].drawing.foot == paused_foot, "Repeated resume commands preserve the held current position")
	# Supply a known amount of time; normal interpolation resumes on publication.
	runner.accumulator_seconds = config.fixed_dt * 1.25
	runner._last_usec = Time.get_ticks_usec()
	runner._process(0.0)
	var resumed_foot: Vector2 = view._states[sheep.slot].drawing.foot
	_check(world.tick == 11 and resumed_foot.x >= paused_foot.x, "First publication after resume continues forward from the paused position")
	_check(resumed_foot.x < world.store.position_current[0].x, "Resume returns to ordinary interpolation after the next publication")
	runner.request_single_step()
	runner._process(0.0)
	var stepped_tick: int = world.tick
	var stepped_foot: Vector2 = view._states[sheep.slot].drawing.foot
	runner.request_pause(false)
	runner._process(0.0)
	_check(world.tick == stepped_tick and view._states[sheep.slot].drawing.foot == stepped_foot, "Resuming after single-step does not rewind its directly displayed result")
	var previous_epoch: int = world.store.epoch
	for reset_index: int in range(2):
		runner.request_reset(scenario)
		runner._process(0.0)
	_check(world.tick == 0 and world.store.epoch == previous_epoch + 2 and view._draw_list.is_empty(), "Consecutive resets clear the held resume display and old-life drawings")
	runner.queue_free()
	view.queue_free()
	world.queue_free()

func _test_direction_and_capture_lifetimes() -> void:
	var config := SimulationConfig.new()
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	var resources := ResourceGrid.new(config)
	var view := WorldPresentation.new()
	root.add_child(view)
	view.hide()
	view.setup(store, intents, resources, config)
	view.set_seed(917)
	var sheep: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(200, 200))
	var grazing := MotionIntent.new()
	grazing.behavior = SimTypes.Behavior.GRAZE
	grazing.mode = SimTypes.IntentMode.GRAZE
	grazing.expires_tick = 500
	intents.write(sheep, grazing)
	view.present(0, 0.0, true)
	var state: WorldPresentation.AnimationState = view._states[sheep.slot]
	var started_tick: int = state.started_tick
	var phase_ms: float = state.phase_ms
	store.facing[0] = Vector2.DOWN
	view.observe_published(31)
	view.present(31, 0.5)
	_check(state.direction == 0, "Future direction remains pending until display time reaches its publication")
	view.present(31, 1.0, true)
	_check(state.direction == 2, "Eight-direction transition becomes visible at its timestamp")
	_check(state.started_tick == started_tick and state.phase_ms == phase_ms, "Direction change preserves action clock and random phase")
	view.set_selected(sheep)
	view.add_capture(sheep, Vector2(210, 200), Vector2.DOWN, 32)
	var copied_position: Vector2 = view._captures[0].position
	store.remove_agent(sheep)
	intents.remove(sheep)
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(350, 250))
	_check(replacement.slot == sheep.slot and not replacement.same_life(sheep), "Test actually exercises a recycled slot with a new generation")
	view.present(32, 0.5)
	_check(view._captures.size() == 1, "Captured visual survives lifecycle recycling")
	_check(view._captures[0].position == copied_position, "Recycled actor cannot move the copied death visual")
	_check(view._captures[0].handle.same_life(sheep), "Capture keeps the retired full identity")
	_check(view._states[replacement.slot].handle.same_life(replacement), "Animation state is rebound only to the new full identity")
	_check(view.selected_handle == null, "Dead selection clears rather than selecting a recycled slot")
	var visual: WorldPresentation.CaptureVisual = view._captures[0]
	var prior_clip: AnimationCatalog.Clip = view._catalog.get_clip(visual.previous_action, visual.previous_direction)
	var prior_ms: float = (31.5 - visual.previous_started_tick) * config.fixed_dt * 1000.0 + visual.previous_phase_ms
	_check(visual.drawing.region == prior_clip.frame_at(prior_ms), "Capture event does not switch animation before its display timestamp")
	view.present(32, 1.0, true)
	var captured_clip: AnimationCatalog.Clip = view._catalog.get_clip(AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction)
	_check(visual.drawing.region == captured_clip.rectangles[0], "Capture begins on the first authored frame at the event tick")
	view.present(200, 1.0, true)
	_check(view._captures.is_empty(), "Capture visual naturally expires without resurrecting an agent")
	view.add_capture(replacement, Vector2(350, 250), Vector2.RIGHT, 201)
	store.reset()
	intents.clear()
	view.present(0, 0.0, true)
	_check(view._captures.is_empty() and view.selected_handle == null, "Epoch reset clears old visual records and selection")
	view.queue_free()

func _test_mixed_species_order() -> void:
	var config := SimulationConfig.new()
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	var resources := ResourceGrid.new(config)
	var view := WorldPresentation.new()
	root.add_child(view)
	view.hide()
	view.setup(store, intents, resources, config)
	store.create_agent(SimTypes.Species.SHEEP, Vector2(200, 201))
	store.create_agent(SimTypes.Species.WOLF, Vector2(200, 200))
	var dog: AgentHandle = store.create_agent(SimTypes.Species.DOG, Vector2(200, 202))
	view.present(0, 0.0, true)
	_check(view._draw_list.size() == 3, "Mixed-species ordering scenario remains inside the viewport")
	for index: int in range(1, view._draw_list.size()):
		_check(view._draw_list[index - 1].foot.y <= view._draw_list[index].foot.y, "All species share ascending foot-Y order")
	var picked: AgentHandle = view.pick(Vector2(200, 202))
	_check(picked != null and picked.same_life(dog), "Picking checks the reverse global body order")
	view.queue_free()

func _test_incremental_order() -> void:
	var view := WorldPresentation.new()
	view._config = SimulationConfig.new()
	var entries: Array[WorldPresentation.DrawEntry] = []
	for index: int in 1000:
		var entry := WorldPresentation.DrawEntry.new()
		entry.handle = AgentHandle.new(index % 500, index / 500, 1)
		entry.is_capture = index >= 500
		entries.append(entry)
	var fallback_count: int = 0
	var samples: Array[Dictionary] = []
	for frame: int in 120:
		# Cover both near-continuous movement and adversarial reversals, ties,
		# disappearing/reappearing drawings, retired lives and backend switches.
		view._config.incremental_render_sort = frame != 60
		var expected: Array[WorldPresentation.DrawEntry] = []
		var started: int = Time.get_ticks_usec()
		view._begin_draw_list()
		for index: int in entries.size():
			var entry: WorldPresentation.DrawEntry = entries[index]
			entry.foot = Vector2(0, float(index / 3) + sin(frame * 0.1 + index) * 0.4)
			if frame % 30 == 29:
				entry.foot.y = -index
			if (index + frame) % 17 == 0:
				continue
			view._queue_drawing(entry)
			expected.append(entry)
		view._finish_draw_list()
		var elapsed: int = Time.get_ticks_usec() - started
		expected.sort_custom(WorldPresentation._draw_before)
		_check(view._draw_list == expected, "Incremental order matches full sorting after membership changes and crossings")
		_check(view.sort_moves <= maxi(32, expected.size() * 4), "Repair work stays bounded before fallback")
		if view.sort_used_fallback:
			fallback_count += 1
		samples.append({"frame": frame, "usec": elapsed, "moves": view.sort_moves, "fallback": view.sort_used_fallback})
		if frame == 90:
			view._reset_draw_list()
			_check(view._draw_list.is_empty(), "Reset drops all cached drawing membership")
	_check(fallback_count > 0, "Adversarial crossings exercise full-sort fallback")
	view._reset_draw_list()
	for entry: WorldPresentation.DrawEntry in entries:
		_check(not entry.listed, "Removed drawings retain no list membership")
	view.free()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--sort-results="):
			var file: FileAccess = FileAccess.open(argument.trim_prefix("--sort-results="), FileAccess.WRITE)
			file.store_string(JSON.stringify({"debug_build": OS.is_debug_build(), "samples": samples}, "  "))
