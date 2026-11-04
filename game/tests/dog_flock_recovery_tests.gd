extends SceneTree
## Formal trees and ordinary registered actors verify finite historical search.
## This CPU contract suite is separate from the GPU production behavior protocol.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)

func _run() -> void:
	await _test_finite_search_and_paused_clock()
	_test_held_resume_and_new_observation()
	_test_clipped_waypoints_and_context_reuse()
	print("DOG_FLOCK_RECOVERY_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _world(size: Vector2 = Vector2(1600, 1000)) -> SimulationWorld:
	var config := SimulationConfig.new()
	config.world_size = size
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, scenario)
	return world

func _step(world: SimulationWorld, count: int = 1) -> void:
	for index: int in count:
		world.ai.begin_frame()
		world.step()

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _wait_for_episode(world: SimulationWorld, context: AgentContext, previous_episode: int = -1) -> bool:
	for step: int in 60:
		if context.flock_search_observed_tick > previous_episode:
			return true
		_step(world)
	return false

func _test_finite_search_and_paused_clock() -> void:
	var world: SimulationWorld = _world()
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(500, 500))
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(540, 500))
	_step(world, 60)
	var context: AgentContext = world.ai.inspect(dog)
	var positive_tick: int = context.last_flock_seen_tick
	var anchor: Vector2 = context.protection_anchor
	_check(positive_tick >= 0, "A real registered sheep establishes a direct positive flock observation")
	world.queue_remove(sheep)
	_check(_wait_for_episode(world, context), "Losing the last sheep starts a historical search episode")
	_check(context.flock_search_observed_tick == positive_tick and context.flock_search_anchor == anchor, "Empty scans do not refresh the historical episode or anchor")
	var paused_tick: int = world.tick
	var deadline: int = context.flock_search_deadline_tick
	var waypoint: int = context.flock_search_waypoint
	# A paused owner issues no World.step. UI frames and wall time alone cannot
	# consume a simulation-clock search deadline or move its waypoint cursor.
	for frame: int in 3:
		await process_frame
	_check(world.tick == paused_tick and context.flock_search_deadline_tick == deadline and context.flock_search_waypoint == waypoint, "Paused simulation does not advance historical search")
	var local_search_seen: bool = context.flock_search_phase == AgentContext.FlockSearchPhase.LOCAL_SWEEP
	var fallback_seen: bool = false
	for step: int in world.ai.settings.dog_flock_search_ticks + 180:
		_step(world)
		local_search_seen = local_search_seen or context.flock_search_phase == AgentContext.FlockSearchPhase.LOCAL_SWEEP
		fallback_seen = fallback_seen or context.task_name == &"search_area"
	_check(local_search_seen, "Arrival at an empty historical anchor begins the bounded neighborhood sweep")
	_check(fallback_seen and context.flock_search_phase == AgentContext.FlockSearchPhase.FINISHED, "No sheep eventually exhausts search and returns to ordinary exploration")
	_check(context.last_flock_searched_tick == positive_tick and context.flock_search_observed_tick == positive_tick, "The same dead flock observation cannot restart local search forever")
	_check(context.last_flock_seen_tick == positive_tick and context.flock_count == 0, "Searching never manufactures a new flock sighting")
	_check(world.config.ai_budget_usec == 6000 and world.config.perception_radius == 180.0 and world.config.memory_ticks == 120, "Search leaves production service budget and sensing rules unchanged")
	_close(world)

func _test_held_resume_and_new_observation() -> void:
	var world: SimulationWorld = _world()
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(500, 500))
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(540, 500))
	_step(world, 60)
	var context: AgentContext = world.ai.inspect(dog)
	world.queue_remove(sheep)
	_check(_wait_for_episode(world, context), "Held-resume fixture has a real pending historical search")
	var old_episode: int = context.flock_search_observed_tick
	var old_deadline: int = context.flock_search_deadline_tick
	world.queue_hold(dog)
	_step(world, world.ai.settings.dog_flock_search_ticks + 1)
	_check(context.suspended and world.tick > old_deadline, "Held life does not stop the world's simulation clock")
	var drop_position := Vector2(1200, 700)
	world.config.perception_jobs = 0
	world.queue_drop(dog, drop_position)
	world.queue_place(SimTypes.Species.SHEEP, drop_position + Vector2(30, 0))
	var drop_tick: int = world.tick
	for step: int in 3:
		_step(world)
		world.ai._request_urgent(context, world.tick)
		_check(context.awaiting_resume_perception and world.intents.get_intent(dog, world.tick) == null, "Even urgent work cannot run the old search before the post-drop scan")
		_check(context.position() == drop_position, "Waiting for resume perception cannot move toward an obsolete anchor")
	world.config.perception_jobs = 512
	_step(world, 30)
	_check(context.last_perception_tick >= drop_tick and not context.awaiting_resume_perception, "A real new scan releases the resume dependency")
	_check(context.flock_count > 0 and context.task_name == &"guard_flock", "A newly observed flock takes priority over the expired historical search")
	var new_positive_tick: int = context.last_flock_seen_tick
	var new_anchor: Vector2 = context.protection_anchor
	for dense: int in world.store.count:
		if world.store.species[dense] == SimTypes.Species.SHEEP:
			world.queue_remove(world.store.handle_at(dense))
	_check(_wait_for_episode(world, context, old_episode), "A new positive observation permits a distinct later search episode")
	_check(context.flock_search_observed_tick == new_positive_tick and context.flock_search_anchor == new_anchor, "New episode uses the newly observed group rather than the prior group's anchor")
	_close(world)

func _test_clipped_waypoints_and_context_reuse() -> void:
	var world: SimulationWorld = _world(Vector2(64, 64))
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(32, 32))
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(13, 13))
	_step(world, 24)
	var context: AgentContext = world.ai.inspect(dog)
	world.queue_remove(sheep)
	_check(_wait_for_episode(world, context), "A corner flock still produces one historical search episode")
	_step(world, 90)
	_check(context.flock_search_phase == AgentContext.FlockSearchPhase.FINISHED and context.task_name == &"search_area", "Clipped and overlapping waypoints terminate instead of cycling at a corner")
	_check(context.position().is_finite(), "Boundary search retains finite physical motion")
	world.queue_remove(dog)
	_step(world)
	var replacement: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(32, 32))
	var replacement_context: AgentContext = world.ai.inspect(replacement)
	_check(replacement_context == context, "Fixture really reuses the pooled context")
	_check(replacement_context.flock_search_observed_tick == -1 and replacement_context.flock_search_deadline_tick == 0 and replacement_context.flock_search_phase == AgentContext.FlockSearchPhase.FINISHED, "A reused life cannot inherit historical search eligibility or deadline")
	_close(world)
