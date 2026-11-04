extends SceneTree
## Real BT/Interaction contract fixtures. Bodies stay fixed outside hit reach so
## retries can be checked without capture; production GPU trials remain separate.
var _checks: int = 0
var _failures: int = 0

class Fixture extends RefCounted:
	var world := SimulationWorld.new()
	var wolf: AgentHandle
	var sheep: AgentHandle
	var context: AgentContext

	func _init() -> void:
		var config := SimulationConfig.new()
		config.detached_ai = true
		config.ai_budget_usec = 6000
		var scenario := ScenarioConfig.new()
		scenario.sheep_count = 0
		scenario.wolf_count = 0
		scenario.dog_count = 0
		world.setup(config, scenario)
		wolf = world.create_at(SimTypes.Species.WOLF, Vector2(400, 400))
		var outside_hit_reach: float = config.agent_radius * 2.0 + config.attack_range + 1.0
		sheep = world.create_at(SimTypes.Species.SHEEP, Vector2(400 + outside_hit_reach, 400))
		context = world.ai.inspect(wolf)

	func decide(tick: int) -> MotionIntent:
		world.tick = tick
		context.current_tick = tick
		world.grid.rebuild(world.store)
		world.ai.perception.update(context, tick)
		world.ai.perception.prepare_decision(context, tick)
		context.update_tree(world.config.fixed_dt * 3.0)
		context.last_decision_tick = tick
		return world.intents.get_intent(wolf, tick)

	func step(tick: int) -> void:
		world.tick = tick
		if tick % 3 == 0:
			decide(tick)
		world.interaction.step(tick, world.config.fixed_dt)

	func advance_through(last_tick: int) -> void:
		for tick: int in range(last_tick + 1):
			step(tick)

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
	_test_continuous_retry_and_owned_replacement()
	_test_dog_preempts_renewed_attack()
	_test_handoff_and_feeding_after_retry()
	_test_target_lifecycle_after_retry()
	_test_hold_after_retry()
	print("ATTACK_RETRY_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_continuous_retry_and_owned_replacement() -> void:
	var fixture := Fixture.new()
	var accepted_ticks: Array[int] = []
	var previous_request_token: int = -1
	var first_intent: MotionIntent
	var empty_steps: int = 0
	for tick: int in range(180):
		fixture.step(tick)
		var intent: MotionIntent = fixture.world.intents.get_intent(fixture.wolf, tick)
		if tick >= 3:
			empty_steps += int(intent == null)
		if tick == 3:
			first_intent = intent
		var request: AttackRequest = fixture.world.interaction.get_attack(fixture.wolf)
		if request != null and request.owner_token != previous_request_token:
			accepted_ticks.append(request.accepted_tick)
			previous_request_token = request.owner_token
			_check(request.active_start_tick == tick + 12 and request.active_end_tick == tick + 22 and request.cooldown_until_tick == tick + 60, "Every renewed request retains authoritative 12/10/60 timing")
		if tick == 87 and first_intent != null:
			fixture.world.intents.clear_owned(fixture.wolf, first_intent.owner_token)
			_check(fixture.world.intents.get_intent(fixture.wolf, tick) == intent, "Old-token cleanup cannot erase the atomically replaced intent")
	_check(first_intent != null and first_intent.mode == SimTypes.IntentMode.ATTACK, "Real tree selects the initial attack after observing its prey")
	_check(empty_steps == 0, "Retry never creates a no-intent step between running attacks")
	_check(accepted_ticks == [3, 87, 171], "Retries retain the 82-tick attempt policy rounded to actual three-tick decisions")
	var final_intent: MotionIntent = fixture.world.intents.get_intent(fixture.wolf, 179)
	_check(final_intent != null and final_intent.owner_token == fixture.context.task_token and final_intent.owner_token > first_intent.owner_token, "One running leaf owns exactly its latest monotonic token")
	_check(first_intent.owner_token < final_intent.owner_token and first_intent.expires_tick < final_intent.expires_tick, "Replacing an attempt does not mutate an older published intent object")
	_check(fixture.world.store.is_alive(fixture.sheep), "Continuous pursuit does not turn a geometric miss into damage")
	fixture.close()

func _test_dog_preempts_renewed_attack() -> void:
	var fixture := Fixture.new()
	fixture.advance_through(90)
	var request: AttackRequest = fixture.world.interaction.get_attack(fixture.wolf)
	_check(request.accepted_tick == 87 and request.is_pending(), "Dog fixture begins inside a renewed windup")
	fixture.world.create_at(SimTypes.Species.DOG, Vector2(410, 400))
	var retreat: MotionIntent = fixture.decide(93)
	fixture.world.interaction.step(93, fixture.world.config.fixed_dt)
	_check(retreat != null and retreat.behavior == SimTypes.Behavior.RETREAT and retreat.mode == SimTypes.IntentMode.FLEE, "Dynamic priorities still interrupt a renewed attack for dog danger")
	_check(request.status == AttackRequest.Status.CANCELLED and request.cooldown_until_tick == 147, "Retreat cancels the accepted request without erasing cooldown")
	_check(retreat.owner_token == fixture.context.task_token and retreat.owner_token > request.owner_token, "Attack cleanup preserves the newer retreat intent")
	fixture.close()

func _test_handoff_and_feeding_after_retry() -> void:
	var fixture := Fixture.new()
	fixture.advance_through(90)
	var request: AttackRequest = fixture.world.interaction.get_attack(fixture.wolf)
	fixture.context.abort_tree()
	_check(fixture.world.intents.get_intent(fixture.wolf, 90) == null and request.is_pending(), "Final BT exit clears its latest intent while the accepted attack remains handed off")
	fixture.world.store.relocate(fixture.sheep, Vector2(441, 400))
	for tick: int in range(91, 100):
		fixture.world.interaction.step(tick, fixture.world.config.fixed_dt)
	_check(fixture.world.interaction.captures.size() == 1 and request.status == AttackRequest.Status.CAPTURED, "A handed-off renewed request can capture only inside its original active window")
	if not fixture.world.interaction.captures.is_empty():
		var event: CaptureEvent = fixture.world.interaction.captures[0]
		_check(event.tick == 100, "Renewed attack keeps the completed-step capture clock")
		fixture.world.ai.notify_capture(event.actor, event.position, event.tick + fixture.world.config.feed_ticks)
		var feed: MotionIntent = fixture.decide(102)
		_check(feed != null and feed.behavior == SimTypes.Behavior.FEED and feed.mode == SimTypes.IntentMode.STOP, "Capture permit still preempts pursuit after target death")
		fixture.world.create_at(SimTypes.Species.DOG, Vector2(410, 400))
		var retreat: MotionIntent = fixture.decide(105)
		_check(retreat != null and retreat.behavior == SimTypes.Behavior.RETREAT, "Dog safety remains above capture feeding in the actual tree")
	fixture.close()

func _test_target_lifecycle_after_retry() -> void:
	var fixture := Fixture.new()
	fixture.advance_through(90)
	var request: AttackRequest = fixture.world.interaction.get_attack(fixture.wolf)
	fixture.world.queue_remove(fixture.sheep)
	fixture.world._apply_commands()
	var replacement: AgentHandle = fixture.world.create_at(SimTypes.Species.SHEEP, Vector2(1000, 1000))
	var intent: MotionIntent = fixture.decide(93)
	_check(request.status == AttackRequest.Status.CANCELLED and request.target.same_life(fixture.sheep), "Target removal cancels the renewed request and preserves its old identity")
	_check(replacement.slot == fixture.sheep.slot and not replacement.same_life(fixture.sheep), "Target lifecycle fixture exercises a reused slot")
	_check(intent != null and intent.mode != SimTypes.IntentMode.ATTACK and fixture.world.store.is_alive(replacement), "Invalid prey exits the attack branch without transferring it to a replacement life")
	fixture.close()

func _test_hold_after_retry() -> void:
	var fixture := Fixture.new()
	fixture.advance_through(90)
	var request: AttackRequest = fixture.world.interaction.get_attack(fixture.wolf)
	fixture.world.queue_hold(fixture.wolf)
	fixture.world._apply_commands()
	_check(fixture.context.suspended and fixture.world.store.is_held(fixture.wolf), "Stage0 lifting still suspends the running tree")
	_check(fixture.world.intents.get_intent(fixture.wolf, 90) == null and request.status == AttackRequest.Status.CANCELLED, "Holding clears the newest token and cancels its pending handoff")
	_check(request.cooldown_until_tick == 147, "Observer lifting does not reset the renewed cooldown")
	fixture.world.queue_drop(fixture.wolf, Vector2(400, 400))
	fixture.world._apply_commands()
	_check(fixture.context.awaiting_resume_perception and fixture.world.intents.get_intent(fixture.wolf, 90) == null, "Drop cannot revive the latest attack before a fresh scan")
	fixture.close()
