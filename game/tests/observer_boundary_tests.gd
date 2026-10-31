extends SceneTree
## Regressions for cancellation, draft ownership, knowledge age and run evidence.
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
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(SimulationConfig.new(), scenario)
	return world

func _run() -> void:
	await _test_cancel_grab()
	await _test_grab_origin_lifetime()
	await _test_parameter_boundary()
	await _test_slider_input()
	await _test_observation_clock()
	_test_spawn_spacing()
	await _test_session_record()
	print("OBSERVER_BOUNDARY_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_cancel_grab() -> void:
	var world: SimulationWorld = _world()
	var view := WorldPresentation.new()
	root.add_child(view)
	var grab := GrabTool.new()
	root.add_child(grab)
	grab.setup(SimulationAccess.local(world), view)
	var origin := Vector2(300, 300)
	var handle: AgentHandle = world.create_at(SimTypes.Species.WOLF, origin)
	var target: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(500, 300))
	var attack := AttackRequest.new()
	attack.actor = handle
	attack.target = target
	attack.cooldown_until_tick = 100
	world.interaction._requests[handle.slot] = attack
	var context: AgentContext = world.ai.inspect(handle)
	context.feeding_until = 90
	for apply_hold: bool in [false, true]:
		_check(grab.begin(handle, origin), "A grab starts on the same live identity")
		if apply_hold:
			world._apply_commands()
		grab.pointer_world = Vector2(700, 700)
		grab.release()
		grab.cancel()
		grab.cancel()
		world._apply_commands()
		grab.update_state(true)
		_check(world.store.position_current[world.store.resolve(handle)] == origin, "Cancelling a queued drop returns to the original position")
		_check(grab.state == GrabTool.State.IDLE and world.store.is_active(handle), "Cancelled grab completes without leaving a held life")
	_check(world.ai.inspect(handle) == context and context.feeding_until == 90, "Grab suspension preserves the original AI context and feeding state")
	_check(world.interaction.get_attack(handle) == attack and attack.cooldown_until_tick == 100, "Cancelling a grab does not reset attack cooldown")
	world.queue_remove(handle)
	world._apply_commands()
	var replacement: AgentHandle = world.create_at(SimTypes.Species.SHEEP, origin)
	world.queue_hold(replacement)
	world.cancel_grab(handle, Vector2(900, 900))
	world._apply_commands()
	_check(world.store.is_held(replacement), "A stale cancellation cannot withdraw another life's hold")
	grab.queue_free()
	view.queue_free()
	world.queue_free()
	await process_frame

func _test_grab_origin_lifetime() -> void:
	var world: SimulationWorld = _world()
	var handle: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(300, 300))
	var equivalent := AgentHandle.new(handle.slot, handle.generation, handle.world_epoch)
	world.queue_hold(equivalent)
	world._apply_commands()
	_check(world._grab_origins.has(handle.key()), "Grab origin belongs to the complete life identity")
	world.queue_remove(equivalent)
	world._apply_commands()
	_check(world._grab_origins.is_empty(), "Equivalent full identity removes the retained grab origin")
	var replacement: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(500, 500))
	world.queue_hold(replacement)
	world._apply_commands()
	world.queue_remove(equivalent)
	world._apply_commands()
	_check(world.store.is_held(replacement) and world._grab_origins.has(replacement.key()), "Stale removal preserves the replacement life's origin")
	world.queue_free()
	await process_frame

