extends SceneTree
## Observer-facing contracts: hold/drop commands, natural spawn plans, runtime
## tuning, camera conversions and the read-only explanation layer.
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
	await _test_hold_and_drop()
	await _test_hold_cancels_attack_and_lease()
	await _test_hold_lifecycle_edges()
	_test_spawn_plans()
	await _test_planned_world_reset()
	await _test_tuning_commands()
	_test_camera_conversions()
	await _test_insight_marks_and_knowledge()
	print("OBSERVER_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _empty_world(config: SimulationConfig = null) -> SimulationWorld:
	if config == null:
		config = SimulationConfig.new()
	config.ai_budget_usec = 100000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	return world

func _step(world: SimulationWorld, count: int = 1) -> void:
	for index: int in count:
		world.ai.begin_frame()
		world.step()

func _test_hold_and_drop() -> void:
	var world: SimulationWorld = _empty_world()
	await process_frame
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(400, 400))
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(470, 400))
	_step(world, 30)
	var hunger_before: float = world.store.hunger[world.store.resolve(sheep)]
	world.queue_hold(sheep)
	_check(not world.store.is_held(sheep) and world.is_hold_pending(sheep), "Hold waits for the next stage 0")
	_step(world)
	_check(world.store.is_held(sheep) and world.store.is_alive(sheep), "Held life keeps its full identity")
	_check(not world.store.is_active(sheep), "Held life is not active in the pasture")
	_check(world.intents.get_intent(sheep, world.tick) == null, "Holding clears the life's intent")
	var context: AgentContext = world.ai.inspect(sheep)
	_check(context.suspended and not context.player.active, "Holding suspends the behavior tree")
	var held_position: Vector2 = world.store.position_current[world.store.resolve(sheep)]
	var perception_before: int = context.last_perception_tick
	_step(world, 40)
	_check(world.store.position_current[world.store.resolve(sheep)] == held_position, "Motion leaves a held body in place")
	_check(context.last_perception_tick == perception_before, "No perception job runs while held")
	_check(world.store.hunger[world.store.resolve(sheep)] > hunger_before, "Hunger keeps advancing while held")
	var wolf_context: AgentContext = world.ai.inspect(wolf)
	_check(wolf_context.observation_for(sheep) == null, "Nobody perceives a held body")
	var probe: Array[int] = []
	world.grid.query(held_position, 50.0, SimTypes.Species.SHEEP, world.store, probe)
	_check(probe.is_empty(), "Spatial grid excludes held bodies")
	_check(world.held_counts()[SimTypes.Species.SHEEP] == 1 and world.counts()[SimTypes.Species.SHEEP] == 1, "Held lives are counted alive and held separately")
	var drop_at := Vector2(1200, 700)
	world.queue_drop(sheep, drop_at)
	_check(world.store.is_held(sheep), "Drop waits for the next stage 0")
	var drop_tick: int = world.tick
	_step(world)
	var dense: int = world.store.resolve(sheep)
	_check(not world.store.is_held(sheep) and world.store.is_active(sheep), "Drop returns the life to the pasture")
	_check(world.store.position_previous[dense] == drop_at, "Drop relocates without a display interpolation jump")
	_check(not context.suspended and context.player.active, "Drop resumes the behavior tree")
	_check(context.last_perception_tick == drop_tick, "First job after a drop is a fresh perception scan")
	_step(world, 3)
	_check(world.intents.get_intent(sheep, world.tick) != null, "Original BT writes a new intent after the drop")
	world.queue_drop(sheep, Vector2(10, 10))
	_step(world)
	_check(world.store.position_current[world.store.resolve(sheep)] != Vector2(13, 13), "A drop for a life that is not held is ignored")
	world.queue_free()
	await process_frame

