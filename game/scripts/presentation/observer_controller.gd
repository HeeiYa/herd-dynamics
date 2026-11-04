class_name ObserverController
extends Node2D
## Observer input and presentation coordination. No strategy or authoritative state mutation:
## world changes go through SimulationWorld/SimulationRunner commands.
##
## Input order: GUI controls consume first; then the active pasture tool (grab
## or place); then selection and camera. Esc cancels only the highest-priority
## operation: grab > place tool > follow > selection.

enum Tool { SELECT, GRAB, PLACE }

const SPEEDS: Array[float] = [0.25, 0.5, 1.0, 2.0]

var _access: SimulationAccess
var _view: WorldPresentation
var _runner: SimulationRunner
var _camera: ObserverCamera
var _insight: InsightOverlay
var _grab: GrabTool
var _selected: AgentHandle
var _tool: Tool = Tool.SELECT
var _place_species: int = SimTypes.Species.DOG
# Overview scale for benchmarks; 1.0 fits the whole pasture.
var _zoom: float = 1.0

var hud: ObserverHud
var _inspector_presenter: AgentInspectorPresenter

func setup(access: SimulationAccess, view: WorldPresentation, runner: SimulationRunner, camera: ObserverCamera, insight: InsightOverlay, grab: GrabTool, interface: ObserverHud) -> void:
	_access = access
	_view = view
	_runner = runner
	_camera = camera
	_insight = insight
	_grab = grab
	hud = interface
	process_priority = 10
	_inspector_presenter = AgentInspectorPresenter.new(hud.inspector)
	hud.action_requested.connect(_on_action)
	hud.speed_changed.connect(func(index: int) -> void: _runner.set_speed(SPEEDS[index]))
	hud.species_changed.connect(func(species: int) -> void: _place_species = species)
	hud.overlays_changed.connect(sync_overlays)
	hud.tuning.regeneration_requested.connect(reset_scenario)
	hud.inspector.follow_requested.connect(follow_selected)
	hud.inspector.remove_requested.connect(func() -> void: _access.queue_remove(_selected))
	hud.tuning.setup(_access.tuning, _access.queue_tuning, hud.world_size_rows)
	_access.observer_commands_applied.connect(func(_tick: int) -> void: hud.tuning._clear_pending())
	_access.observer_reset.connect(hud.tuning._on_reset)
	hud.tuning.range_preview_changed.connect(_insight.set_range_preview)
	_grab.message.connect(hud.show_toast)
	_camera.follow_lost.connect(func() -> void: hud.show_toast("跟随的角色已离开牧场，镜头停在最后位置"))
	_camera.mode_changed.connect(func(_mode: ObserverCamera.Mode) -> void: refresh_panel())
	_view.epoch_cleared.connect(_on_epoch_cleared)
	_runner.frame_updated.connect(refresh_panel)
	_runner.display_committed.connect(_on_display_committed)
	hud.usable_rect_changed.connect(_camera.set_usable_rect)
	apply_scenario(_access.scenario)
	set_tool(Tool.SELECT)
	sync_overlays()
	hud.update_layout()
	_camera.show_overview(true)
	refresh_panel()

func apply_scenario(scenario: ScenarioConfig) -> void:
	if scenario.pasture != null:
		hud.tuning.apply_generation_draft(scenario.pasture)
	hud.layout.select(hud.layout.get_item_index(scenario.layout))
	hud.seed.value = scenario.random_seed
	hud.sheep.value = scenario.sheep_count
	hud.wolves.value = scenario.wolf_count
	hud.dogs.value = scenario.dog_count

func _on_action(action: ObserverHud.Action) -> void:
	match action:
		ObserverHud.Action.PAUSE: _runner.request_pause(not _runner.pause_requested)
		ObserverHud.Action.STEP: _runner.request_single_step()
		ObserverHud.Action.RESET: reset_scenario()
		ObserverHud.Action.OVERVIEW: _camera.show_overview()
		ObserverHud.Action.HIDE_UI: hud.toggle_ui()
		ObserverHud.Action.PANEL: hud.toggle_panel()
		ObserverHud.Action.SELECT: set_tool(Tool.SELECT)
		ObserverHud.Action.GRAB: set_tool(Tool.GRAB)
		ObserverHud.Action.PLACE: set_tool(Tool.PLACE)
		ObserverHud.Action.SPAWN_SHEEP: _access.queue_spawn(SimTypes.Species.SHEEP, 20)
		ObserverHud.Action.SPAWN_WOLVES: _access.queue_spawn(SimTypes.Species.WOLF, 3)
		ObserverHud.Action.SPAWN_DOG: _access.queue_spawn(SimTypes.Species.DOG, 1)

## Benchmark hook: overview scaled by _zoom (1.0 fits the whole pasture).
func fit_camera() -> void:
	_camera.show_overview(true, _zoom)

# --- Tools and selection ----------------------------------------------------