func _test_parameter_boundary() -> void:
	var world: SimulationWorld = _world()
	for value: float in [NAN, INF, -INF]:
		_check(not world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.PERCEPTION_RADIUS, value)), "Nonfinite tuning is rejected before entering the queue")
	_check(not world.queue_tuning(null), "Missing tuning commands are rejected")
	var change := TuningCatalog.Change.new(TuningCatalog.Param.PERCEPTION_RADIUS, 9999.0)
	_check(world.queue_tuning(change), "A finite out-of-range value can be bounded")
	change.value = 80.0
	change.key = TuningCatalog.Param.WOLF_SPEED
	world._apply_commands()
	_check(world.config.perception_radius == 320.0, "Queue owns its clamped copy of the parameter command")
	_check(world.tuning.get_parameter(TuningCatalog.Param.WOLF_SPEED).value == 1.0, "Caller mutation cannot change the queued key")
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.SHEEP_SPEED, 1.5))
	world.reset(world.scenario)
	world._apply_commands()
	_check(not world.has_pending_tuning() and world.tuning.get_parameter(TuningCatalog.Param.SHEEP_SPEED).value == 1.0, "Reset discards unapplied tuning")
	_check(world.config.perception_radius == 320.0, "Reset preserves parameters already applied")
	world.queue_free()
	await process_frame

func _mouse_button(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = point
	event.global_position = point
	event.pressed = pressed
	root.push_input(event)

func _start_slider_drag(row: TuningPanel.Row, fraction: float) -> Vector2:
	var rect: Rect2 = row.slider.get_global_rect()
	var point := Vector2(rect.position.x + rect.size.x * fraction, rect.get_center().y)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion)
	_mouse_button(point, true)
	return point

func _test_slider_input() -> void:
	var world: SimulationWorld = _world()
	var panel := TuningPanel.new()
	root.add_child(panel)
	panel.setup(SimulationAccess.local(world))
	panel.size.x = 400.0
	var overlay := InsightOverlay.new()
	panel.range_preview_changed.connect(overlay.set_range_preview)
	await process_frame
	await process_frame
	var row: TuningPanel.Row = panel._rows[TuningCatalog.Param.PERCEPTION_RADIUS]
	var point: Vector2 = _start_slider_drag(row, 0.85)
	var draft: float = row.slider.value
	_check(row.dragging and draft > 180.0 and not world.has_pending_tuning(), "Real mouse press previews without submitting")
	world.queue_place(SimTypes.Species.SHEEP, Vector2(400, 400))
	world._apply_commands()
	_check(row.slider.value == draft and row.dragging, "Unrelated applied command preserves an active draft")
	_check(overlay.preview_radius == draft and overlay.preview_parameter == TuningCatalog.Param.PERCEPTION_RADIUS, "Range geometry uses the draft value")
	_check(world.config.perception_radius == 180.0, "Range preview does not alter simulation perception")
	_mouse_button(point, false)
	_check(world._pending_tuning.size() == 1 and row.pending, "Release queues exactly one change and shows pending")
	world._apply_commands()
	_check(world.config.perception_radius == draft and not row.pending and overlay.preview_parameter == -1, "Applied tuning acknowledges its preview")
	point = _start_slider_drag(row, 0.2)
	world.reset(world.scenario)
	_mouse_button(point, false)
	_check(not world.has_pending_tuning() and not row.dragging and row.slider.value == draft, "A reset during a drag discards the gesture through release")
	point = _start_slider_drag(row, 0.35)
	_mouse_button(point, false)
	world.reset(world.scenario)
	_check(not row.pending and not world.has_pending_tuning() and overlay.preview_parameter == -1, "Reset clears queued edits and pending UI together")
	panel.queue_free()
	overlay.free()
	world.queue_free()
	await process_frame

func _test_observation_clock() -> void:
	var world: SimulationWorld = _world()
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(300, 300))
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(350, 300))
	var context: AgentContext = world.ai.inspect(wolf)
	var sighting := LocalObservation.new()
	sighting.handle = sheep
	sighting.position = Vector2(350, 300)
	sighting.expires_tick = 10
	context.observations[sheep.slot] = sighting
	context.current_tick = 5
	world.tick = 20
	_check(context.observation_for(sheep) == sighting, "Fixture's last job clock precedes expiration")
	_check(context.observation_for(sheep, world.tick) == null, "Read-only observation expires against the supplied world tick")
	var inspector := AgentInspector.new()
	var intent := MotionIntent.new()
	intent.target = sheep
	_check(inspector._target_text(SimulationAccess.local(world), AgentInspection.capture(world, wolf), intent).contains("已失效"), "Inspector explains expired knowledge while the job is delayed")
	_check(context.current_tick == 5, "Inspection never advances the AI clock")
	sighting.expires_tick = 30
	world.store.relocate(sheep, Vector2(1400, 900))
	_check(context.observation_for(sheep, world.tick).position == Vector2(350, 300), "Valid knowledge keeps its historical position")
	world.queue_hold(sheep)
	world._apply_commands()
	_check(context.observation_for(sheep, world.tick) == null, "Held targets invalidate even unexpired sightings")
	inspector.free()
	world.queue_free()
	await process_frame

