extends SceneTree
## Visual cues consume published intent facts and never change simulation rules.
var _checks: int = 0
var _failures: int = 0
var _capture_base: String = ""
var _catalog := AnimationCatalog.new()

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_capture_base = argument.trim_prefix("--capture=").get_basename()
	call_deferred(&"_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _intent(behavior: int, mode: int, token: int) -> MotionIntent:
	var intent := MotionIntent.new()
	intent.behavior = behavior
	intent.mode = mode
	intent.owner_token = token
	intent.expires_tick = 10000
	return intent

func _run() -> void:
	root.size = Vector2i(1280, 800)
	_catalog.load_assets()
	_test_pose_edges()
	_test_visual_clocks()
	await _test_publication_and_capture()
	if DisplayServer.get_name() != "headless":
		await _test_pixels()
	print("BEHAVIOR_TRANSITION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_pose_edges() -> void:
	var history := PublishedPose.History.new()
	var life := AgentHandle.new(7, 1, 3)
	var calm: MotionIntent = _intent(SimTypes.Behavior.GRAZE, SimTypes.IntentMode.GRAZE, 1)
	var flee: MotionIntent = _intent(SimTypes.Behavior.FLEE, SimTypes.IntentMode.MOVE, 2)
	var previous: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, calm, false, Vector2.RIGHT, 1, null, history)
	_check(previous.cue_action == -1, "A newly observed life does not invent an earlier transition")
	var startled: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, flee, true, Vector2.RIGHT, 2, previous, history)
	_check(startled.action == AnimationCatalog.Action.SHEEP_FLEE and startled.cue_action == AnimationCatalog.Action.SHEEP_STARTLE and startled.cue_started_tick == 1, "Flee keeps its base action and receives one cue at the n-1 intent boundary")
	flee.expires_tick += 100
	var renewed: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, flee, true, Vector2.RIGHT, 3, startled, history)
	_check(renewed == startled, "Same-token renewal keeps the immutable pose and cue clock")
	var turned: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, flee, true, Vector2.DOWN, 4, renewed, history)
	_check(turned.cue_started_tick == 1 and turned.started_tick == startled.started_tick and turned.direction_tick == 4, "Turning preserves both clocks and keeps the original direction boundary")
	var lost: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, null, false, Vector2.DOWN, 5, turned, history)
	_check(lost.cue_action == -1 and lost.cue_started_tick == 0 and lost.cue_owner_token == 0, "Missing intent clears the cue without claiming recovery")
	var after_gap: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, flee, true, Vector2.RIGHT, 6, lost, history)
	_check(after_gap.cue_action == -1 and after_gap.has_intent, "Restoring an intent after a missing interval does not invent a previous calm state")
	var recovered: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, calm, false, Vector2.RIGHT, 5, turned, history)
	_check(recovered.cue_action == AnimationCatalog.Action.SHEEP_RECOVER, "A valid calm stationary intent can recover from fleeing")
	var interrupted: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, flee, true, Vector2.RIGHT, 6, recovered, history)
	_check(interrupted.cue_action == AnimationCatalog.Action.SHEEP_STARTLE and interrupted.cue_started_tick == 5, "Renewed danger immediately replaces a recovery cue")
	var resumed: MotionIntent = _intent(SimTypes.Behavior.FLEE, SimTypes.IntentMode.MOVE, 90)
	var cancelled: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, resumed, true, Vector2.RIGHT, 7, interrupted, history)
	_check(cancelled.cue_action == -1, "A new task token cancels an old cue without replaying the same behavior edge")
	resumed.owner_token = 91
	_check(PublishedPose.sample(life, SimTypes.Species.SHEEP, resumed, true, Vector2.RIGHT, 8, cancelled, history) == cancelled, "Token changes without a visual cue do not allocate new poses")
	var reborn := AgentHandle.new(life.slot, life.generation + 1, life.world_epoch)
	var birth: PublishedPose = PublishedPose.sample(reborn, SimTypes.Species.SHEEP, flee, true, Vector2.RIGHT, 9, interrupted, history)
	_check(birth.cue_action == -1 and birth.cue_owner_token == 0, "A reused slot cannot inherit a retired life's cue")
	var reset := AgentHandle.new(life.slot, life.generation, life.world_epoch + 1)
	_check(PublishedPose.sample(reset, SimTypes.Species.SHEEP, flee, true, Vector2.RIGHT, 0, interrupted, history).cue_action == -1, "A new epoch starts with no cue from the old world")
	_check(startled.cue_action == AnimationCatalog.Action.SHEEP_STARTLE and startled.cue_started_tick == 1, "Pinned older versions remain unchanged after later transitions")
	var buffer := IntentBuffer.new()
	flee.expires_tick = 12
	buffer.write(life, flee)
	var at_end: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, buffer.get_intent(life, 12), false, Vector2.RIGHT, 13, startled, history)
	_check(at_end.cue_action == -1, "The exclusive TTL boundary clears a cue and does not synthesize calm behavior")
	var pool := PublishedPose.History.new()
	var stale := PublishedPose.new()
	stale.cue_action = AnimationCatalog.Action.DOG_BARK
	stale.cue_started_tick = 888
	stale.cue_owner_token = 999
	stale.has_intent = true
	pool.versions.append(stale)
	stale = null
	var overwritten: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, null, false, Vector2.RIGHT, 1, null, pool)
	_check(pool.allocations == 0 and not overwritten.has_intent and overwritten.cue_action == -1 and overwritten.cue_started_tick == 0 and overwritten.cue_owner_token == 0, "Pool reuse overwrites every cue field, including cancellation defaults")
	var idle: MotionIntent = _intent(SimTypes.Behavior.IDLE, SimTypes.IntentMode.STOP, 20)
	var known_idle: PublishedPose = PublishedPose.sample(life, SimTypes.Species.SHEEP, idle, false, Vector2.RIGHT, 2, overwritten, pool)
	_check(known_idle.has_intent and known_idle.cue_action == -1 and known_idle.action == overwritten.action, "Known idle and missing intent retain distinct history even when their base image is identical")
	_check(PublishedPose.sample(life, SimTypes.Species.SHEEP, idle, false, Vector2.RIGHT, 3, known_idle, pool) == known_idle, "Unchanged intent presence does not create repeated versions")
	_check(PublishedPose.sample(life, SimTypes.Species.SHEEP, flee, true, Vector2.RIGHT, 4, known_idle, pool).cue_action == AnimationCatalog.Action.SHEEP_STARTLE, "A verified idle-to-flee edge can startle despite sharing its earlier image with missing intent")
	_test_dog_edges(life)

