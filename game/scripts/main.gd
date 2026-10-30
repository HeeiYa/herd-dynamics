extends Node2D
## Composition and observer controls. No strategy or authoritative state mutation:
## world changes go through SimulationWorld/SimulationRunner commands.
##
## Input order: GUI controls consume first; then the active pasture tool (grab
## or place); then selection and camera. Esc cancels only the highest-priority
## operation: grab > place tool > follow > selection.

enum Tool { SELECT, GRAB, PLACE }

const LAYOUT_NAMES: Dictionary[int, String] = {
	ScenarioConfig.Layout.NATURAL: "自然牧场",
	ScenarioConfig.Layout.SCATTERED: "分散放牧",
	ScenarioConfig.Layout.HERDS_AND_THREATS: "多群与威胁",
	ScenarioConfig.Layout.PASTURE: "常态牧场（V1 基准）",
	ScenarioConfig.Layout.TWO_FLOCKS: "双羊群（V1 基准）",
	ScenarioConfig.Layout.CROWDED: "拥挤压力测试（V1 基准）",
}
const SPEEDS: Array[float] = [0.25, 0.5, 1.0, 2.0]
const RIGHT_PANEL_WIDTH: float = 330.0
const TOP_BAR_HEIGHT: float = 52.0
# Gap between docked HUD panels and the pasture area the camera fits.
const PANEL_GAP: float = 10.0

var _world: SimulationWorld
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

var _hud: Control
var _top_bar: PanelContainer
var _toolbar: PanelContainer
var _right_panel: PanelContainer
var _tabs: TabContainer
var _perf_card: PanelContainer
var _restore_button: Button
var _toast: Label
var _toast_seconds: float = 0.0
var _ui_visible: bool = true
# The detail panel starts collapsed to give the pasture the most room; selecting
# a character opens it.
var _panel_open: bool = false

var _pause: Button
var _speed: OptionButton
var _scene_label: Label
var _counts_label: Label
var _time_label: Label
var _tool_buttons: Array[Button] = []
var _place_option: OptionButton
var _overlay_buttons: Dictionary[StringName, Button] = {}
var _panel_toggle: Button
var _stats: Label
var _perf_summary: Label
var _perf_details: bool = false
var _inspector: AgentInspector
var _tuning: TuningPanel
var _layout: OptionButton
var _seed: SpinBox
var _sheep: SpinBox
var _wolves: SpinBox
var _dogs: SpinBox
var _planner_label: Label

func _ready() -> void:
	if not has_meta("benchmark_view"):
		for argument: String in OS.get_cmdline_user_args():
			if argument in ["--benchmark=cpu", "--benchmark=frames", "--benchmark=threat", "--benchmark=threat-cohort"]:
				get_tree().root.add_child.call_deferred(BenchmarkSession.new())
				queue_free()
				return
	RenderingServer.set_default_clear_color(UiStyle.BACKDROP)
	# Run after the runner so tools and overlays see this frame's publication.
	process_priority = 10
	call_deferred("_initialize")

func _initialize() -> void:
	_world = SimulationWorld.new()
	add_child(_world)
	var scenario := ScenarioConfig.new()
	scenario.layout = ScenarioConfig.Layout.NATURAL
	_world.setup(SimulationConfig.new(), scenario)
	_view = WorldPresentation.new(_world.probes)
	add_child(_view)
	_view.setup(_world.store, _world.intents, _world.resources, _world.config)
	_view.set_seed(_world.scenario.random_seed)
	_world.captured.connect(_on_capture)
	_insight = InsightOverlay.new()
	add_child(_insight)
	_insight.setup(_world, _view)
	_grab = GrabTool.new()
	add_child(_grab)
	_grab.setup(_world, _view)
	_grab.message.connect(_show_toast)
	_camera = ObserverCamera.new()
	add_child(_camera)
	_camera.setup(_world.config.world_size, _view.display_foot)
	_camera.make_current()
	_camera.follow_lost.connect(func() -> void: _show_toast("跟随的角色已离开牧场，镜头停在最后位置"))
	_camera.mode_changed.connect(func(_mode: ObserverCamera.Mode) -> void: _refresh_panel())
	_view.epoch_cleared.connect(_on_epoch_cleared)
	_runner = SimulationRunner.new()
	add_child(_runner)
	_runner.setup(_world, _view)
	_build_hud()
	_runner.frame_updated.connect(_refresh_panel)
	get_viewport().size_changed.connect(_update_usable_rect)
	# Panel sizes are known only after layout; follow every resize.
	for panel: Control in [_top_bar, _toolbar, _right_panel]:
		panel.resized.connect(_update_usable_rect)
	_update_usable_rect()
	_camera.show_overview(true)
	_refresh_panel()

