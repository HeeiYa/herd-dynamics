extends SceneTree
## Boundary fixtures exercise the same production systems used by SimulationWorld.
var _checks: int = 0
var _failures: int = 0

class Fixture extends RefCounted:
	var config := SimulationConfig.new()
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	var resources: ResourceGrid
	var interaction := InteractionSystem.new()

	func _init() -> void:
		config.attack_windup_ticks = 2
		config.attack_window_ticks = 2
		config.attack_cooldown_ticks = 5
		config.hunger_rate = 0.0
		config.grass_recovery_rate = 0.0
		resources = ResourceGrid.new(config)
		interaction.setup(store, resources, intents, config)

	func attack(actor: AgentHandle, target: AgentHandle, token: int = 1, expiry: int = 100) -> void:
		var intent := MotionIntent.new()
		intent.mode = SimTypes.IntentMode.ATTACK
		intent.behavior = SimTypes.Behavior.ATTACK
		intent.target = target
		intent.owner_token = token
		intent.expires_tick = expiry
		intents.write(actor, intent)

	func graze(actor: AgentHandle, cell: int) -> void:
		var intent := MotionIntent.new()
		intent.mode = SimTypes.IntentMode.GRAZE
		intent.resource_cell = cell
		intent.expires_tick = 100
		intents.write(actor, intent)

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_competing_attacks()
	_test_swept_arbitration()
	_test_windup_and_handoff()
	_test_replay_cooldown_and_cancel()
	_test_target_and_actor_reuse()
	_test_proportional_grazing()
	print("INTERACTION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_competing_attacks() -> void:
	var fixture := Fixture.new()
	fixture.config.attack_windup_ticks = 0
	var first: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	var second: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	var prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(110, 100))
	fixture.attack(second, prey)
	fixture.attack(first, prey)
	fixture.interaction.step(0, fixture.config.fixed_dt)
	_check(fixture.interaction.captures.size() == 1 and fixture.interaction.deaths.size() == 1, "Competing attacks produce one capture and one death")
	if not fixture.interaction.captures.is_empty():
		var event: CaptureEvent = fixture.interaction.captures[0]
		_check(event.actor.same_life(first) and event.tick == 1, "Equal contacts use stable actor slot and publication tick")
	_check(not fixture.store.is_alive(prey), "Capture invalidates prey before lifecycle compaction")
	_check(is_zero_approx(fixture.store.hunger[fixture.store.resolve(first)]), "Winner receives nutrition once")
	_check(is_equal_approx(fixture.store.hunger[fixture.store.resolve(second)], 0.65), "Losing wolf receives no nutrition")
	fixture.interaction.step(1, fixture.config.fixed_dt)
	_check(fixture.interaction.captures.is_empty(), "Repeated intent cannot replay a successful capture")

func _test_swept_arbitration() -> void:
	var fixture := Fixture.new()
	fixture.config.attack_windup_ticks = 0
	var late: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(0, 100))
	var early: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(50, 100))
	var prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	fixture.store.position_next[fixture.store.resolve(late)] = Vector2(200, 100)
	fixture.store.position_next[fixture.store.resolve(early)] = Vector2(200, 100)
	fixture.attack(late, prey)
	fixture.attack(early, prey)
	fixture.interaction.step(0, fixture.config.fixed_dt)
	_check(fixture.interaction.captures.size() == 1, "Swept contact catches crossing paths whose endpoints are separated")
	if not fixture.interaction.captures.is_empty():
		_check(fixture.interaction.captures[0].actor.same_life(early), "Earlier contact beats smaller actor slot")

func _test_windup_and_handoff() -> void:
	var fixture := Fixture.new()
	var wolf: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(0, 100))
	var prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	var wolf_dense: int = fixture.store.resolve(wolf)
	fixture.store.position_next[wolf_dense] = Vector2(200, 100)
	fixture.attack(wolf, prey, 1, 1)
	fixture.interaction.step(0, fixture.config.fixed_dt)
	_check(fixture.interaction.captures.is_empty(), "Contact during windup cannot deal damage")
	fixture.intents.clear_owned(wolf, 1)
	fixture.store.position_current[wolf_dense] = Vector2(200, 100)
	fixture.interaction.step(1, fixture.config.fixed_dt)
	fixture.interaction.step(2, fixture.config.fixed_dt)
	_check(fixture.interaction.captures.is_empty(), "A pre-window crossing is not counted retroactively")
	_check(fixture.interaction.get_attack(wolf).active_start_tick == 2, "BT exit preserves accepted attack timeline")
	fixture.store.position_current[wolf_dense] = Vector2(0, 100)
	fixture.interaction.step(3, fixture.config.fixed_dt)
	_check(fixture.interaction.captures.size() == 1, "Accepted attack continues inside active window after intent exit")
	var expired := Fixture.new()
	var expired_wolf: AgentHandle = expired.store.create_agent(SimTypes.Species.WOLF, Vector2(0, 100))
	var expired_prey: AgentHandle = expired.store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	expired.attack(expired_wolf, expired_prey)
	for tick: int in range(4):
		expired.interaction.step(tick, expired.config.fixed_dt)
	expired.store.position_next[expired.store.resolve(expired_wolf)] = Vector2(200, 100)
	expired.interaction.step(4, expired.config.fixed_dt)
	_check(expired.interaction.captures.is_empty() and expired.interaction.get_attack(expired_wolf).status == AttackRequest.Status.MISSED, "Active window end is exclusive")