func _test_dog_edges(life: AgentHandle) -> void:
	var history := PublishedPose.History.new()
	var guard: MotionIntent = _intent(SimTypes.Behavior.GUARD, SimTypes.IntentMode.STOP, 1)
	var pressure: MotionIntent = _intent(SimTypes.Behavior.INTERCEPT, SimTypes.IntentMode.PRESSURE, 2)
	var before: PublishedPose = PublishedPose.sample(life, SimTypes.Species.DOG, guard, false, Vector2.RIGHT, 1, null, history)
	var detect: PublishedPose = PublishedPose.sample(life, SimTypes.Species.DOG, pressure, true, Vector2.RIGHT, 2, before, history)
	_check(detect.cue_action == AnimationCatalog.Action.DOG_DETECT, "A moving first interception shows detection once")
	_check(PublishedPose.sample(life, SimTypes.Species.DOG, pressure, false, Vector2.RIGHT, 3, detect, history) == detect, "Stopping during the same pressure episode does not queue another cue")
	var bark: PublishedPose = PublishedPose.sample(life, SimTypes.Species.DOG, pressure, false, Vector2.RIGHT, 2, before, history)
	_check(bark.cue_action == AnimationCatalog.Action.DOG_BARK, "A stationary first pressure edge can show one bark")
	var moving: PublishedPose = PublishedPose.sample(life, SimTypes.Species.DOG, pressure, true, Vector2.RIGHT, 3, bark, history)
	_check(moving == bark and moving.cue_started_tick == 1, "Movement changes do not restart the pressure cue")
	var returning: MotionIntent = _intent(SimTypes.Behavior.RETURN, SimTypes.IntentMode.MOVE, 3)
	var return_pose: PublishedPose = PublishedPose.sample(life, SimTypes.Species.DOG, returning, true, Vector2.RIGHT, 4, moving, history)
	_check(return_pose.cue_action == -1, "Returning while moving does not pretend to relax")
	var relaxed: PublishedPose = PublishedPose.sample(life, SimTypes.Species.DOG, guard, false, Vector2.RIGHT, 5, return_pose, history)
	_check(relaxed.cue_action == AnimationCatalog.Action.DOG_RELAX, "A valid stationary guard intent after return can relax")
	_check(PublishedPose.sample(life, SimTypes.Species.DOG, null, false, Vector2.RIGHT, 6, detect, history).cue_action == -1, "Lost interception intent does not imply relaxation")
	var attack: MotionIntent = _intent(SimTypes.Behavior.ATTACK, SimTypes.IntentMode.ATTACK, 7)
	var wolf: PublishedPose = PublishedPose.sample(life, SimTypes.Species.WOLF, attack, false, Vector2.RIGHT, 7, null, history)
	_check(wolf.action == AnimationCatalog.Action.WOLF_POUNCE and wolf.cue_action == -1, "An attack intent never invents a successful bite")

