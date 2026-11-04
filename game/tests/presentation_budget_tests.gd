extends SceneTree
## Back-frame preparation must be interruptible and leave the rendered front
## frame, picking rectangles and GPU instances unchanged until one commit.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _finish(job: PresentationJob) -> int:
	var slices: int = 0
	while job.phase != PresentationJob.Phase.READY and slices < 1000:
		job.advance(Time.get_ticks_usec() + 100)
		slices += 1
	_check(slices < 1000, "Bounded preparation makes progress through every phase")
	return slices

func _run() -> void:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.detached_ai = true
	config.gpu_presentation = true
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 1000
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	for step: int in 16:
		world.ai.begin_frame()
		world.step()
	var view := WorldPresentation.new()
	root.add_child(view)
	view.setup(world.store, world.intents, world.resources, config)
	view.set_seed(scenario.random_seed)
	view.present(world.tick, 0.5)
	await process_frame
	await RenderingServer.frame_post_draw
	var reference: Image = root.get_texture().get_image()
	var executor := SimulationExecutor.new()
	executor._publish(world, 1)
	var snapshot: SimulationPublication = executor._latest
	var front_entry: WorldPresentation.DrawEntry = view._draw_list[0]
	var front_foot: Vector2 = front_entry.foot
	var front_buffer: PackedFloat32Array = view.instance_animator()._instances.buffer
	var job := PresentationJob.new()
	job.begin(view, snapshot, 0.5, false)
	job.advance(Time.get_ticks_usec())
	_check(job.phase == PresentationJob.Phase.BODIES, "An expired deadline starts no preparation work")
	var slices: int = _finish(job)
	_check(slices > 1, "Thousand-body preparation is split across cooperative slices")
	_check(view._draw_list[0] == front_entry and front_entry.foot == front_foot, "Back preparation cannot mutate displayed picking geometry")
	_check(view.instance_animator()._instances.buffer == front_buffer, "Back packing cannot submit a partial GPU frame")
	for index: int in range(1, job.drawings.size()):
		_check(not WorldPresentation._draw_before(job.drawings[index], job.drawings[index - 1]), "Resumable merge preserves the full stable draw key")
	view.commit_job(job)
	await process_frame
	await RenderingServer.frame_post_draw
	var actual: Image = root.get_texture().get_image()
	_check(actual.get_data() == reference.get_data(), "Segmented frame is pixel-identical to the existing renderer at the same display time")
	var retained: WorldPresentation.DrawEntry = view._draw_list[0]
	var retained_foot: Vector2 = retained.foot
	for dense: int in world.store.count:
		world.store.position_current[dense].y = config.world_size.y - world.store.position_current[dense].y
	world.tick += 1
	executor._publish(world, 1)
	var second := PresentationJob.new()
	second.begin(view, executor._latest, 1.0, true)
	_finish(second)
	_check(retained.foot == retained_foot, "A second back bank cannot alter the first committed frame")
	for index: int in range(1, second.drawings.size()):
		_check(not WorldPresentation._draw_before(second.drawings[index], second.drawings[index - 1]), "Adversarial reversed Y order also completes correctly")
	view.commit_job(second)
	_check(view._store == second.source.store and view.display_tick == second.display_tick, "State and geometry switch together at commit")
	var second_front_foot: Vector2 = view._draw_list[0].foot
	job.begin(view, second.source, 0.0, false)
	_check(job.display_tick == view.display_tick and job.alpha == 1.0, "Rapid same-tick resume cannot rewind an already displayed completed interval")
	_finish(job)
	_check(job.drawings.size() == second.drawings.size(), "Reusing a retired bank does not duplicate retained draw entries")
	_check(view._draw_list[0].foot == second_front_foot, "Reusing a retired bank leaves the current bank immutable")
	for index: int in range(1, job.drawings.size()):
		_check(not WorldPresentation._draw_before(job.drawings[index], job.drawings[index - 1]), "Incremental repair retains the complete draw order")
	var future := CaptureEvent.new()
	future.target = snapshot.poses[0].handle
	future.tick = second.source.tick + 20
	view.queue_reliable_capture(future, snapshot.poses[0])
	_check(view.reliable_captures(second.source, second.display_tick).is_empty(), "Future capture facts do not duplicate a still-live body in an older frame")
	_check(view._reliable_captures.size() == 1, "Future capture waits for a compatible display state")
	var expired := SimulationPublication.new()
	expired.epoch = second.source.epoch
	expired.tick = future.tick + 300
	expired.config = config
	expired.scenario = scenario
	_check(view.reliable_captures(expired, expired.tick).is_empty(), "Late reliable facts do not resurrect an already expired visual")
	world.motion.close()
	world.ai.reset()
	world.free()
	view.queue_free()
	await process_frame
	print("PRESENTATION_BUDGET_TESTS checks=%d failures=%d slices=%d" % [_checks, _failures, slices])
	quit(0 if _failures == 0 else 1)
