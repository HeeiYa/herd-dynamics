extends SceneTree
## The selected-life projection and its card must remain historical, owned data.
var _checks: int = 0
var _failures: int = 0
var _card: AgentInspector
var _presenter: AgentInspectorPresenter
var _hud: ObserverHud
var _capture_base: String = ""

func _initialize() -> void:
	call_deferred(&"_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

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

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _access(world: SimulationWorld, inspection: AgentInspection) -> SimulationAccess:
	var access := SimulationAccess.new()
	access.publication = SimulationPublication.new()
	access.publication.store = world.store.publication_copy()
	access.publication.intents = world.intents.publication_copy()
	access.publication.config = world.config.duplicate() as SimulationConfig
	access.publication.tick = world.tick
	access.publication.inspection = inspection
	return access

func _sighting(target: AgentHandle, position: Vector2, observed_tick: int, expires_tick: int, source: LocalObservation.Source) -> LocalObservation:
	var sighting := LocalObservation.new()
	sighting.handle = target
	sighting.species = SimTypes.Species.SHEEP
	sighting.position = position
	sighting.observed_tick = observed_tick
	sighting.last_direct_tick = observed_tick
	sighting.expires_tick = expires_tick
	sighting.source = source
	return sighting

func _summary(access: SimulationAccess, handle: AgentHandle) -> String:
	_presenter.refresh(access, handle)
	return _card._summary.text

func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_capture_base = argument.trim_prefix("--capture=").get_basename()
	_hud = preload("res://scenes/ui/observer_hud.tscn").instantiate() as ObserverHud
	root.add_child(_hud)
	await process_frame
	_hud.toggle_panel()
	_card = _hud.inspector
	_presenter = AgentInspectorPresenter.new(_card)
	await _test_wolf_lease_evidence()
	await _test_dog_sample_and_search()
	_test_missing_context_and_legacy_evidence()
	_check(_card._summary.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "The explanatory card wraps inside the observer sidebar")
	_hud.free()
	print("AGENT_INSPECTION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_wolf_lease_evidence() -> void:
	var world: SimulationWorld = _world()
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(100, 100))
	var current_target: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(150, 100))
	var lease_target: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(200, 100))
	var context: AgentContext = world.ai.inspect(wolf)
	context.last_perception_tick = 10
	context.current_tick = 15
	context.task_name = &"hunt_prey"
	var direct: LocalObservation = _sighting(current_target, Vector2(140, 110), 10, 130, LocalObservation.Source.DIRECT)
	var shared: LocalObservation = _sighting(lease_target, Vector2(180, 120), 20, 40, LocalObservation.Source.SHARED)
	shared.last_direct_tick = 5
	context.observations[current_target.slot] = direct
	context.observations[lease_target.slot] = shared
	var intent := MotionIntent.new()
	intent.mode = SimTypes.IntentMode.MOVE
	intent.behavior = SimTypes.Behavior.CHASE
	intent.target = current_target
	intent.destination = direct.position
	intent.expires_tick = 130
	intent.reason = "private developer detail"
	world.intents.write(wolf, intent)
	world.ai.coordination.request(wolf, lease_target, CoordinationSystem.Kind.HUNT, 7, Vector2(100, 100), 29)
	world.ai.coordination.begin_step(30)
	world.tick = 30
	var query_count: int = world.grid.candidate_count
	var inspection: AgentInspection = AgentInspection.capture(world, wolf)
	_check(inspection.sighting.handle.same_life(current_target) and inspection.lease_sighting.handle.same_life(lease_target), "Motion and lease targets retain their separate local observations")
	_check(inspection.sighting.source == LocalObservation.Source.DIRECT and inspection.sighting.last_direct_tick == 10, "Direct evidence retains its provenance in the UI copy")
	_check(inspection.lease_sighting.source == LocalObservation.Source.SHARED and inspection.lease_sighting.last_direct_tick == 5, "Shared evidence does not become direct during inspection")
	_check(context.current_tick == 15 and world.grid.candidate_count == query_count, "Inspection does not advance AI time or issue a spatial query")
	var access: SimulationAccess = _access(world, inspection)
	var text: String = _summary(access, wolf)
	_check(text.contains("主追") and text.contains("同伴转告") and text.contains("亲眼看到"), "Main summary explains role and distinct observation sources")
	_check(text.contains("目标") and text.contains("羊 #%d" % (lease_target.slot + 1)), "The lease target is identifiable without querying its current location")
	_check(not text.contains("hunt_prey") and not text.contains(intent.reason), "Implementation names and raw reasons stay outside the main explanation")
	_check(_card._details.text.contains(wolf.key()) and _card._details.text.contains(intent.reason), "Full identity and raw reason remain available in diagnostics")
	await _capture_card("wolf-main")
	var source_lease: CoordinationSystem.Lease = world.ai.coordination.get_lease(wolf, 30)
	source_lease.role = CoordinationSystem.Role.LEFT
	shared.position = Vector2(1500, 900)
	direct.source = LocalObservation.Source.SHARED
	_check(inspection.lease.role == CoordinationSystem.Role.MAIN and inspection.lease_sighting.position == Vector2(180, 120), "Older inspection owns its lease and sighting values")
	_check(inspection.sighting.source == LocalObservation.Source.DIRECT, "Later live knowledge changes do not rewrite a previous card")
	world.store.position_current[world.store.resolve(lease_target)] = Vector2(1590, 990)
	_check(_summary(access, wolf) == text, "Invisible target movement cannot change a frozen explanation")
	var replacement := AgentHandle.new(lease_target.slot, lease_target.generation + 1, lease_target.world_epoch)
	_check(inspection.lease_observation_for(replacement, 30) == null, "A reused slot cannot borrow another life's lease observation")
	access.publication.tick = 40
	_check(_summary(access, wolf).contains("暂无有效观察"), "A lease can remain valid after its historical target evidence expires")
	access.publication.tick = inspection.lease.expires_tick
	_check(_summary(access, wolf).contains("分工已到期"), "The card expires a lease at its exact simulation deadline")
	for role: int in [CoordinationSystem.Role.LEFT, CoordinationSystem.Role.RIGHT]:
		source_lease.role = role
		var flank: AgentInspection = AgentInspection.capture(world, wolf)
		var flank_access: SimulationAccess = _access(world, flank)
		var expected: String = "左侧包抄" if role == CoordinationSystem.Role.LEFT else "右侧包抄"
		_check(_summary(flank_access, wolf).contains(expected), "Flank role is visible without opening technical details")
	_close(world)