func _test_visual_clocks() -> void:
	var sample := AnimationCatalog.VisualSample.new()
	for cue: int in [AnimationCatalog.Action.SHEEP_STARTLE, AnimationCatalog.Action.SHEEP_RECOVER, AnimationCatalog.Action.DOG_DETECT, AnimationCatalog.Action.DOG_BARK, AnimationCatalog.Action.DOG_RELAX]:
		for direction: int in 8:
			var clip: AnimationCatalog.Clip = _catalog.get_clip(cue, direction)
			var times: Array[float] = [-0.001, 0.0, clip.duration_ms - 0.001, float(clip.duration_ms), clip.duration_ms + 0.001, clip.duration_ms * 1000000.0]
			for boundary: int in clip.cumulative_ms:
				times.append(boundary - 0.001)
				times.append(float(boundary))
			for elapsed: float in times:
				_catalog.resolve_visual(sample, AnimationCatalog.Action.SHEEP_IDLE, direction, 12345.25, cue, elapsed)
				var active: bool = elapsed >= 0.0 and elapsed < clip.duration_ms
				_check(sample.action == (cue if active else AnimationCatalog.Action.SHEEP_IDLE), "The cue uses its real authored duration and never loops/replays beyond its window")
				_check(sample.elapsed_ms == (elapsed if active else 12345.25), "Cue resolution preserves either its exact local clock or the continuing base clock")

func _world() -> SimulationWorld:
	var config := SimulationConfig.new()
	config.detached_ai = true
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, scenario)
	return world

func _publish(executor: SimulationExecutor, world: SimulationWorld) -> SimulationPublication:
	executor._publish(world, 1)
	var delivery: SimulationDelivery = executor.poll_delivery()
	return executor.poll_state(delivery.sequence)

