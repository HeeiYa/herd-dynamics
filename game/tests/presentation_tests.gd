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
	runner.request_pause(false)
	for frame: int in range(4000):
		if world.tick >= 600:
			break
		await process_frame
	runner.request_pause(true)
	await process_frame
	await RenderingServer.frame_post_draw
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			var path: String = argument.trim_prefix("--capture=")
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			var result: Error = root.get_texture().get_image().save_png(path)
			_check(result == OK, "Rendered screenshot saved")
	_test_presentation_contracts()
	print("PRESENTATION_TESTS failures=%d tick=%d visible=%d" % [_failures, world.tick, view.visible_count])
	main.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)

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