func _test_dog_sample_and_search() -> void:
	var world: SimulationWorld = _world()
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(500, 500))
	var context: AgentContext = world.ai.inspect(dog)
	context.task_name = &"search_last_flock"
	context.last_perception_tick = 10
	context.flock_sample_observed_tick = 10
	context.flock_sample_expires_tick = 20
	context.flock_sample_count = 4
	context.flock_count = 99 # Deliberately stale derived facts must not become live UI claims.
	context.last_flock_seen_tick = 10
	context.protection_anchor = Vector2(540, 500)
	context.flock_search_observed_tick = 10
	context.flock_search_phase = AgentContext.FlockSearchPhase.TO_ANCHOR
	context.flock_search_deadline_tick = 100
	var intent := MotionIntent.new()
	intent.mode = SimTypes.IntentMode.MOVE
	intent.behavior = SimTypes.Behavior.SEARCH
	intent.destination = context.protection_anchor
	intent.expires_tick = 160
	world.intents.write(dog, intent)
	world.tick = 19
	var inspection: AgentInspection = AgentInspection.capture(world, dog)
	var access: SimulationAccess = _access(world, inspection)
	var text: String = _summary(access, dog)
	_check(inspection.flock_evidence_count == 4 and text.contains("4 只羊") and not text.contains("99"), "Protection shows the actual bounded sample instead of stale derived facts")
	_check(inspection.flock_count == 99, "The existing overlay fact remains distinct from the card's historical sample")
	_check(text.contains("局部样本") and text.contains("不是固定羊群"), "A local group sample is not presented as a persistent flock identity")
	await _capture_card("dog-protection")
	access.publication.tick = 20
	text = _summary(access, dog)
	_check(text.contains("记录已过期") and text.contains("返回最后记录的位置"), "Sample expiry is checked against display-world time without advancing AI")
	_check(text.contains("剩余 1.3 模拟秒") and text.contains("历史线索"), "Historical search reports its real phase and bounded simulation time")
	await _capture_card("dog-return")
	await process_frame
	_check(_summary(access, dog) == text, "A paused world does not count down search time using render frames")
	context.flock_search_phase = AgentContext.FlockSearchPhase.LOCAL_SWEEP
	context.flock_search_deadline_tick = 200
	_check(inspection.flock_search_phase == AgentContext.FlockSearchPhase.TO_ANCHOR and inspection.flock_search_deadline_tick == 100, "An older publication retains its own historical search phase and deadline")
	world.tick = 20
	var sweep_access: SimulationAccess = _access(world, AgentInspection.capture(world, dog))
	_check(_summary(sweep_access, dog).contains("在旧位置附近寻找"), "The local search phase has a distinct human-readable explanation")
	await _capture_card("dog-search")
	sweep_access.publication.tick = 160
	text = _summary(sweep_access, dog)
	_check(text.contains("等待决策") and text.contains("最近判断") and text.contains("等待新意图"), "A retained search phase does not claim current movement after its intent expires")
	sweep_access.publication.tick = 200
	text = _summary(sweep_access, dog)
	_check(text.contains("寻找已到期") and not text.contains("剩余 -"), "Expired search is not displayed as continuing or as negative time")
	sweep_access.publication.store.set_held(dog, true)
	_check(_summary(sweep_access, dog).contains("暂不执行寻找"), "Held animals are not described as actively searching")
	context.task_name = &"search_area"
	context.flock_search_phase = AgentContext.FlockSearchPhase.FINISHED
	context.last_flock_searched_tick = 10
	context.flock_sample_count = 0
	context.flock_sample_observed_tick = 20
	context.flock_sample_expires_tick = 140
	var finished_access: SimulationAccess = _access(world, AgentInspection.capture(world, dog))
	text = _summary(finished_access, dog)
	_check(text.contains("最近扫描没有发现羊") and text.contains("旧线索已查找完"), "An empty new scan does not pretend that the old flock is still protected")
	_close(world)