func _job(view: WorldPresentation, source: SimulationPublication, alpha: float) -> PresentationJob:
	var job := PresentationJob.new()
	job.begin(view, source, alpha, false)
	job.advance(Time.get_ticks_usec() + 1000000)
	_check(job.phase == PresentationJob.Phase.READY, "The small fixture finishes its normal cooperative preparation")
	return job

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _test_publication_and_capture() -> void:
	var world: SimulationWorld = _world()
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(200, 200))
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(400, 200))
	world.intents.write(sheep, _intent(SimTypes.Behavior.GRAZE, SimTypes.IntentMode.GRAZE, 1))
	world.intents.write(dog, _intent(SimTypes.Behavior.GUARD, SimTypes.IntentMode.STOP, 1))
	var executor := SimulationExecutor.new()
	var inline_view := WorldPresentation.new()
	var worker_view := WorldPresentation.new()
	root.add_child(inline_view)
	root.add_child(worker_view)
	inline_view.setup(world.store, world.intents, world.resources, world.config)
	worker_view.setup(world.store, world.intents, world.resources, world.config)
	inline_view.observe_published(0)
	_publish(executor, world)
	world.intents.write(sheep, _intent(SimTypes.Behavior.FLEE, SimTypes.IntentMode.MOVE, 2))
	world.intents.write(dog, _intent(SimTypes.Behavior.INTERCEPT, SimTypes.IntentMode.PRESSURE, 3))
	world.store.velocity_current[world.store.resolve(sheep)] = Vector2(40, 0)
	world.tick = 1
	var source: SimulationPublication = _publish(executor, world)
	inline_view.present(1, 0.5)
	var job: PresentationJob = _job(worker_view, source, 0.5)
	_check(inline_view._states[sheep.slot].cue_action == source.pose_at(world.store.resolve(sheep)).cue_action, "Inline and worker use the same pose edge policy")
	for index: int in job.drawings.size():
		_check(job.drawings[index].region == inline_view._draw_list[index].region and job.drawings[index].area == inline_view._draw_list[index].area, "Inline and worker prepare the same cue frame and pivot")
	var frozen_region: Rect2 = inline_view._draw_list[0].region
	await process_frame
	inline_view.present(1, 0.5)
	_check(inline_view._draw_list[0].region == frozen_region, "A paused display clock does not advance with process frames")
	var event := CaptureEvent.new()
	event.target = sheep
	event.position = Vector2(202, 200)
	event.previous_position = Vector2(200, 200)
	event.facing = Vector2.RIGHT
	event.tick = 2
	inline_view.add_capture(sheep, event.position, event.facing, event.tick)
	worker_view.queue_reliable_capture(event, source.pose_at(world.store.resolve(sheep)))
	world.store.remove_agent(sheep)
	var replacement: AgentHandle = world.store.create_agent(SimTypes.Species.WOLF, Vector2(600, 200))
	world.tick = 2
	source = _publish(executor, world)
	inline_view.present(2, 0.5)
	job = _job(worker_view, source, 0.5)
	_check(replacement.slot == sheep.slot and not replacement.same_life(sheep), "The fixture reuses the captured slot with a complete new identity")
	_check(inline_view._captures[0].previous_cue_action == AnimationCatalog.Action.SHEEP_STARTLE and job.captures[0].previous_cue_action == AnimationCatalog.Action.SHEEP_STARTLE, "Capture interpolation owns the old life's cue in both paths")
	_check(source.pose_at(world.store.resolve(replacement)).cue_action == -1, "The replacement wolf never inherits the sheep cue")
	_check(job.captures[0].handle.same_life(sheep), "Reliable capture still belongs to the retired life")
	for entry: WorldPresentation.DrawEntry in job.drawings:
		if entry.is_capture:
			var visual: WorldPresentation.CaptureVisual = job.captures[0]
			var elapsed: float = (job.display_tick - visual.previous_cue_started_tick) * world.config.fixed_dt * 1000.0
			_check(entry.region == _catalog.get_clip(AnimationCatalog.Action.SHEEP_STARTLE, visual.previous_direction).frame_at(elapsed), "Before capture time the retired body actually draws its old cue frame")
	job = _job(worker_view, source, 1.0)
	for entry: WorldPresentation.DrawEntry in job.drawings:
		if entry.is_capture:
			_check(entry.region == _catalog.get_clip(AnimationCatalog.Action.SHEEP_CAPTURED, job.captures[0].direction).frame_at(0.0), "At the authoritative capture boundary the captured clip immediately takes priority")
	world._hold(dog)
	world._drop(dog, Vector2(400, 200))
	world.intents.write(dog, _intent(SimTypes.Behavior.INTERCEPT, SimTypes.IntentMode.PRESSURE, 4))
	world.tick = 3
	source = _publish(executor, world)
	_check(source.pose_at(world.store.resolve(dog)).cue_action == -1, "A same-stage hold/drop and new task cancels the old cue without needing an intermediate published held body")
	world.intents.write(dog, _intent(SimTypes.Behavior.GUARD, SimTypes.IntentMode.STOP, 5))
	world.tick = 4
	_publish(executor, world)
	world._hold(dog)
	world.tick = 5
	source = _publish(executor, world)
	_check(source.pose_at(world.store.resolve(dog)).cue_action == -1 and world.store.held[world.store.resolve(dog)] != 0, "The real hold path removes the intent and clears its visual cue")
	world._drop(dog, Vector2(400, 200))
	world.intents.write(dog, _intent(SimTypes.Behavior.INTERCEPT, SimTypes.IntentMode.PRESSURE, 6))
	world.tick = 6
	source = _publish(executor, world)
	_check(source.pose_at(world.store.resolve(dog)).cue_action == -1, "Resuming the same behavior after a published hold does not replay the cancelled cue")
	world.intents.write(dog, _intent(SimTypes.Behavior.GUARD, SimTypes.IntentMode.STOP, 7))
	world.tick = 7
	_publish(executor, world)
	world.intents.write(dog, _intent(SimTypes.Behavior.INTERCEPT, SimTypes.IntentMode.PRESSURE, 8))
	world.tick = 8
	source = _publish(executor, world)
	_check(source.pose_at(world.store.resolve(dog)).cue_action == AnimationCatalog.Action.DOG_BARK, "A later distinct valid guard-to-pressure edge can start a new cue")
	world.tick = 120
	source = _publish(executor, world)
	job = _job(worker_view, source, 1.0)
	var pose: PublishedPose = source.pose_at(world.store.resolve(dog))
	var visual := AnimationCatalog.VisualSample.new()
	_catalog.resolve_visual(visual, pose.action, pose.direction, 2000.0, pose.cue_action, (job.display_tick - pose.cue_started_tick) * world.config.fixed_dt * 1000.0)
	_check(visual.action == pose.action, "A display jump beyond the entire cue directly shows the current base action")
	world.reset(world.scenario)
	var reset_life: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(200, 200))
	source = _publish(executor, world)
	job.begin(worker_view, source, 1.0, true)
	job.advance(Time.get_ticks_usec() + 1000000)
	_check(job.states[reset_life.slot].cue_action == -1 and job.captures.is_empty(), "Reusing a back-frame bank after reset cannot retain old-life cues or captures")
	inline_view.free()
	worker_view.free()
	_close(world)