func _test_hold_cancels_attack_and_lease() -> void:
	var world: SimulationWorld = _empty_world()
	await process_frame
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(400, 400))
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(420, 400))
	# Inject an accepted attack against the sheep through the normal intent path.
	var intent := MotionIntent.new()
	intent.mode = SimTypes.IntentMode.ATTACK
	intent.behavior = SimTypes.Behavior.ATTACK
	intent.target = sheep
	intent.owner_token = 99
	intent.destination = Vector2(400, 400)
	intent.expires_tick = world.tick + 200
	world.intents.write(wolf, intent)
	world.interaction.step(world.tick, world.config.fixed_dt)
	var attack: AttackRequest = world.interaction.get_attack(wolf)
	_check(attack != null and attack.is_pending(), "Fixture creates a pending attack")
	world.ai.coordination.request(wolf, sheep, CoordinationSystem.Kind.HUNT, 7, Vector2(420, 400), world.tick - 1)
	world.ai.coordination.begin_step(world.tick)
	_check(world.ai.coordination.get_lease(wolf, world.tick) != null, "Fixture grants a hunt lease")
	world.queue_hold(sheep)
	var captures_before: int = world.capture_count
	_step(world, 60)
	_check(attack.status == AttackRequest.Status.CANCELLED, "Lifting the target cancels a pending attack")
	_check(world.capture_count == captures_before, "A held sheep cannot be captured")
	_check(world.ai.coordination.get_lease(wolf, world.tick) == null or not world.ai.coordination.get_lease(wolf, world.tick).target.same_life(sheep), "Hunt reservations on a held target are released")
	world.queue_drop(sheep, Vector2(1400, 900))
	world.queue_hold(wolf)
	_step(world)
	_check(world.store.is_held(wolf) and world.interaction.get_attack(wolf) != null, "Lifting the actor keeps its attack record and cooldown")
	world.queue_free()
	await process_frame

func _test_hold_lifecycle_edges() -> void:
	var world: SimulationWorld = _empty_world()
	await process_frame
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(300, 300))
	world.queue_hold(sheep)
	_check(world.cancel_pending_hold(sheep) and not world.is_hold_pending(sheep), "A pending hold can be withdrawn before stage 0")
	_step(world)
	_check(not world.store.is_held(sheep), "Withdrawn hold never applies")
	world.queue_hold(sheep)
	world.queue_drop(sheep, Vector2(600, 600))
	_step(world)
	_check(world.store.is_active(sheep) and world.store.position_current[world.store.resolve(sheep)] == Vector2(600, 600), "Hold and drop in one frame apply in order")
	world.queue_hold(sheep)
	_step(world)
	world.queue_remove(sheep)
	_step(world)
	_check(world.store.held_count == 0, "Removing a held life clears the held count")
	var recycled: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(500, 500))
	_check(recycled.slot == sheep.slot and not recycled.same_life(sheep), "Fixture recycles the slot")
	world.queue_drop(sheep, Vector2(50, 50))
	world.queue_hold(sheep)
	_step(world)
	_check(world.store.is_active(recycled) and not world.store.is_held(recycled), "Stale hold and drop never act on a recycled slot")
	world.queue_hold(recycled)
	_step(world)
	world.reset(world.scenario)
	_check(world.store.held_count == 0 and not world.store.is_alive(recycled), "Reset releases all held state with the old epoch")
	world.queue_free()
	await process_frame

func _plan(layout: ScenarioConfig.Layout, seed_value: int, sheep: int, wolves: int, dogs: int) -> SpawnPlanner:
	var scenario := ScenarioConfig.new()
	scenario.layout = layout
	scenario.random_seed = seed_value
	scenario.sheep_count = sheep
	scenario.wolf_count = wolves
	scenario.dog_count = dogs
	return SpawnPlanner.new(SimulationConfig.new(), scenario)

func _drain(planner: SpawnPlanner) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for species: int in range(3):
		var positions := PackedVector2Array()
		for index: int in planner.planned_counts[species]:
			positions.append(planner.next_position(species))
		result.append(positions)
	return result