# --- HUD construction -------------------------------------------------------

func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud = Control.new()
	_hud.theme = UiStyle.interface_theme()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The full-screen root must never swallow pasture input.
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_hud)
	_build_top_bar()
	_build_toolbar()
	_build_right_panel()
	_build_perf_card()
	_restore_button = _button("显示界面 (H)", _toggle_ui)
	_restore_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 10)
	_restore_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_restore_button.modulate = Color(1, 1, 1, 0.55)
	_restore_button.visible = false
	_hud.add_child(_restore_button)
	_toast = Label.new()
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 60)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_stylebox_override("normal", UiStyle.panel_box(0.92))
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	_hud.add_child(_toast)

func _build_top_bar() -> void:
	_top_bar = PanelContainer.new()
	_top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	var box := UiStyle.panel_box(0.96)
	box.set_corner_radius_all(0)
	box.corner_radius_bottom_left = 14
	box.corner_radius_bottom_right = 14
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	_top_bar.add_theme_stylebox_override("panel", box)
	_top_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_hud.add_child(_top_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_top_bar.add_child(row)
	var title := Label.new()
	title.text = "牧场观察室"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", UiStyle.OLIVE.darkened(0.25))
	row.add_child(title)
	_scene_label = Label.new()
	_scene_label.modulate = UiStyle.INK_SOFT
	row.add_child(_scene_label)
	row.add_child(VSeparator.new())
	_counts_label = Label.new()
	row.add_child(_counts_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	_time_label = Label.new()
	_time_label.modulate = UiStyle.INK_SOFT
	row.add_child(_time_label)
	_pause = _button("暂停", func() -> void: _runner.request_pause(not _runner.paused), "空格")
	_pause.custom_minimum_size.x = 64
	row.add_child(_pause)
	row.add_child(_button("单步", _runner.request_single_step, "N：推进一个固定模拟步"))
	_speed = OptionButton.new()
	_speed.focus_mode = Control.FOCUS_NONE
	_speed.tooltip_text = "时间倍率：模拟时钟相对现实时间的速度，不改变角色移动速度"
	for value: float in SPEEDS:
		_speed.add_item("%s×" % str(value))
	_speed.select(SPEEDS.find(1.0))
	_speed.item_selected.connect(func(index: int) -> void: _runner.speed = SPEEDS[index])
	row.add_child(_speed)
	row.add_child(_button("重置", _reset_scenario, "R：按“场景”页的初始条件重置"))
	row.add_child(VSeparator.new())
	row.add_child(_button("总览", func() -> void: _camera.show_overview(), "Home：显示整个牧场"))
	_panel_toggle = _button("面板 ◂", _toggle_panel, "收起/展开右侧面板 (P)")
	row.add_child(_panel_toggle)
	row.add_child(_button("隐藏界面", _toggle_ui, "H：隐藏全部界面，便于录制"))

func _build_toolbar() -> void:
	_toolbar = PanelContainer.new()
	_toolbar.mouse_filter = Control.MOUSE_FILTER_STOP
	_toolbar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_toolbar.position = Vector2(PANEL_GAP, TOP_BAR_HEIGHT + 12)
	_hud.add_child(_toolbar)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_toolbar.add_child(column)
	column.add_child(_caption("工具"))
	var tools: Array = [["选择", "V：左键选择角色，查看解释"], ["抓取", "G：按住左键提起角色，松开放下；Esc/右键放回"], ["放置", "B：左键在牧场放置一个新角色"]]
	for index: int in tools.size():
		var button := _button(tools[index][0], func() -> void: _set_tool(index as Tool), tools[index][1])
		button.toggle_mode = true
		_tool_buttons.append(button)
		column.add_child(button)
	_place_option = OptionButton.new()
	_place_option.focus_mode = Control.FOCUS_NONE
	_place_option.tooltip_text = "放置的物种"
	for species: int in range(3):
		_place_option.add_item(SimTypes.species_name(species))
	_place_option.select(_place_species)
	_place_option.item_selected.connect(func(index: int) -> void: _place_species = index)
	column.add_child(_place_option)
	column.add_child(HSeparator.new())
	column.add_child(_caption("显示"))
	var overlays: Array = [
		[&"destination", "目的", "选中角色的行动目的地（黄色虚线与叉）", true],
		[&"target", "目标", "AI 记录的目标位置：实线为亲眼看到，虚线为同伴转告，带信息年龄", true],
		[&"perception", "感知", "选中角色的 AI 感知半径（不是镜头视野）", false],
		[&"protection", "保护", "选中牧羊犬的保护范围与追击范围", false],
		[&"marks", "事件", "受惊、锁定、拦截、捕获等短暂状态标记", true],
	]
	for entry: Array in overlays:
		var key: StringName = entry[0]
		var button := _button(entry[1], func() -> void: _sync_overlays(), entry[2])
		button.toggle_mode = true
		button.button_pressed = entry[3]
		_overlay_buttons[key] = button
		column.add_child(button)
	_set_tool(Tool.SELECT)
	_sync_overlays()

func _build_right_panel() -> void:
	_right_panel = PanelContainer.new()
	_right_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_right_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_right_panel.offset_left = -RIGHT_PANEL_WIDTH - 10
	_right_panel.offset_right = -10
	_right_panel.offset_top = TOP_BAR_HEIGHT + 12
	_right_panel.offset_bottom = -12
	_right_panel.visible = _panel_open
	_hud.add_child(_right_panel)
	_tabs = TabContainer.new()
	_tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	_right_panel.add_child(_tabs)
	_inspector = AgentInspector.new()
	_inspector.follow_requested.connect(_follow_selected)
	_inspector.remove_requested.connect(func() -> void: _world.queue_remove(_selected))
	_tabs.add_child(_scrolling(_inspector, "角色"))
	_tuning = TuningPanel.new()
	_tuning.setup(_world)
	_tabs.add_child(_scrolling(_tuning, "参数"))
	_tabs.add_child(_scrolling(_build_scenario_page(), "场景"))

func _build_scenario_page() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	var intro := Label.new()
	intro.text = "初始条件只在“重置”时应用。V1 基准布局保持旧版位置算法，供历史测量对照。"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 12)
	intro.modulate = UiStyle.INK_SOFT
	column.add_child(intro)
	_layout = OptionButton.new()
	_layout.focus_mode = Control.FOCUS_NONE
	# Item ids equal the enum values, so numeric benchmark arguments still map.
	for layout: int in ScenarioConfig.Layout.values():
		_layout.add_item(LAYOUT_NAMES[layout], layout)
	_layout.select(_layout.get_item_index(_world.scenario.layout))
	column.add_child(_layout)
	_seed = _number(column, "种子", _world.scenario.random_seed, 0, 999999)
	_sheep = _number(column, "初始羊数", _world.scenario.sheep_count, 0, 10000)
	_wolves = _number(column, "初始狼数", _world.scenario.wolf_count, 0, 1000)
	_dogs = _number(column, "初始犬数", _world.scenario.dog_count, 0, 1000)
	column.add_child(_button("按这些初始条件重置 (R)", _reset_scenario))
	_planner_label = Label.new()
	_planner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_planner_label.add_theme_font_size_override("font_size", 12)
	column.add_child(_planner_label)
	column.add_child(HSeparator.new())
	column.add_child(_caption("运行中加入（下一模拟步生效）"))
	var spawn_row := HBoxContainer.new()
	spawn_row.add_child(_button("+20 羊", func() -> void: _world.queue_spawn(SimTypes.Species.SHEEP, 20)))
	spawn_row.add_child(_button("+3 狼", func() -> void: _world.queue_spawn(SimTypes.Species.WOLF, 3)))
	spawn_row.add_child(_button("+1 犬", func() -> void: _world.queue_spawn(SimTypes.Species.DOG, 1)))
	column.add_child(spawn_row)
	return column

func _build_perf_card() -> void:
	_perf_card = PanelContainer.new()
	_perf_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_perf_card.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 10)
	_perf_card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_perf_card.add_theme_stylebox_override("panel", UiStyle.panel_box(0.88))
	_hud.add_child(_perf_card)
	var column := VBoxContainer.new()
	_perf_card.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	_perf_summary = Label.new()
	_perf_summary.add_theme_font_size_override("font_size", 12)
	header.add_child(_perf_summary)
	var expand := Button.new()
	expand.text = "▴"
	expand.tooltip_text = "展开/收起性能详情"
	expand.focus_mode = Control.FOCUS_NONE
	expand.toggle_mode = true
	expand.toggled.connect(func(pressed: bool) -> void: _set_perf_details(pressed, expand))
	header.add_child(expand)
	_stats = Label.new()
	_stats.tooltip_text = "逾期是已执行任务超过计划时间的累计最大值，重置时清零；不包含仍未服务的队列，也不等于威胁出现至行动的完整响应时间。"
	_stats.mouse_filter = Control.MOUSE_FILTER_PASS
	_stats.add_theme_font_size_override("font_size", 12)
	_stats.visible = false
	column.add_child(_stats)