func _test_pixels() -> void:
	root.size = Vector2i(1280, 800)
	var world: SimulationWorld = _world()
	var cues: Array[int] = [AnimationCatalog.Action.SHEEP_STARTLE, AnimationCatalog.Action.SHEEP_RECOVER, AnimationCatalog.Action.DOG_DETECT, AnimationCatalog.Action.DOG_BARK, AnimationCatalog.Action.DOG_RELAX]
	var source: SimulationPublication
	for index: int in cues.size():
		world.store.create_agent(SimTypes.Species.SHEEP if index < 2 else SimTypes.Species.DOG, Vector2(180 + index * 180, 300))
	source = SimulationPublication.capture(world, null)
	source.pose_buffer = PoseBuffer.new()
	source.pose_buffer.prepare(cues.size())
	for index: int in cues.size():
		var pose := PublishedPose.new()
		pose.handle = world.store.handle_at(index)
		pose.species = world.store.species[index]
		pose.action = AnimationCatalog.Action.SHEEP_IDLE if index < 2 else AnimationCatalog.Action.DOG_GUARD_IDLE
		pose.direction = index % 8
		pose.previous_direction = pose.direction
		pose.phase_direction = pose.direction
		pose.cue_action = cues[index]
		source.pose_buffer.write(index, pose)
	var view := WorldPresentation.new()
	root.add_child(view)
	view.setup(world.store, world.intents, world.resources, world.config)
	var comparisons: Array[Dictionary] = []
	for milliseconds: float in [0.0, 70.0, 294.999, 295.0, 400.0, 760.0, 830.0, 860.0, 900.0]:
		var display: float = milliseconds / (source.config.fixed_dt * 1000.0)
		source.tick = floori(display) + 1
		var alpha: float = display - floorf(display)
		var cpu: Image = await _render_source(view, source, alpha, false)
		var gpu: Image = await _render_source(view, source, alpha, true)
		var left: PackedByteArray = cpu.get_data()
		var right: PackedByteArray = gpu.get_data()
		var differences: int = 0
		var maximum: int = 0
		for index: int in left.size():
			var error: int = absi(int(left[index]) - int(right[index]))
			maximum = maxi(maximum, error)
			differences += int(error > 1)
		_check(differences == 0, "CPU/GPU use the same cue frame at %.3f ms" % milliseconds)
		comparisons.append({"milliseconds": milliseconds, "differing_channels_gt1": differences, "maximum_error": maximum})
		if not _capture_base.is_empty() and (milliseconds == 70.0 or milliseconds == 900.0 or differences > 0):
			cpu.save_png(_capture_base + "-%s-cpu.png" % str(milliseconds))
			gpu.save_png(_capture_base + "-%s-gpu.png" % str(milliseconds))
	if not _capture_base.is_empty():
		var file: FileAccess = FileAccess.open(_capture_base + "-pixels.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(comparisons, "  "))
	view.free()
	_close(world)

func _render_source(view: WorldPresentation, source: SimulationPublication, alpha: float, gpu: bool) -> Image:
	# Test-only renderer selection; no authoritative World state is changed.
	source.config.gpu_presentation = gpu
	var job: PresentationJob = _job(view, source, alpha)
	view.commit_job(job)
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