func _test_spawn_plans() -> void:
	var config := SimulationConfig.new()
	var bounds := Rect2(Vector2.ZERO, config.world_size)
	for layout: ScenarioConfig.Layout in [ScenarioConfig.Layout.NATURAL, ScenarioConfig.Layout.SCATTERED, ScenarioConfig.Layout.HERDS_AND_THREATS]:
		for counts: Array in [[40, 4, 2], [1000, 12, 6], [0, 3, 1], [1, 0, 0]]:
			var first: SpawnPlanner = _plan(layout, 42, counts[0], counts[1], counts[2])
			var second: SpawnPlanner = _plan(layout, 42, counts[0], counts[1], counts[2])
			var first_positions: Array[PackedVector2Array] = _drain(first)
			_check(first_positions == _drain(second), "Same seed and configuration reproduce the plan")
			for species: int in range(3):
				_check(first_positions[species].size() == counts[species], "Plan provides every requested body")
				for point: Vector2 in first_positions[species]:
					_check(bounds.has_point(point), "Planned bodies stay inside the pasture")
			if counts[0] >= 40:
				_check(first.herds.size() >= 2, "Larger flocks form several herds")
				_check(_crowded_fraction(first_positions[0], config.agent_radius) < 0.05, "Initial overlap is not the norm")
			if counts[1] > 0 and counts[0] > 0:
				_check(_nearest(first_positions[1], first_positions[0]) > config.perception_radius * 0.5, "Wolves start with room to develop behavior")
	var other_seed: Array[PackedVector2Array] = _drain(_plan(ScenarioConfig.Layout.NATURAL, 43, 40, 4, 2))
	_check(other_seed != _drain(_plan(ScenarioConfig.Layout.NATURAL, 42, 40, 4, 2)), "Different seeds change the plan")
	var started: int = Time.get_ticks_msec()
	var crowded: SpawnPlanner = _plan(ScenarioConfig.Layout.NATURAL, 7, 5000, 20, 10)
	_check(crowded.density_scale > 1.0, "Requests beyond the target density raise density instead of failing")
	_check(Time.get_ticks_msec() - started < 15000, "Bounded placement search finishes for 5000 sheep")
	_check(not crowded.describe().is_empty(), "Planner explains its density")
	for layout: ScenarioConfig.Layout in [ScenarioConfig.Layout.PASTURE, ScenarioConfig.Layout.TWO_FLOCKS, ScenarioConfig.Layout.CROWDED]:
		_check(not ScenarioConfig.is_planned(layout), "V1 benchmark layouts keep their legacy placement")

func _crowded_fraction(points: PackedVector2Array, body_radius: float) -> float:
	if points.size() < 2:
		return 0.0
	var crowded: int = 0
	var cells: Dictionary[Vector2i, PackedInt32Array] = {}
	var width: float = body_radius * 2.0
	for index: int in points.size():
		var cell := Vector2i(floori(points[index].x / width), floori(points[index].y / width))
		var members: PackedInt32Array = cells.get(cell, PackedInt32Array())
		members.append(index)
		cells[cell] = members
	for index: int in points.size():
		var cell := Vector2i(floori(points[index].x / width), floori(points[index].y / width))
		var overlapping: bool = false
		for y: int in range(cell.y - 1, cell.y + 2):
			for x: int in range(cell.x - 1, cell.x + 2):
				for other: int in cells.get(Vector2i(x, y), PackedInt32Array()):
					if other != index and points[index].distance_to(points[other]) < body_radius:
						overlapping = true
		if overlapping:
			crowded += 1
	return float(crowded) / points.size()

func _nearest(from: PackedVector2Array, to: PackedVector2Array) -> float:
	var nearest: float = INF
	for first: Vector2 in from:
		for second: Vector2 in to:
			nearest = minf(nearest, first.distance_to(second))
	return nearest

