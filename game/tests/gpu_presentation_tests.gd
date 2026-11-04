extends SceneTree
## Same published state, two render paths. Pixels verify frame lookup and order,
## including all authored clips, transparent overlap, fade and slot recycling.
var _checks: int = 0
var _failures: int = 0
var _output: String

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_output = argument.trim_prefix("--capture=").get_basename()
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _image(view: WorldPresentation, gpu: bool, tick: int = 1, alpha: float = 1.0, direct: bool = true) -> Image:
	view._config.gpu_presentation = gpu
	view.present(tick, alpha, direct)
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _compare(cpu: Image, gpu: Image, sample: int) -> Dictionary:
	var left: PackedByteArray = cpu.get_data()
	var right: PackedByteArray = gpu.get_data()
	var differing: int = 0
	var maximum_error: int = 0
	for index: int in left.size():
		var error: int = absi(int(left[index]) - int(right[index]))
		maximum_error = maxi(maximum_error, error)
		if error > 1:
			differing += 1
	_check(differing == 0, "GPU pixels match CPU clips/order/fade at sample %d (channels=%d, max=%d)" % [sample, differing, maximum_error])
	if differing > 0 and not _output.is_empty():
		cpu.save_png(_output + "-%d-cpu.png" % sample)
		gpu.save_png(_output + "-%d-gpu.png" % sample)
	return {"sample": sample, "differing_channels_gt1": differing, "maximum_error": maximum_error}

func _run() -> void:
	root.size = Vector2i(1280, 800)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var config := SimulationConfig.new()
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	var view := WorldPresentation.new()
	root.add_child(view)
	view.setup(store, intents, ResourceGrid.new(config), config)
	for clip: int in view._catalog.clips.size():
		store.create_agent(clip / 64 % 3, Vector2(40 + clip % 20 * 60, 70 + clip / 20 * 60))
	# Last bodies overlap in reverse species order and include identical Y ties.
	for index: int in range(store.count - 12, store.count):
		store.position_current[index] = Vector2(350 + index % 3 * 7, 690 + index % 2)
	view.observe_published(1)
	var comparisons: Array[Dictionary] = []
	for sample: int in 21:
		for index: int in store.count:
			var state: WorldPresentation.AnimationState = view._states[store.handle_at(index).slot]
			state.action = index / 8
			state.direction = index % 8
			state.started_tick = 1
			var clip: AnimationCatalog.Clip = view._catalog.clips[index]
			var boundary: int = clip.cumulative_ms[sample % clip.cumulative_ms.size()]
			state.phase_ms = boundary + [-0.001, 0.0, 0.001][sample % 3]
			if sample >= 12:
				state.phase_ms += clip.duration_ms * 1000000.0
			if sample >= 18:
				state.phase_ms = [-100.0, 0.0, 0.001][sample - 18]
			state.drawing.tint.a = 0.5 if index % 3 == 0 else 1.0
		var cpu: Image = await _image(view, false)
		var gpu: Image = await _image(view, true)
		comparisons.append(_compare(cpu, gpu, sample))
		if sample == 0 and not _output.is_empty():
			cpu.save_png(_output + "-cpu.png")
			gpu.save_png(_output + "-gpu.png")
		for entry: WorldPresentation.DrawEntry in view._draw_list:
			_check(view.pick(entry.foot - Vector2(0, 8)) != null, "GPU path retains CPU picking bounds")
	# A retired capture must keep its own clip/identity while its slot is reused.
	var retired: AgentHandle = store.handle_at(0)
	view.add_capture(retired, Vector2(200, 200), Vector2.RIGHT, 1)
	store.remove_agent(retired)
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(400, 200))
	_check(replacement.slot == retired.slot and not replacement.same_life(retired), "Fixture reuses a retired slot")
	view.observe_published(2)
	view.present(2, 0.5)
	_check(view._captures[0].drawing.handle.same_life(retired), "Capture owns retired identity")
	var cpu_capture: Image = await _image(view, false, 2, 0.5, false)
	var gpu_capture: Image = await _image(view, true, 2, 0.5, false)
	comparisons.append(_compare(cpu_capture, gpu_capture, 21))
	# Rewind only the presentation fixture to test the previous-action interval.
	comparisons.append(_compare(await _image(view, false, 1, 0.5, false), await _image(view, true, 1, 0.5, false), 22))
	store.reset()
	view.present(0, 0.0, true)
	_check(view._instance_animator.bodies.multimesh.visible_instance_count == 0, "Reset clears GPU visibility")
	if not _output.is_empty():
		var file := FileAccess.open(_output + "-pixels.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(comparisons, "  "))
	view.queue_free()
	await process_frame
	print("GPU_PRESENTATION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
