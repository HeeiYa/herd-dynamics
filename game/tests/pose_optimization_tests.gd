extends SceneTree
var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures < 10:
			push_error(message)

func old_direction(facing: Vector2, previous: int) -> int:
	if facing.length_squared() < 0.01:
		return previous
	var angle: float = facing.angle()
	if absf(wrapf(angle - previous * PI / 4.0, -PI, PI)) < PI / 8.0 + 0.06:
		return previous
	return posmod(roundi(angle / (PI / 4.0)), 8)

func _run() -> void:
	for previous: int in 8:
		for index: int in 8192:
			for magnitude: float in [0.0, 0.099999, 0.1, 1.0, 100.0]:
				var facing: Vector2 = Vector2.from_angle(index * TAU / 8192.0) * magnitude
				check(AnimationCatalog.direction_for(facing, previous) == old_direction(facing, previous), "Direction differs from angular oracle")
		for boundary: int in 8:
			for offset: float in [-PI / 8.0 - 0.06, -PI / 8.0, PI / 8.0, PI / 8.0 + 0.06]:
				for epsilon: float in [-0.000001, -0.00000001, 0.0, 0.00000001, 0.000001]:
					var facing: Vector2 = Vector2.from_angle(boundary * PI / 4.0 + offset + epsilon)
					check(AnimationCatalog.direction_for(facing, previous) == old_direction(facing, previous), "Angular tie or hysteresis boundary changed")
	_check_cached_pose_sequence()
	var buffer := IntentBuffer.new()
	var life := AgentHandle.new(257, 2, 3)
	var intent := MotionIntent.new()
	intent.expires_tick = 10
	buffer.write(life, intent)
	var pinned_intents: IntentBuffer = buffer.publication_copy()
	check(buffer.get_intent(AgentHandle.new(257, 2, 3), 9) == intent, "Equivalent full handles resolve array slots")
	check(buffer.get_intent(life, 10) == null, "TTL is exclusive at the same boundary")
	check(buffer.get_intent(AgentHandle.new(257, 3, 3), 0) == null and buffer.get_intent(AgentHandle.new(257, 2, 4), 0) == null, "Generation and epoch still gate access")
	check(buffer.get_intent(AgentHandle.new(-1), 0) == null, "Invalid negative slot has no record")
	buffer.remove(AgentHandle.new(257, 3, 3))
	check(buffer.get_intent(life, 9) == intent, "Stale removal does not affect the current life")
	buffer.clear()
	check(pinned_intents.get_intent(life, 9) != null, "Clearing the owner leaves a pinned publication intact")
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.detached_ai = true
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 1
	scenario.wolf_count = 0
	scenario.dog_count = 0
	world.setup(config, scenario)
	world.ai.begin_frame()
	world.step()
	life = world.store.handle_at(0)
	var executor := SimulationExecutor.new()
	var pinned: Array[SimulationPublication] = []
	for index: int in 20:
		world.tick += 1
		intent = MotionIntent.new()
		intent.behavior = SimTypes.Behavior.FLEE if index % 2 == 0 else SimTypes.Behavior.IDLE
		intent.expires_tick = world.tick + 1
		world.intents.write(life, intent)
		executor._publish(world, 1)
		executor.poll_delivery()
		pinned.append(executor.poll_state(index))
	for index: int in pinned.size():
		check(pinned[index].pose_at(0).behavior == (SimTypes.Behavior.FLEE if index % 2 == 0 else SimTypes.Behavior.IDLE), "Pinned poses survive buffer and object pool exhaustion")
	check(executor._pose_buffers.size() <= 8 and executor._pose_histories[life.slot].versions.size() <= 8, "Pool retention is bounded even with many external readers")
	pinned.clear()
	var later_allocations: int = 0
	for index: int in 100:
		world.tick += 1
		intent = MotionIntent.new()
		intent.behavior = SimTypes.Behavior.FLEE if index % 2 == 0 else SimTypes.Behavior.IDLE
		intent.expires_tick = world.tick
		world.intents.write(life, intent)
		executor._publish(world, 1)
		executor.poll_delivery()
		var publication: SimulationPublication = executor.poll_state(index + 20)
		check(publication.active_agents == 1 and publication.missing_intents == 1, "Fused quality pass counts expiration at n")
		check(publication.pose_at(0).behavior == intent.behavior, "Animation still reads the valid n-1 intent")
		if index > 16:
			later_allocations += publication.pose_allocations + publication.pose_buffer_allocations
	check(later_allocations == 0, "Changing poses and frame buffers allocate no new objects after leases recycle")
	world.motion.close()
	world.ai.reset()
	world.free()
	print("POSE_OPTIMIZATION_TESTS checks=%d failures=%d steady_allocations=%d" % [checks, failures, later_allocations])
	quit(0 if failures == 0 else 1)

func _check_cached_pose_sequence() -> void:
	var history := PublishedPose.History.new()
	var handle := AgentHandle.new(7, 1, 3)
	var intent := MotionIntent.new()
	var previous: PublishedPose
	for index: int in 4096:
		if index == 2048:
			handle = AgentHandle.new(7, 2, 3)
		var continuing: bool = previous != null and previous.handle.same_life(handle)
		var facing: Vector2 = Vector2.from_angle(float(index / 4) * TAU / 1024.0)
		if index % 20 == 0:
			facing = Vector2.ZERO
		var moving: bool = index % 3 == 0
		intent.behavior = SimTypes.Behavior.FLEE if index % 11 == 0 else SimTypes.Behavior.GRAZE
		var expected_direction: int = old_direction(facing, previous.direction if continuing else 0)
		var expected_action: int = AnimationCatalog.action_for(SimTypes.Species.SHEEP, intent.behavior, moving, false)
		var pose: PublishedPose = PublishedPose.sample(handle, SimTypes.Species.SHEEP, intent, moving, facing, index, previous, history)
		check(pose.direction == expected_direction and pose.action == expected_action, "Facing cache preserves direction/action across changes and slot reuse")
		if continuing and expected_direction == previous.direction and expected_action == previous.action and intent.behavior == previous.behavior:
			check(pose == previous, "Unchanged visual state keeps its immutable record")
		previous = pose