func set_tool(tool: Tool) -> void:
	if _grab.is_busy() and tool != Tool.GRAB:
		_grab.cancel()
	_tool = tool
	for index: int in hud.tool_buttons.size():
		hud.tool_buttons[index].set_pressed_no_signal(index == tool)
	hud.place_option.disabled = tool != Tool.PLACE

func sync_overlays() -> void:
	_insight.show_destination = hud.overlay_buttons[&"destination"].button_pressed
	_insight.show_target = hud.overlay_buttons[&"target"].button_pressed
	_insight.show_perception = hud.overlay_buttons[&"perception"].button_pressed
	_insight.show_protection = hud.overlay_buttons[&"protection"].button_pressed
	_insight.show_marks = hud.overlay_buttons[&"marks"].button_pressed

func select(handle: AgentHandle) -> void:
	if _camera.mode == ObserverCamera.Mode.FOLLOW and not (handle != null and handle.same_life(_camera.follow_handle)):
		_camera.stop_follow()
	_selected = handle
	_view.set_selected(handle)
	_access.select(handle)
	if handle != null:
		if not hud.panel_open and hud.ui_visible and not _grab.is_busy():
			hud.toggle_panel()
		hud.tabs.current_tab = 0
	refresh_panel()

func follow_selected() -> void:
	if _selected == null:
		hud.show_toast("先选中一个角色再跟随")
		return
	if not _camera.follow(_selected):
		hud.show_toast("该角色当前不在画面记录中，无法跟随")

func _on_epoch_cleared() -> void:
	_selected = null
	if _insight != null:
		_insight.clear()
	if _camera != null:
		_camera.set_world_size(_access.config.world_size)
		_camera.show_overview(false, _zoom)

func reset_scenario() -> void:
	var scenario := ScenarioConfig.new()
	scenario.layout = hud.layout.get_item_id(hud.layout.selected) as ScenarioConfig.Layout
	scenario.random_seed = int(hud.seed.value)
	scenario.sheep_count = int(hud.sheep.value)
	scenario.wolf_count = int(hud.wolves.value)
	scenario.dog_count = int(hud.dogs.value)
	scenario.pasture = hud.tuning.generation_draft()
	if scenario.pasture == null:
		hud.show_toast("场地参数无效")
		return
	if _grab.is_busy():
		_grab.cancel()
	_runner.request_reset(scenario)
	_selected = null
	_view.set_selected(null)

func _is_inside_world(point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, _access.config.world_size).has_point(point)

func _pointer_over_gui() -> bool:
	return get_viewport().gui_get_hovered_control() != null

func _process(delta: float) -> void:
	if _runner == null:
		return
	var started_usec: int = Time.get_ticks_usec() if _access.probes.enabled else 0
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var on_pasture: bool = not _pointer_over_gui()
	var world_point: Vector2 = _camera.screen_to_world(mouse)
	_insight.camera_zoom = _camera.zoom_level
	_grab.camera_zoom = _camera.zoom_level
	_insight.hovered = null
	if on_pasture and not _grab.is_busy() and _tool != Tool.PLACE:
		_insight.hovered = _view.pick(world_point)
	if _grab.state == GrabTool.State.CARRYING:
		_grab.update_pointer(world_point)
		_grab.pointer_valid = on_pasture and _is_inside_world(world_point)
	_grab.update_state(_runner.paused)
	_insight.refresh()
	if _selected != null and not _access.store.is_alive(_selected):
		_selected = null

	if _access.probes.enabled:
		_access.probes.record(Probes.Tag.OBSERVER_UPDATE, Time.get_ticks_usec() - started_usec)

# --- Input ------------------------------------------------------------------

## Releases must end a drag or carry even when the pointer is over a panel,
## where the GUI would otherwise consume the event.
func _input(event: InputEvent) -> void:
	if _runner == null or not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_MIDDLE and _camera.is_dragging():
		_camera.end_drag()
	elif button.button_index == MOUSE_BUTTON_LEFT and _grab.state == GrabTool.State.CARRYING:
		_grab.pointer_valid = not _pointer_over_gui() and _is_inside_world(_camera.screen_to_world(button.position))
		_grab.update_pointer(_camera.screen_to_world(button.position))
		_grab.release()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if _runner == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event as InputEventKey)
		return
	if event is InputEventMouseMotion:
		if _camera.is_dragging():
			_camera.pan_screen((event as InputEventMouseMotion).relative)
		return
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	match button.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if button.pressed:
				_camera.zoom_at(button.position, 1)
		MOUSE_BUTTON_WHEEL_DOWN:
			if button.pressed:
				_camera.zoom_at(button.position, -1)
		MOUSE_BUTTON_MIDDLE:
			if button.pressed:
				_camera.begin_drag()
			else:
				_camera.end_drag()
		MOUSE_BUTTON_RIGHT:
			if button.pressed and _grab.is_busy():
				_grab.cancel()
		MOUSE_BUTTON_LEFT:
			_handle_left(button.pressed, _camera.screen_to_world(button.position))