func _test_planned_world_reset() -> void:
	var config := SimulationConfig.new()
	var scenario := ScenarioConfig.new()
	scenario.layout = ScenarioConfig.Layout.HERDS_AND_THREATS
	scenario.sheep_count = 120
	scenario.wolf_count = 6
	scenario.dog_count = 3
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	await process_frame
	# The first step creates spawn_per_tick bodies; position_previous holds S(0).
	_step(world, 1)
	var first: PackedVector2Array = world.store.position_previous.slice(0, world.store.count)
	world.reset(scenario)
	_step(world, 1)
	var second: PackedVector2Array = world.store.position_previous.slice(0, world.store.count)
	_check(first.size() == config.spawn_per_tick and first == second, "Reset reproduces the initial layout")
	_step(world, 2)
	_check(world.store.count == 129, "Planned layout spawns the configured population in batches")
	world.queue_spawn(SimTypes.Species.SHEEP, 10)
	_step(world, 4)
	for dense: int in world.store.count:
		_check(Rect2(Vector2.ZERO, config.world_size).has_point(world.store.position_current[dense]), "Runtime spawns stay inside the pasture")
	world.queue_free()
	await process_frame

func _test_tuning_commands() -> void:
	var world: SimulationWorld = _empty_world()
	await process_frame
	var catalog: TuningCatalog = world.tuning
	var base_speed: float = world.ai.settings.sheep_speed
	var base_flee: float = world.ai.settings.sheep_flee_speed
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.SHEEP_SPEED, 1.5))
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.PERCEPTION_RADIUS, 9999.0))
	_check(world.has_pending_tuning() and world.ai.settings.sheep_speed == base_speed, "Tuning waits for the next stage 0")
	var applied: Array[int] = []
	world.observer_commands_applied.connect(func(tick: int) -> void: applied.append(tick))
	_step(world)
	_check(not world.has_pending_tuning() and applied.size() == 1, "Tuning applies once at stage 0 and is announced")
	_check(is_equal_approx(world.ai.settings.sheep_speed, base_speed * 1.5) and is_equal_approx(world.ai.settings.sheep_flee_speed, base_flee * 1.5), "Species speed multiplier scales every speed of that species")
	_check(world.config.perception_radius == catalog.get_parameter(TuningCatalog.Param.PERCEPTION_RADIUS).maximum, "Values are clamped to the published range")
	_check(catalog.is_modified(TuningCatalog.Param.SHEEP_SPEED) and catalog.history.size() == 2, "Edits are marked and recorded")
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.SHEEP_SPEED, catalog.get_parameter(TuningCatalog.Param.SHEEP_SPEED).default_value))
	_step(world)
	_check(is_equal_approx(world.ai.settings.sheep_speed, base_speed) and not catalog.is_modified(TuningCatalog.Param.SHEEP_SPEED), "Restoring the default restores the original value")
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.WOLF_SPEED, 1.0))
	_step(world)
	_check(catalog.history.size() == 3, "Unchanged values do not add log entries")
	world.reset(world.scenario)
	_check(world.config.perception_radius == catalog.get_parameter(TuningCatalog.Param.PERCEPTION_RADIUS).maximum, "Scenario reset keeps runtime parameters")
	world.queue_free()
	await process_frame

