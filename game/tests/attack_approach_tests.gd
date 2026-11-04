extends SceneTree
## Geometry/visibility boundary fixtures. Real production behavior is measured
## separately by the unchanged worker/GPU hunt protocol and normal timers.
const CheckFact = preload("res://scripts/ai/tasks/check_fact.gd")
var _checks: int = 0
var _failures: int = 0

class Fixture extends RefCounted:
	var world := SimulationWorld.new()
	var wolf: AgentHandle
	var sheep: AgentHandle
	var context: AgentContext
	var condition := CheckFact.new()

	func _init(radius: float = 13.0) -> void:
		var config := SimulationConfig.new()
		config.agent_radius = radius
		config.detached_ai = true
		config.ai_budget_usec = 6000
		var scenario := ScenarioConfig.new()
		scenario.sheep_count = 0
		scenario.wolf_count = 0
		scenario.dog_count = 0
		world.setup(config, scenario)
		wolf = world.create_at(SimTypes.Species.WOLF, Vector2(400, 400))
		sheep = world.create_at(SimTypes.Species.SHEEP, Vector2(440, 400))
		context = world.ai.inspect(wolf)
		condition.context = context
		condition.fact = CheckFact.Fact.ATTACK_RANGE

	func observe(distance: float, tick: int = 10) -> void:
		world.store.relocate(sheep, Vector2(400 + distance, 400))
		world.grid.rebuild(world.store)
		world.ai.perception.update(context, tick)
		context.prey = context.observation_for(sheep, tick)

	func contact_reach() -> float:
		return world.config.agent_radius * 2.0 + world.config.attack_range

	func close() -> void:
		world.motion.close()
		world.ai.reset()
		world.free()

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)