func _test_missing_context_and_legacy_evidence() -> void:
	var world: SimulationWorld = _world()
	var dog: AgentHandle = world.create_at(SimTypes.Species.DOG, Vector2(500, 500))
	var context: AgentContext = world.ai.inspect(dog)
	var access: SimulationAccess = _access(world, AgentInspection.capture(world, dog))
	_check(_summary(access, dog).contains("尚未观察到"), "A new dog does not invent a protection group or historical search")
	world.config.compact_flock_knowledge = false
	context.task_name = &"unexpected_internal_task"
	context.last_perception_tick = 10
	context.flock_count = 3
	context.flock_cache_expires_tick = 100
	world.tick = 20
	access = _access(world, AgentInspection.capture(world, dog))
	var text: String = _summary(access, dog)
	_check(text.contains("局部记忆汇总") and not text.contains("亲眼看到的局部样本"), "The legacy individual-memory mode is not relabeled as a direct group sample")
	_check(not text.contains("unexpected_internal_task"), "Unknown implementation identifiers stay in diagnostic details")
	access.publication.inspection = null
	_check(_summary(access, dog).contains("等待决策"), "A published body without AI inspection still renders a useful card")
	access.publication.store.remove_agent(dog)
	_presenter.refresh(access, dog)
	_check(_card._empty.visible and not _card._summary.visible, "An expired selected life returns to the empty card")
	_close(world)

func _capture_card(label: String) -> void:
	if _capture_base.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		_check(false, "Card captures require a rendered viewport")
		return
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var picture: Image = root.get_texture().get_image()
	_check(picture.save_png(_capture_base + "-" + label + ".png") == OK, "Rendered inspector card is saved")