func _handle_left(pressed: bool, world_point: Vector2) -> void:
	match _tool:
		Tool.GRAB:
			if pressed:
				var target: AgentHandle = _view.pick(world_point)
				if target != null and _grab.begin(target, world_point):
					select(target)
					hud.show_toast("提起中：移动到目标位置后松开" + ("（暂停中，单步或继续后生效）" if _runner.paused else ""))
			else:
				_grab.release()
		Tool.PLACE:
			if pressed:
				if _is_inside_world(world_point):
					_access.queue_place(_place_species, world_point)
					hud.show_toast("已提交放置%s%s" % [SimTypes.species_name(_place_species), "，单步或继续后出现" if _runner.paused else ""])
				else:
					hud.show_toast("只能放在牧场范围内")
		_:
			if pressed:
				select(_view.pick(world_point))

func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_SPACE: _runner.request_pause(not _runner.pause_requested)
		KEY_N: _runner.request_single_step()
		KEY_R: reset_scenario()
		KEY_F: follow_selected()
		KEY_HOME: _camera.show_overview()
		KEY_H: hud.toggle_ui()
		KEY_P: hud.toggle_panel()
		KEY_V: set_tool(Tool.SELECT)
		KEY_G: set_tool(Tool.GRAB)
		KEY_B: set_tool(Tool.PLACE)
		KEY_ESCAPE: _escape()

func _escape() -> void:
	if _grab.is_busy():
		_grab.cancel()
	elif _tool != Tool.SELECT:
		set_tool(Tool.SELECT)
	elif _camera.mode == ObserverCamera.Mode.FOLLOW:
		_camera.stop_follow()
	elif _selected != null:
		select(null)

# --- Panels -----------------------------------------------------------------

func refresh_panel() -> void:
	if _runner == null or hud.pause == null:
		return
	var started_usec: int = Time.get_ticks_usec() if _access.probes.enabled else 0
	var counts: PackedInt32Array = _access.counts()
	var held: PackedInt32Array = _access.held_counts()
	var held_total: int = held[0] + held[1] + held[2]
	hud.pause.text = "继续" if _runner.paused else "暂停"
	if _runner.pause_requested != _runner.paused:
		hud.pause.text = "等待中"
	hud.scene_label.text = "%s · 种子 %d" % [hud.layout.get_item_text(hud.layout.get_item_index(_access.scenario.layout)), _access.scenario.random_seed]
	var count_text: String = "羊 %d   狼 %d   犬 %d" % [counts[0], counts[1], counts[2]]
	if held_total > 0:
		count_text += "   （提起 %d，不参与互动）" % held_total
	hud.counts_label.text = count_text
	var camera_text: String = ["总览", "自由", "跟随"][_camera.mode]
	hud.time_label.text = "%s · %.1fs · 捕获 %d · 镜头 %s %.2f×" % ["已暂停" if _runner.paused else "运行", _access.tick * _access.config.fixed_dt, _access.capture_count, camera_text, _camera.zoom_level]
	hud.perf_summary.text = "帧 P95 %.1f ms · 可见 %d" % [_runner.frame_percentile(0.95), _view.visible_count]
	if _access.executor != null and not _runner.paused and _runner.snapshot_age_msec > 100.0:
		hud.perf_summary.text += " · 等待模拟"
	if hud.stats.visible:
		var statistics := PackedStringArray([
			"运动后端：%s" % _access.motion_backend_status,
			"模拟 %d · 参与互动 %d · 容量 %d" % [_access.store.count, _access.store.count - held_total, _access.store.capacity],
			"帧间隔 P95 %.1f / P99 %.1f ms" % [_runner.frame_percentile(0.95), _runner.frame_percentile(0.99)],
			"循环 CPU %.2f ms · 积压 %.3fs" % [_runner.cpu_frame_msec, _runner.accumulator_seconds],
			"上步 AI %.2f / 运动 %.2f / 交互 %.2f ms" % [_access.phase_usec[3] / 1000.0, _access.phase_usec[4] / 1000.0, _access.phase_usec[5] / 1000.0],
			"感知 / 决策逾期 %d / %d tick" % [_access.max_perception_delay_ticks, _access.max_decision_delay_ticks],
			"网格最密 %d · 候选访问 %d" % [_access.grid_max_occupancy, _access.grid_candidate_count],
			"表现准备 %.2f ms · 状态标记 %d" % [_view.render_build_usec / 1000.0, _insight.active_mark_count()],
		])
		if _access.executor != null:
			statistics.append("后台模拟 · 数据年龄 %.1fms · 缺失意图 %d" % [_runner.snapshot_age_msec, _access.publication.missing_intents])
		hud.stats.text = "\n".join(statistics)
	hud.planner_label.text = "当前布局：" + _access.planner_description
	_inspector_presenter.refresh(_access, _selected)
	hud.tuning.refresh(_runner.paused)
	if _access.probes.enabled:
		_access.probes.record(Probes.Tag.HUD_REFRESH, Time.get_ticks_usec() - started_usec)

func _on_display_committed() -> void:
	# Input runs first. Reconcile the tiny grab preview after the atomic frame
	# switch so a completed drop never draws both the body and its old preview.
	_grab.update_state(_runner.paused)
