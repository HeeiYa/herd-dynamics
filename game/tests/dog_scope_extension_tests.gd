extends SceneTree
## A focused maintainability example: existing stage-0 configuration changes
## the formal dog tree's pursuit boundary without editing motion or presentation.
## These small CPU worlds are contract fixtures, not capacity measurements.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_local_pursuit_configuration()
	print("DOG_SCOPE_EXTENSION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _world() -> SimulationWorld:
	var config := SimulationConfig.new()
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	world.setup(config, scenario)
	return world

func _step(world: SimulationWorld) -> void:
	world.ai.begin_frame()
	world.step()

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _test_local_pursuit_configuration() -> void:
	var world: SimulationWorld = _world()
	var independent_world: SimulationWorld = _world()
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(400, 500))
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(480, 500))
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(580, 500))
	var context: AgentContext = world.ai.inspect(dog)
	var original_intent: MotionIntent
	for step: int in 90:
		_step(world)
		var intent: MotionIntent = world.intents.get_intent(dog, world.tick - 1)
		if intent != null and intent.behavior == SimTypes.Behavior.INTERCEPT:
			original_intent = intent
			break
	_check(original_intent != null, "A registered dog intercepts a registered wolf through its formal tree")
	_check(world.ai.inspect(sheep) != null and world.ai.inspect(wolf) != null, "Stimulus animals retain their own ordinary behavior trees")
	if original_intent == null:
		_close(world)
		_close(independent_world)
		return
	var original_destination: Vector2 = original_intent.destination
	var original_anchor: Vector2 = context.protection_anchor
	_check(original_destination.distance_to(original_anchor) > 120.0, "Fixture has a pursuit target beyond the proposed shorter boundary")
	var original_perception_radius: float = world.config.perception_radius
	var original_protection_radius: float = world.ai.settings.protection_radius
	var original_budget: int = world.config.ai_budget_usec
	var tree: BTInstance = context.tree_instance()
	var original_limit: float = world.config.dog_leash_radius
	var change := TuningCatalog.Change.new(TuningCatalog.Param.DOG_LEASH_RADIUS, 120.0)
	_check(world.queue_tuning(change), "The existing named parameter accepts the shorter pursuit range")
	_check(world.config.dog_leash_radius == original_limit, "Queuing a range change does not write the world before stage 0")
	var applied_tick: int = world.tick
	_step(world)
	_check(world.config.dog_leash_radius == 120.0 and not world.has_pending_tuning(), "The next normal world step applies the new range once")
	var bounded_intent: MotionIntent
	var bounded_anchor: Vector2
	for step: int in 18:
		var intent: MotionIntent = world.intents.get_intent(dog, world.tick - 1)
		if intent != null and intent != original_intent and context.last_decision_tick >= applied_tick and intent.behavior == SimTypes.Behavior.INTERCEPT:
			bounded_intent = intent
			bounded_anchor = context.protection_anchor
			break
		_step(world)
	_check(bounded_intent != null, "A later ordinary decision publishes a fresh pursuit intent after tuning")
	if bounded_intent != null:
		_check(bounded_intent.destination.distance_to(bounded_anchor) <= 120.001, "Only the new dog's pursuit destination is clamped to its configured boundary")
		_check(bounded_intent.target != null and bounded_intent.target.same_life(wolf), "Range tuning keeps the complete observed target identity")
	_check(original_intent.destination == original_destination, "Changing policy does not mutate an already-published intent")
	_check(context.tree_instance() == tree, "Range tuning reuses the same running behavior tree instance")
	_check(world.config.perception_radius == original_perception_radius and world.ai.settings.protection_radius == original_protection_radius, "Pursuit range does not silently change sight or threat classification radius")
	_check(world.config.ai_budget_usec == original_budget, "The extension does not buy responsiveness with a larger AI budget")
	_check(independent_world.config.dog_leash_radius == original_limit, "A second world's configuration is not changed by the first world's command")
	_close(world)
	_close(independent_world)