func _run() -> void:
	_test_surface_units_and_boundaries()
	_test_recorded_position_and_visibility()
	_test_lifecycle_and_reuse()
	_test_normal_windup_and_surface_contact()
	_test_approach_does_not_expand_hit_reach()
	print("ATTACK_APPROACH_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_surface_units_and_boundaries() -> void:
	for radius: float in [6.0, 13.0, 20.0]:
		var fixture := Fixture.new(radius)
		var approach: float = fixture.contact_reach() + fixture.world.ai.settings.attack_approach_margin
		_check(fixture.world.store.radius[fixture.world.store.resolve(fixture.wolf)] == radius and fixture.world.store.radius[fixture.world.store.resolve(fixture.sheep)] == radius, "Production creation uses the declared uniform physical radius")
		fixture.observe(approach - 0.01)
		_check(fixture.condition._holds(), "Approach is allowed just inside surface reach plus the existing margin")
		fixture.observe(approach)
		_check(fixture.condition._holds(), "Approach boundary includes equality in center-distance units")
		fixture.observe(approach + 0.01)
		_check(not fixture.condition._holds(), "Approach rejects a target just beyond the declared center-distance boundary")
		fixture.observe(fixture.contact_reach())
		_check(fixture.condition._holds(), "A directly observed contact opportunity is not blocked by missing body radii")
		fixture.close()

func _test_recorded_position_and_visibility() -> void:
	var fixture := Fixture.new()
	fixture.observe(100.0)
	fixture.world.store.relocate(fixture.sheep, Vector2(410, 400))
	_check(not fixture.condition._holds(), "An unseen live target moving close cannot bypass the recorded far position")
	fixture.observe(40.0, 20)
	fixture.world.store.relocate(fixture.sheep, Vector2(1200, 800))
	_check(fixture.condition._holds(), "The approach guard uses the last observed position, not a hidden current coordinate")
	fixture.context.last_perception_tick = 21
	fixture.context.current_tick = 21
	_check(not fixture.condition._holds(), "A newer scan that did not see the prey invalidates direct-visibility eligibility")
	fixture.context.last_perception_tick = 20
	fixture.context.current_tick = 20 + fixture.world.config.memory_ticks
	_check(not fixture.condition._holds(), "The exact direct-memory and observation expiry boundary rejects approach")
	fixture.observe(40.0, 30)
	fixture.context.prey.last_direct_tick = -1
	fixture.context.prey.source = LocalObservation.Source.SHARED
	_check(not fixture.condition._holds(), "Shared-only knowledge cannot authorize the direct attack approach branch")
	fixture.close()

func _test_lifecycle_and_reuse() -> void:
	var fixture := Fixture.new()
	fixture.observe(40.0)
	fixture.world.store.set_held(fixture.sheep, true)
	_check(not fixture.condition._holds(), "Held target is not an active attack opportunity")
	fixture.world.store.set_held(fixture.sheep, false)
	_check(fixture.condition._holds(), "Restored target still needs the original valid direct observation")
	var retired: AgentHandle = fixture.sheep
	fixture.world.queue_remove(retired)
	fixture.world._apply_commands()
	_check(not fixture.condition._holds(), "Removed full identity cannot authorize approach")
	var replacement: AgentHandle = fixture.world.create_at(SimTypes.Species.SHEEP, Vector2(410, 400))
	_check(replacement.slot == retired.slot and not replacement.same_life(retired), "Boundary fixture reuses the slot with a new generation")
	_check(not fixture.condition._holds(), "New close life does not inherit the retired target's visibility")
	fixture.close()

func _issue_attack(fixture: Fixture) -> void:
	var intent := MotionIntent.new()
	intent.mode = SimTypes.IntentMode.ATTACK
	intent.behavior = SimTypes.Behavior.ATTACK
	intent.target = fixture.sheep
	intent.owner_token = 1
	intent.expires_tick = 1000
	fixture.world.intents.write(fixture.wolf, intent)

func _test_normal_windup_and_surface_contact() -> void:
	var fixture := Fixture.new()
	fixture.observe(fixture.contact_reach() - 0.01, 0)
	_check(fixture.condition._holds(), "BT approach admits a physically reachable center distance outside the old 32px gate")
	var config: SimulationConfig = fixture.world.config
	_check(config.attack_windup_ticks == 12 and config.attack_window_ticks == 10 and config.attack_cooldown_ticks == 60, "Normal attack timing remains 12/10/60")
	_issue_attack(fixture)
	for tick: int in config.attack_windup_ticks:
		fixture.world.interaction.step(tick, config.fixed_dt)
		_check(fixture.world.interaction.captures.is_empty(), "Approach never skips the real windup")
	fixture.world.interaction.step(config.attack_windup_ticks, config.fixed_dt)
	_check(fixture.world.interaction.captures.size() == 1, "Original swept contact captures inside the unchanged sum-of-radii reach")
	if not fixture.world.interaction.captures.is_empty():
		_check(fixture.world.interaction.captures[0].tick == 13, "Capture retains the completed n+1 event clock")
	fixture.world.interaction.step(config.attack_windup_ticks + 1, config.fixed_dt)
	_check(fixture.world.interaction.captures.is_empty(), "The unchanged interaction cannot replay one captured life")
	fixture.close()

func _test_approach_does_not_expand_hit_reach() -> void:
	var fixture := Fixture.new()
	fixture.observe(fixture.contact_reach() + 1.0, 0)
	_check(fixture.condition._holds(), "Approach margin may admit an attempt before physical contact")
	_issue_attack(fixture)
	var config: SimulationConfig = fixture.world.config
	for tick: int in range(config.attack_windup_ticks + config.attack_window_ticks + 1):
		fixture.world.interaction.step(tick, config.fixed_dt)
		_check(fixture.world.interaction.captures.is_empty(), "A stationary target outside physical reach remains unhit throughout the active window")
	_check(fixture.world.interaction.get_attack(fixture.wolf).status == AttackRequest.Status.MISSED, "Natural misses remain valid outcomes; approach is not a hit guarantee")
	fixture.close()
