extends SceneTree
## Candidate A only: intent lookup reuse, with the existing pose algorithm intact.
class CountedIntents extends IntentBuffer:
	var lookups: int = 0

	func get_intent(handle: AgentHandle, tick: int) -> MotionIntent:
		lookups += 1
		return super.get_intent(handle, tick)

var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _world() -> SimulationWorld:
	var config := SimulationConfig.new()
	config.detached_ai = true
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 1
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, scenario)
	world._apply_commands()
	# Only the pose projection runs in this fixture. AI/motion/interaction retain
	# their original dependencies and are deliberately not stepped after replacing.
	world.intents = CountedIntents.new()
	return world

func _intent(behavior: int, expires_tick: int, token: int = 1) -> MotionIntent:
	var result := MotionIntent.new()
	result.behavior = behavior
	result.expires_tick = expires_tick
	result.owner_token = token
	return result

func _project(executor: SimulationExecutor, world: SimulationWorld) -> SimulationPublication:
	# Intent publication drains _changed_slots before the pose pass, just as in
	# production. The independent mutation ledger must remain valid afterwards.
	var publication: SimulationPublication = SimulationPublication.capture(world, null)
	executor._sample_poses(world, publication)
	return publication

func _dispose(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _run() -> void:
	_check_ttl_and_mutation_aba()
	_check_buffer_and_life_identity()
	_check_projection_equivalence()
	print("POSE_INTENT_CACHE_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_ttl_and_mutation_aba() -> void:
	var world: SimulationWorld = _world()
	var buffer: CountedIntents = world.intents as CountedIntents
	var handle: AgentHandle = world.store.handle_at(0)
	var executor := SimulationExecutor.new()
	var first: MotionIntent = _intent(SimTypes.Behavior.FLEE, 5)
	buffer.write(handle, first)
	world.tick = 4
	var pinned: SimulationPublication = _project(executor, world)
	_check(pinned.pose_at(0).behavior == SimTypes.Behavior.FLEE and pinned.missing_intents == 0, "Initial lookup sees the current complete life and valid intent")
	_check(buffer.lookups == 1, "The first pose row validates its intent once")
	var repeated: SimulationPublication = _project(executor, world)
	_check(buffer.lookups == 1 and repeated.pose_at(0) == pinned.pose_at(0), "Control-only repeated projection reuses the lookup and immutable pose")
	world.tick = 5
	var boundary: SimulationPublication = _project(executor, world)
	_check(boundary.pose_at(0).behavior == SimTypes.Behavior.FLEE and boundary.missing_intents == 1, "At n=expiry, animation n-1 remains valid while quality n is missing")
	world.tick = 6
	var expired: SimulationPublication = _project(executor, world)
	_check(expired.pose_at(0).behavior == SimTypes.Behavior.IDLE and expired.missing_intents == 1, "TTL expires without a writer touching the intent")
	_check(buffer.lookups == 1, "TTL advancement does not require a repeated full lookup")
	buffer.remove(handle)
	var after_remove: MotionIntent = _intent(SimTypes.Behavior.GRAZE, 50, 7)
	buffer.write(handle, after_remove)
	_check(first.revision == 0 and after_remove.revision == 0, "Fixture genuinely exercises same-life revision-zero ABA")
	var replacement: SimulationPublication = _project(executor, world)
	_check(buffer.lookups == 2 and replacement.pose_at(0).behavior == SimTypes.Behavior.GRAZE, "Mutation stamps invalidate a removed and rewritten intent even at equal revision")
	buffer.clear_owned(handle, 6)
	_project(executor, world)
	_check(buffer.lookups == 2, "A stale owner's rejected clear does not invent a mutation")
	buffer.clear_owned(handle, 7)
	var cancelled: SimulationPublication = _project(executor, world)
	_check(buffer.lookups == 3 and cancelled.missing_intents == 1, "The correct owner cancellation invalidates the cached record")
	var equivalent := AgentHandle.new(handle.slot, handle.generation, handle.world_epoch)
	buffer.write(equivalent, _intent(SimTypes.Behavior.FLEE, 50))
	var external: SimulationPublication = _project(executor, world)
	_check(external.pose_at(0).behavior == SimTypes.Behavior.FLEE, "A reconstructed full handle is accepted by the unchanged identity lookup")
	var before_clear_epoch: int = world.store.epoch
	buffer.clear()
	var cleared: SimulationPublication = _project(executor, world)
	_check(world.store.epoch == before_clear_epoch and cleared.missing_intents == 1 and cleared.pose_at(0).behavior == SimTypes.Behavior.IDLE, "Clear invalidates cached records even without an epoch change")
	buffer.write(handle, _intent(SimTypes.Behavior.GRAZE, 50))
	_check(_project(executor, world).pose_at(0).behavior == SimTypes.Behavior.GRAZE, "Write after clear cannot match a stale mutation stamp")
	_check(pinned.pose_at(0).behavior == SimTypes.Behavior.FLEE and pinned.intents.get_intent(handle, 4).expires_tick == 5, "Old pose and intent publications remain immutable after all cache mutations")
	_dispose(world)

func _pose_fields(pose: PublishedPose) -> Dictionary:
	return {
		"life": pose.handle.key(), "species": pose.species,
		"behavior": pose.behavior, "action": pose.action,
		"direction": pose.direction, "previous_direction": pose.previous_direction,
		"direction_tick": pose.direction_tick, "started_tick": pose.started_tick,
		"phase_direction": pose.phase_direction,
		"has_intent": pose.has_intent, "cue_action": pose.cue_action,
		"cue_started_tick": pose.cue_started_tick, "cue_owner_token": pose.cue_owner_token,
	}

func _check_projection_equivalence() -> void:
	var world: SimulationWorld = _world()
	var buffer: CountedIntents = world.intents as CountedIntents
	var handle: AgentHandle = world.store.handle_at(0)
	var executor := SimulationExecutor.new()
	var reference_history := PublishedPose.History.new()
	var reference: PublishedPose
	var pinned: Array[SimulationPublication] = []
	var expected_fields: Array[Dictionary] = []
	var threshold_speeds := PackedFloat32Array([0.0, 2.99999, 3.0, 3.00001, 7.0])
	for index: int in 128:
		world.tick = index + 1
		if index % 37 == 0:
			buffer.clear()
		elif index % 11 == 0:
			buffer.remove(handle)
		if index % 7 == 0:
			var behavior: int = SimTypes.Behavior.FLEE if index % 2 == 0 else SimTypes.Behavior.GRAZE
			var intent: MotionIntent = _intent(behavior, world.tick + 3)
			intent.mode = SimTypes.IntentMode.PRESSURE if index % 3 == 0 else SimTypes.IntentMode.STOP
			buffer.write(handle, intent)
		world.store.velocity_current[0] = Vector2(threshold_speeds[index % threshold_speeds.size()], 0.0)
		world.store.facing[0] = Vector2.from_angle(float(index / 4) * PI / 16.0)
		world.store.set_held(handle, index % 17 == 0)
		var observed_tick: int = maxi(0, world.tick - 1)
		var direct: MotionIntent = buffer.get_intent(handle, observed_tick)
		var moving: bool = world.store.velocity_current[0].length_squared() > 9.0
		# The oracle is the same production projection with the uncached getter,
		# independent history and identical inputs, not a second animation system.
		reference = PublishedPose.sample(handle, world.store.species[0], direct, moving, world.store.facing[0], world.tick, reference, reference_history)
		var publication: SimulationPublication = _project(executor, world)
		_check(_pose_fields(publication.pose_at(0)) == _pose_fields(reference), "Cached intent projection preserves all pose timeline fields at tick %d" % world.tick)
		var expected_active: int = 0 if world.store.held[0] != 0 else 1
		var expected_missing: int = 0
		if expected_active > 0 and (direct == null or world.tick >= direct.expires_tick):
			expected_missing = 1
		_check(publication.active_agents == expected_active and publication.missing_intents == expected_missing, "Cached lookup preserves quality n while pose uses n-1 at tick %d" % world.tick)
		pinned.append(publication)
		expected_fields.append(_pose_fields(reference))
	for index: int in pinned.size():
		_check(_pose_fields(pinned[index].pose_at(0)) == expected_fields[index], "All pinned publications retain their timeline after cache and pool reuse")
	_dispose(world)

func _check_buffer_and_life_identity() -> void:
	var world: SimulationWorld = _world()
	var original: CountedIntents = world.intents as CountedIntents
	var executor := SimulationExecutor.new()
	var old_handle: AgentHandle = world.store.handle_at(0)
	original.write(old_handle, _intent(SimTypes.Behavior.FLEE, 100))
	world.tick = 2
	var pinned: SimulationPublication = _project(executor, world)
	var replacement := CountedIntents.new()
	replacement.write(old_handle, _intent(SimTypes.Behavior.GRAZE, 100))
	_check(original.mutation_versions_for_slots(world.store.capacity)[old_handle.slot] == replacement.mutation_versions_for_slots(world.store.capacity)[old_handle.slot], "Two buffer instances have matching stamp values in the replacement fixture")
	world.intents = replacement
	_check(_project(executor, world).pose_at(0).behavior == SimTypes.Behavior.GRAZE and replacement.lookups == 1, "Buffer-instance replacement invalidates matching cached stamps")
	# Deliberately leave a stale intent behind to prove cache identity does not
	# rely on the usual World removal also clearing the intent buffer.
	world.store.remove_agent(old_handle)
	var new_handle: AgentHandle = world.store.create_agent(SimTypes.Species.DOG, Vector2(300, 300), 13.0)
	_check(new_handle.slot == old_handle.slot and new_handle.generation != old_handle.generation, "Fixture reuses a slot without changing its intent mutation stamp")
	var newborn: SimulationPublication = _project(executor, world)
	_check(newborn.missing_intents == 1 and newborn.pose_at(0).handle.same_life(new_handle) and newborn.pose_at(0).behavior == SimTypes.Behavior.IDLE, "New generation cannot inherit a cached old-life intent")
	_check(pinned.pose_at(0).handle.same_life(old_handle) and pinned.pose_at(0).behavior == SimTypes.Behavior.FLEE, "Retired-life pose is still valid for an old frame or capture")
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 1
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var old_epoch: int = world.store.epoch
	world.reset(scenario)
	world._apply_commands()
	var reset: SimulationPublication = _project(executor, world)
	_check(reset.epoch > old_epoch and reset.pose_at(0).handle.world_epoch == reset.epoch, "Reset establishes fresh epoch-bound intent and pose caches")
	_dispose(world)