func _set_perf_details(expanded: bool, toggle: Button) -> void:
	_perf_details = expanded
	toggle.text = "▾" if expanded else "▴"
	_stats.visible = expanded
	_refresh_panel()
	_perf_card.reset_size()

func _scrolling(content: Control, title: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return scroll

func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = UiStyle.INK_SOFT
	return label

func _button(caption: String, callback: Callable, tooltip: String = "") -> Button:
	var button := Button.new()
	button.text = caption
	button.tooltip_text = tooltip
	# Keyboard shortcuts stay with the pasture rather than a focused button.
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	return button

func _number(parent: Control, caption: String, initial: int, minimum: int, maximum: int) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var number := SpinBox.new()
	number.min_value = minimum
	number.max_value = maximum
	number.value = initial
	number.custom_minimum_size.x = 128
	row.add_child(number)
	return number

# --- Layout -----------------------------------------------------------------

func _toggle_ui() -> void:
	_ui_visible = not _ui_visible
	for node: Control in [_top_bar, _toolbar, _perf_card]:
		node.visible = _ui_visible
	_right_panel.visible = _ui_visible and _panel_open
	_restore_button.visible = not _ui_visible
	_update_usable_rect()

func _toggle_panel() -> void:
	_panel_open = not _panel_open
	_right_panel.visible = _ui_visible and _panel_open
	_panel_toggle.text = "面板 ▸" if _panel_open else "面板 ◂"
	_update_usable_rect()

## The pasture area the camera centers and fits: the viewport minus the
## measured rectangles of the visible docked panels. Other modules use the
## camera's conversions instead of re-deriving these offsets.
func _update_usable_rect() -> void:
	var viewport: Rect2 = get_viewport_rect()
	var left: float = viewport.position.x
	var top: float = viewport.position.y
	var right: float = viewport.end.x
	if _top_bar.visible:
		top = _top_bar.get_global_rect().end.y
	if _toolbar.visible:
		left = _toolbar.get_global_rect().end.x + PANEL_GAP
	if _right_panel.visible:
		right = _right_panel.get_global_rect().position.x - PANEL_GAP
	_camera.set_usable_rect(Rect2(left, top, right - left, viewport.end.y - top))

## Benchmark hook: overview scaled by _zoom (1.0 fits the whole pasture).
func _fit_camera() -> void:
	_camera.show_overview(true, _zoom)

# --- Tools and selection ----------------------------------------------------

func _set_tool(tool: Tool) -> void:
	if _grab.is_busy() and tool != Tool.GRAB:
		_grab.cancel()
	_tool = tool
	for index: int in _tool_buttons.size():
		_tool_buttons[index].set_pressed_no_signal(index == tool)
	_place_option.disabled = tool != Tool.PLACE

func _sync_overlays() -> void:
	_insight.show_destination = _overlay_buttons[&"destination"].button_pressed
	_insight.show_target = _overlay_buttons[&"target"].button_pressed
	_insight.show_perception = _overlay_buttons[&"perception"].button_pressed
	_insight.show_protection = _overlay_buttons[&"protection"].button_pressed
	_insight.show_marks = _overlay_buttons[&"marks"].button_pressed

func _select(handle: AgentHandle) -> void:
	if _camera.mode == ObserverCamera.Mode.FOLLOW and not (handle != null and handle.same_life(_camera.follow_handle)):
		_camera.stop_follow()
	_selected = handle
	_view.set_selected(handle)
	if handle != null:
		if not _panel_open and _ui_visible:
			_toggle_panel()
		_tabs.current_tab = 0
	_refresh_panel()

func _follow_selected() -> void:
	if _selected == null:
		_show_toast("先选中一个角色再跟随")
		return
	if not _camera.follow(_selected):
		_show_toast("该角色当前不在画面记录中，无法跟随")

func _on_epoch_cleared() -> void:
	_selected = null
	if _insight != null:
		_insight.clear()
	if _camera != null:
		_camera.show_overview(false, _zoom)

func _reset_scenario() -> void:
	var scenario := ScenarioConfig.new()
	scenario.layout = _layout.get_item_id(_layout.selected) as ScenarioConfig.Layout
	scenario.random_seed = int(_seed.value)
	scenario.sheep_count = int(_sheep.value)
	scenario.wolf_count = int(_wolves.value)
	scenario.dog_count = int(_dogs.value)
	if _grab.is_busy():
		_grab.cancel()
	_runner.request_reset(scenario)
	_selected = null
	_view.set_selected(null)

func _is_inside_world(point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, _world.config.world_size).has_point(point)

func _pointer_over_gui() -> bool:
	return get_viewport().gui_get_hovered_control() != null

func _process(delta: float) -> void:
	if _runner == null:
		return
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var on_pasture: bool = not _pointer_over_gui()
	var world_point: Vector2 = _camera.screen_to_world(mouse)
	_insight.camera_zoom = _camera.zoom_level
	_grab.camera_zoom = _camera.zoom_level
	_insight.hovered = null
	if on_pasture and not _grab.is_busy() and _tool != Tool.PLACE:
		_insight.hovered = _view.pick(world_point)
	if _grab.state == GrabTool.State.CARRYING:
		_grab.pointer_world = world_point
		_grab.pointer_valid = on_pasture and _is_inside_world(world_point)
	_grab.update_state(_runner.paused)
	_insight.refresh()
	if _selected != null and not _world.store.is_alive(_selected):
		_selected = null
	if _toast_seconds > 0.0:
		_toast_seconds -= delta
		_toast.modulate.a = clampf(_toast_seconds / 0.4, 0.0, 1.0)
		if _toast_seconds <= 0.0:
			_toast.visible = false

func _show_toast(text: String) -> void:
	if text.is_empty() or _toast == null:
		return
	_toast.text = text
	_toast.reset_size()
	_toast.visible = true
	_toast.modulate.a = 1.0
	_toast_seconds = 2.6

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
		_grab.pointer_world = _camera.screen_to_world(button.position)
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
					_select(target)
					_show_toast("提起中：移动到目标位置后松开" + ("（暂停中，单步或继续后生效）" if _runner.paused else ""))
			else:
				_grab.release()
		Tool.PLACE:
			if pressed:
				if _is_inside_world(world_point):
					_world.queue_place(_place_species, world_point)
					_show_toast("已提交放置%s%s" % [SimTypes.species_name(_place_species), "，单步或继续后出现" if _runner.paused else ""])
				else:
					_show_toast("只能放在牧场范围内")
		_:
			if pressed:
				_select(_view.pick(world_point))

func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_SPACE: _runner.request_pause(not _runner.paused)
		KEY_N: _runner.request_single_step()
		KEY_R: _reset_scenario()
		KEY_F: _follow_selected()
		KEY_HOME: _camera.show_overview()
		KEY_H: _toggle_ui()
		KEY_P: _toggle_panel()
		KEY_V: _set_tool(Tool.SELECT)
		KEY_G: _set_tool(Tool.GRAB)
		KEY_B: _set_tool(Tool.PLACE)
		KEY_ESCAPE: _escape()

func _escape() -> void:
	if _grab.is_busy():
		_grab.cancel()
	elif _tool != Tool.SELECT:
		_set_tool(Tool.SELECT)
	elif _camera.mode == ObserverCamera.Mode.FOLLOW:
		_camera.stop_follow()
	elif _selected != null:
		_select(null)

# --- Panels -----------------------------------------------------------------

func _refresh_panel() -> void:
	if _runner == null or _pause == null:
		return
	var counts: PackedInt32Array = _world.counts()
	var held: PackedInt32Array = _world.held_counts()
	var held_total: int = held[0] + held[1] + held[2]
	_pause.text = "继续" if _runner.paused else "暂停"
	_scene_label.text = "%s · 种子 %d" % [LAYOUT_NAMES[_world.scenario.layout], _world.scenario.random_seed]
	var count_text: String = "羊 %d   狼 %d   犬 %d" % [counts[0], counts[1], counts[2]]
	if held_total > 0:
		count_text += "   （提起 %d，不参与互动）" % held_total
	_counts_label.text = count_text
	var camera_text: String = ["总览", "自由", "跟随"][_camera.mode]
	_time_label.text = "%s · %.1fs · 捕获 %d · 镜头 %s %.2f×" % ["已暂停" if _runner.paused else "运行", _world.tick * _world.config.fixed_dt, _world.capture_count, camera_text, _camera.zoom_level]
	_perf_summary.text = "帧 P95 %.1f ms · 可见 %d" % [_runner.frame_percentile(0.95), _view.visible_count]
	if _perf_details:
		var statistics := PackedStringArray([
			"模拟 %d · 参与互动 %d · 容量 %d" % [_world.store.count, _world.store.count - held_total, _world.store.capacity],
			"帧间隔 P95 %.1f / P99 %.1f ms" % [_runner.frame_percentile(0.95), _runner.frame_percentile(0.99)],
			"循环 CPU %.2f ms · 积压 %.3fs" % [_runner.cpu_frame_msec, _runner.accumulator_seconds],
			"上步 AI %.2f / 运动 %.2f / 交互 %.2f ms" % [_world.phase_usec[3] / 1000.0, _world.phase_usec[4] / 1000.0, _world.phase_usec[5] / 1000.0],
			"感知 / 决策逾期 %d / %d tick" % [_world.ai.max_perception_delay_ticks, _world.ai.max_decision_delay_ticks],
			"网格最密 %d · 候选访问 %d" % [_world.grid.max_occupancy, _world.grid.candidate_count],
			"表现准备 %.2f ms · 状态标记 %d" % [_view.render_build_usec / 1000.0, _insight.active_mark_count()],
		])
		_stats.text = "\n".join(statistics)
	var planner: SpawnPlanner = _world.spawn_planner
	_planner_label.text = "当前布局：" + (planner.describe() if planner != null else "V1 固定算法")
	_inspector.refresh(_world, _selected)
	_tuning.refresh(_runner.paused)

func _on_capture(event: CaptureEvent) -> void:
	_view.add_capture(event.target, event.position, event.facing, event.tick)