func _test_spawn_spacing() -> void:
	var config := SimulationConfig.new()
	for layout: ScenarioConfig.Layout in [ScenarioConfig.Layout.NATURAL, ScenarioConfig.Layout.SCATTERED, ScenarioConfig.Layout.HERDS_AND_THREATS]:
		for seed_value: int in [7, 42, 99]:
			var scenario := ScenarioConfig.new()
			scenario.layout = layout
			scenario.random_seed = seed_value
			scenario.sheep_count = 1000
			scenario.wolf_count = 12
			scenario.dog_count = 8
			var planner := SpawnPlanner.new(config, scenario)
			var points := PackedVector2Array()
			for index: int in scenario.sheep_count:
				points.append(planner.next_position(SimTypes.Species.SHEEP))
			var affected: Dictionary[int, bool] = {}
			var pairs: int = 0
			for first: int in points.size():
				for second: int in range(first + 1, points.size()):
					if points[first].distance_squared_to(points[second]) < pow(config.agent_radius * 2.0, 2):
						pairs += 1
						affected[first] = true
						affected[second] = true
			_check(affected.size() < 20, "Thousand-body planned layouts keep diameter overlap below 2 percent")
			print("SPAWN_SPACING layout=%d seed=%d pairs=%d affected=%d spill=%d relaxed=%d" % [layout, seed_value, pairs, affected.size(), planner.spill_placements, planner.relaxed_placements])

func _test_session_record() -> void:
	var world: SimulationWorld = _world()
	var runner := SimulationRunner.new()
	runner.world = world
	var log := ObserverSessionLog.new()
	var path: String = ProjectSettings.globalize_path("res://.godot/observer-tests/session-%d.jsonl" % Time.get_ticks_usec())
	var opened: bool = log.start(SimulationAccess.local(world), runner, path)
	_check(opened, "Local session evidence opens successfully")
	if not opened:
		runner.free()
		world.queue_free()
		await process_frame
		return
	var handle: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(400, 400))
	world.queue_hold(handle)
	world._apply_commands()
	world.queue_drop(handle, Vector2(500, 500))
	world.queue_place(SimTypes.Species.SHEEP, Vector2(600, 600))
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.SHEEP_SPEED, 1.5))
	world._apply_commands()
	runner.set_speed(0.5)
	var old_epoch: int = world.store.epoch
	world.reset(world.scenario)
	log.close()
	var file := FileAccess.open(path, FileAccess.READ)
	var events: Array[String] = []
	var sequence: int = 0
	while file.get_position() < file.get_length():
		var record: Dictionary = JSON.parse_string(file.get_line())
		events.append(record.event)
		_check(int(record.sequence) == sequence and record.has("seed") and record.has("layout") and record.has("tick"), "Each evidence record has ordered sequence and scenario context")
		if record.event == "reset":
			_check(int(record.epoch) > old_epoch and int(record.tick) == 0, "Reset evidence distinguishes the new epoch")
		sequence += 1
	_check(events == ["session", "hold", "parameter", "drop", "place", "time_scale", "reset"], "Applied commands are recorded in actual stage order")
	file.close()
	print("SESSION_EVIDENCE ", ProjectSettings.globalize_path(path))
	runner.free()
	world.queue_free()
	await process_frame