func _test_replay_cooldown_and_cancel() -> void:
	var fixture := Fixture.new()
	var wolf: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(0, 100))
	var prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	fixture.attack(wolf, prey)
	fixture.interaction.step(0, fixture.config.fixed_dt)
	fixture.attack(wolf, prey)
	fixture.interaction.step(1, fixture.config.fixed_dt)
	_check(fixture.interaction.get_attack(wolf).active_start_tick == 2, "Reissuing one token does not restart windup")
	fixture.interaction.cancel(wolf)
	fixture.attack(wolf, prey, 2)
	fixture.interaction.step(4, fixture.config.fixed_dt)
	_check(fixture.interaction.get_attack(wolf).owner_token == 1, "Cancellation retains cooldown")
	fixture.interaction.step(5, fixture.config.fixed_dt)
	_check(fixture.interaction.get_attack(wolf).owner_token == 2 and fixture.interaction.get_attack(wolf).active_start_tick == 7, "New request begins at its actual acceptance tick")
	var retreat := MotionIntent.new()
	retreat.mode = SimTypes.IntentMode.FLEE
	retreat.behavior = SimTypes.Behavior.RETREAT
	retreat.expires_tick = 100
	fixture.intents.write(wolf, retreat)
	fixture.interaction.step(6, fixture.config.fixed_dt)
	_check(fixture.interaction.get_attack(wolf).status == AttackRequest.Status.CANCELLED, "Retreat explicitly cancels accepted request")
	fixture.attack(wolf, prey, 1)
	fixture.interaction.step(20, fixture.config.fixed_dt)
	_check(fixture.interaction.get_attack(wolf).owner_token == 2, "Old token remains rejected after cooldown expires")
	fixture.attack(wolf, prey, 3, 21)
	fixture.interaction.step(21, fixture.config.fixed_dt)
	_check(fixture.interaction.get_attack(wolf).owner_token == 2, "Expired request is never accepted")

func _test_target_and_actor_reuse() -> void:
	var fixture := Fixture.new()
	var wolf: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	var prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(110, 100))
	fixture.attack(wolf, prey)
	fixture.interaction.step(0, fixture.config.fixed_dt)
	fixture.interaction.remove(prey)
	fixture.store.remove_agent(prey)
	var replacement: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(110, 100))
	_check(replacement.slot == prey.slot and fixture.interaction.get_attack(wolf).status == AttackRequest.Status.CANCELLED, "Target removal cancels requests during the same lifecycle phase")
	fixture.interaction.step(2, fixture.config.fixed_dt)
	_check(fixture.store.is_alive(replacement), "An old target handle cannot capture a replacement life")
	fixture.interaction.remove(wolf)
	fixture.store.remove_agent(wolf)
	var new_wolf: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	fixture.attack(new_wolf, replacement, 1)
	fixture.interaction.step(3, fixture.config.fixed_dt)
	_check(fixture.interaction.get_attack(new_wolf).accepted_tick == 3, "Actor reuse starts a fresh token and cooldown lifetime")
	_check(fixture.interaction.get_attack(wolf) == null, "Old actor cannot inspect replacement request")
	fixture.interaction.reset()
	fixture.store.reset()
	_check(fixture.interaction.get_attack(new_wolf) == null, "World reset drops attack history")

func _test_proportional_grazing() -> void:
	var fixture := Fixture.new()
	fixture.config.grazing_rate = 1.0
	var cell: int = 0
	var center: Vector2 = fixture.resources.cell_center(cell)
	var hungry: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, center)
	var content: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, center)
	var distant: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, center + Vector2(300, 0))
	fixture.store.hunger[fixture.store.resolve(hungry)] = 0.8
	fixture.store.hunger[fixture.store.resolve(content)] = 0.2
	var initial: float = fixture.resources.get_effective_amount(cell, 0)
	fixture.resources.consume(cell, initial - 0.1, 0)
	fixture.graze(hungry, cell)
	fixture.graze(content, cell)
	fixture.graze(distant, cell)
	fixture.interaction.step(1, 1.0)
	_check(absf(fixture.store.hunger[fixture.store.resolve(hungry)] - 0.72) < 0.00001, "Scarce grass is allocated in proportion to hungry demand")
	_check(absf(fixture.store.hunger[fixture.store.resolve(content)] - 0.18) < 0.00001, "Smaller demand receives the same fulfillment ratio")
	_check(is_equal_approx(fixture.store.hunger[fixture.store.resolve(distant)], 0.65), "Distant sheep cannot consume grass through stale intent")
	_check(absf(fixture.interaction.grass_consumed - 0.1) < 0.00001 and is_zero_approx(fixture.resources.get_effective_amount(cell, 2)), "Grass never overdraws the available quantity")
	_check(absf(fixture.resources.get_effective_amount(cell, 1) - 0.1) < 0.00001, "Aggregate grazing preserves the pre-commit display snapshot")