func _test_camera_conversions() -> void:
	var camera := ObserverCamera.new()
	root.add_child(camera)
	var positions: Dictionary[AgentHandle, Vector2] = {}
	var source: Callable = func(handle: AgentHandle) -> Variant:
		return positions.get(handle)
	camera.setup(Vector2(1600, 1000), source)
	camera.set_usable_rect(Rect2(60, 50, 900, 700))
	camera.show_overview(true)
	_check(is_equal_approx(camera.focus.x, 800.0) and is_equal_approx(camera.focus.y, 500.0), "Overview centers the pasture in the usable area")
	var center_world: Vector2 = camera.screen_to_world(Rect2(60, 50, 900, 700).get_center())
	_check(center_world.distance_to(Vector2(800, 500)) < 0.01, "Usable-area center maps to the overview focus")
	for screen: Vector2 in [Vector2(100, 80), Vector2(700, 400), Vector2(900, 720)]:
		_check(camera.world_to_screen(camera.screen_to_world(screen)).distance_to(screen) < 0.01, "Screen and world conversions are inverse")
	var cursor := Vector2(300, 260)
	var anchor: Vector2 = camera.screen_to_world(cursor)
	camera.zoom_at(cursor, 3)
	for frame: int in 120:
		camera._process(1.0 / 60.0)
	_check(camera.zoom_level > camera.overview_zoom() * 1.5, "Wheel zoom increases magnification")
	_check(camera.screen_to_world(cursor).distance_to(anchor) < 2.0 / camera.zoom_level + 0.01 or camera.mode == ObserverCamera.Mode.FREE, "Zoom keeps the world point under the cursor")
	_check(camera.screen_to_world(cursor).distance_to(anchor) < 1.0, "Cursor-anchored zoom is stable after the animation")
	camera.zoom_at(cursor, 40)
	for frame: int in 200:
		camera._process(1.0 / 60.0)
	_check(camera.zoom_level <= ObserverCamera.MAX_ZOOM, "Zoom respects the upper limit")
	var tracked := AgentHandle.new(3, 1, 1)
	positions[tracked] = Vector2(1000, 600)
	_check(camera.follow(tracked) and camera.mode == ObserverCamera.Mode.FOLLOW, "Follow starts for a known life")
	for frame: int in 240:
		camera._process(1.0 / 60.0)
	_check(camera.focus.distance_to(Vector2(1000, 600)) < camera.usable_rect().size.length() * 0.2 / camera.zoom_level, "Follow converges near the target")
	camera.pan_screen(Vector2(40, 0))
	_check(camera.mode == ObserverCamera.Mode.FREE and camera.follow_handle == null, "Manual pan leaves follow")
	camera.follow(tracked)
	var lost: Array[bool] = []
	camera.follow_lost.connect(func() -> void: lost.append(true))
	positions.erase(tracked)
	var last_focus: Vector2 = camera.focus
	camera._process(1.0 / 60.0)
	_check(lost.size() == 1 and camera.mode == ObserverCamera.Mode.FREE, "A vanished life ends follow once")
	_check(camera.focus.distance_to(last_focus) < 0.01, "Lost follow stays at the last valid place")
	camera.set_usable_rect(Rect2(0, 0, 1280, 800))
	camera.show_overview(true)
	var wide_zoom: float = camera.zoom_level
	camera.set_usable_rect(Rect2(0, 50, 900, 750))
	_check(camera.zoom_level < wide_zoom and camera.mode == ObserverCamera.Mode.OVERVIEW, "Overview refits when panels change the usable area")
	camera.free()

func _test_insight_marks_and_knowledge() -> void:
	var world: SimulationWorld = _empty_world()
	var view := WorldPresentation.new()
	root.add_child(view)
	view.setup(world.store, world.intents, world.resources, world.config)
	var overlay := InsightOverlay.new()
	root.add_child(overlay)
	overlay.setup(world, view)
	overlay.camera_zoom = 2.0
	await process_frame
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(500, 500))
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(560, 500))
	for index: int in 90:
		_step(world)
		view.observe_published(world.tick)
	view.present(world.tick, 1.0, true)
	overlay.refresh()
	_check(overlay.active_mark_count() > 0, "Real behavior transitions produce marks")
	var kinds: Dictionary[int, bool] = {}
	for mark: InsightOverlay.Mark in overlay._marks:
		kinds[mark.kind] = true
	_check(kinds.has(InsightOverlay.MarkKind.STARTLE), "A sheep that starts fleeing shows a startle mark")
	var before: int = overlay.active_mark_count()
	view.observe_published(world.tick)
	_check(overlay.active_mark_count() == before, "Re-observing a published tick does not repeat marks")
	# Target knowledge: the overlay reads the wolf's observation, not live data.
	var wolf_context: AgentContext = world.ai.inspect(wolf)
	var sighting: LocalObservation = wolf_context.observation_for(sheep)
	_check(sighting != null, "Wolf holds an observation of the sheep")
	if sighting != null:
		var remembered: Vector2 = sighting.position
		world.store.position_current[world.store.resolve(sheep)] = Vector2(1500, 900)
		_check(wolf_context.observation_for(sheep).position == remembered, "Moving the target does not move the remembered target point")
	world.reset(world.scenario)
	_step(world)
	view.observe_published(world.tick)
	_check(overlay.active_mark_count() == 0, "Reset clears every life-scoped mark")
	overlay.queue_free()
	view.queue_free()
	world.queue_free()
	await process_frame
