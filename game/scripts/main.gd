extends Node2D
## Composition and observer controls. No strategy or authoritative state mutation.
const PANEL_WIDTH: float = 300.0
var _world: SimulationWorld
var _view: WorldPresentation
var _runner: SimulationRunner
var _camera: Camera2D
var _selected: AgentHandle
var _stats: Label
var _inspector: Label
var _pause: Button
var _seed: SpinBox
var _sheep: SpinBox
var _wolves: SpinBox
var _dogs: SpinBox
var _zoom: float = 1.2
var _layout: OptionButton

func _ready() -> void:
	if not has_meta("benchmark_view"):
		for argument: String in OS.get_cmdline_user_args():
			if argument in ["--benchmark=cpu", "--benchmark=frames", "--benchmark=threat"]:
				get_tree().root.add_child.call_deferred(BenchmarkSession.new())
				queue_free()
				return
	RenderingServer.set_default_clear_color(Color("182b2b"))
	call_deferred("_initialize")

func _initialize() -> void:
	_world = SimulationWorld.new()
	add_child(_world)
	_world.setup(SimulationConfig.new(), ScenarioConfig.new())
	_view = WorldPresentation.new(_world.probes)
	add_child(_view)
	_view.setup(_world.store, _world.intents, _world.resources, _world.config)
	_view.set_seed(_world.scenario.random_seed)
	_world.captured.connect(_on_capture)
	_camera = Camera2D.new()
	add_child(_camera)
	_runner = SimulationRunner.new()
	add_child(_runner)
	_runner.setup(_world, _view)
	_build_panel()
	_runner.frame_updated.connect(_refresh_panel)
	get_viewport().size_changed.connect(_fit_camera)
	_fit_camera()
	_refresh_panel()

func _build_panel() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	var panel_theme := Theme.new()
	var interface_font := SystemFont.new()
	interface_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "sans-serif"])
	panel_theme.default_font = interface_font
	panel_theme.default_font_size = 14
	panel.theme = panel_theme
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -PANEL_WIDTH
	var style := StyleBoxFlat.new()
	style.bg_color = Color("17262d")
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 18
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	scroll.add_child(column)
	var title := Label.new()
	title.text = "牧场观察室"
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "羊群 · 狼群 · 牧羊犬 / V1"
	subtitle.modulate = Color("9ab4b6")
	column.add_child(subtitle)
	var time_row := HBoxContainer.new()
	column.add_child(time_row)
	_pause = _button("暂停", func() -> void: _runner.request_pause(not _runner.paused))
	time_row.add_child(_pause)
	time_row.add_child(_button("单步", _runner.request_single_step))
	var speed := OptionButton.new()
	for label: String in ["0.25×", "0.5×", "1×", "2×"]:
		speed.add_item(label)
	speed.select(2)
	speed.item_selected.connect(func(index: int) -> void: _runner.speed = [0.25, 0.5, 1.0, 2.0][index])
	time_row.add_child(speed)
	_layout = OptionButton.new()
	for label: String in ["常态牧场", "双羊群 / 多处威胁", "拥挤 / 集中交互"]:
		_layout.add_item(label)
	column.add_child(_layout)
	_seed = _number(column, "种子", _world.scenario.random_seed, 0, 999999)
	_sheep = _number(column, "初始羊数", _world.scenario.sheep_count, 0, 10000)
	_wolves = _number(column, "初始狼数", _world.scenario.wolf_count, 0, 1000)
	_dogs = _number(column, "初始犬数", _world.scenario.dog_count, 0, 1000)
	column.add_child(_button("按这些初始条件重置", _reset_scenario))
	var spawn_row := HBoxContainer.new()
	column.add_child(spawn_row)
	spawn_row.add_child(_button("+20 羊", func() -> void: _world.queue_spawn(SimTypes.Species.SHEEP, 20)))
	spawn_row.add_child(_button("+3 狼", func() -> void: _world.queue_spawn(SimTypes.Species.WOLF, 3)))
	spawn_row.add_child(_button("+1 犬", func() -> void: _world.queue_spawn(SimTypes.Species.DOG, 1)))
	column.add_child(HSeparator.new())
	_stats = Label.new()
	_stats.tooltip_text = "逾期是已执行任务超过计划时间的累计最大值，重置时清零；不包含仍未服务的队列，也不等于威胁出现至行动的完整响应时间。"
	_stats.add_theme_font_size_override("font_size", 13)
	column.add_child(_stats)
	column.add_child(HSeparator.new())
	_inspector = Label.new()
	_inspector.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector.custom_minimum_size.y = 105
	_inspector.add_theme_font_size_override("font_size", 13)
	column.add_child(_inspector)
	column.add_child(_button("移除选中角色", func() -> void: _world.queue_remove(_selected)))
	var hint := Label.new()
	hint.text = "点击角色检查 · 滚轮缩放
空格暂停 · N 单步 · R 重置
数量变更在下一模拟步生效"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color("9ab4b6")
	column.add_child(hint)

func _button(caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
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

func _reset_scenario() -> void:
	var scenario := ScenarioConfig.new()
	scenario.layout = _layout.selected as ScenarioConfig.Layout
	scenario.random_seed = int(_seed.value)
	scenario.sheep_count = int(_sheep.value)
	scenario.wolf_count = int(_wolves.value)
	scenario.dog_count = int(_dogs.value)
	_runner.request_reset(scenario)
	_selected = null

func _fit_camera() -> void:
	var viewport_size: Vector2 = get_viewport_rect().size
	var available: Vector2 = Vector2(viewport_size.x - PANEL_WIDTH - 32.0, viewport_size.y - 32.0)
	var scale: float = minf(available.x / _world.config.world_size.x, available.y / _world.config.world_size.y) * _zoom
	_camera.zoom = Vector2.ONE * maxf(scale, 0.1)
	_camera.position = _world.config.world_size * 0.5 + Vector2(PANEL_WIDTH / (2.0 * scale), 0.0)

func _unhandled_input(event: InputEvent) -> void:
	if _runner == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: _runner.request_pause(not _runner.paused)
			KEY_N: _runner.request_single_step()
			KEY_R: _reset_scenario()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_selected = _view.pick(get_global_mouse_position())
			_view.set_selected(_selected)
			_refresh_panel()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = minf(_zoom * 1.2, 4.0)
			_fit_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = maxf(_zoom / 1.2, 0.5)
			_fit_camera()

func _refresh_panel() -> void:
	var counts: PackedInt32Array = _world.counts()
	_pause.text = "继续" if _runner.paused else "暂停"
	var statistics := PackedStringArray([
		"存活 羊 %d / 狼 %d / 犬 %d" % [counts[0], counts[1], counts[2]],
		"模拟 %d · 可见 %d · 容量 %d" % [_world.store.count, _view.visible_count, _world.store.capacity],
		"时间 %.2fs · 捕获 %d" % [_world.tick * _world.config.fixed_dt, _world.capture_count],
		"帧间隔 P95 %.1f / P99 %.1f ms" % [_runner.frame_percentile(0.95), _runner.frame_percentile(0.99)],
		"循环 CPU %.2f ms · 积压 %.3fs" % [_runner.cpu_frame_msec, _runner.accumulator_seconds],
		"上步 AI %.2f / 运动 %.2f / 交互 %.2f ms" % [_world.phase_usec[3] / 1000.0, _world.phase_usec[4] / 1000.0, _world.phase_usec[5] / 1000.0],
		"感知 / 决策逾期 %d / %d tick" % [_world.ai.max_perception_delay_ticks, _world.ai.max_decision_delay_ticks],
		"网格最密 %d · 候选访问 %d" % [_world.grid.max_occupancy, _world.grid.candidate_count],
	])
	_stats.text = "\n".join(statistics)
	var dense: int = _world.store.resolve(_selected)
	if dense < 0:
		_inspector.text = "点击牧场中的角色
查看它的意图、目标和身份。"
		return
	var intent: MotionIntent = _world.intents.get_intent(_selected, _world.tick)
	_inspector.text = "%s · %s
饥饿 %.2f" % [SimTypes.species_name(_world.store.species[dense]), _selected.key(), _world.store.hunger[dense]]
	if intent != null:
		var target: String = "无" if intent.target == null else intent.target.key()
		_inspector.text += "
行为 %s · 目标 %s
意图剩余 %d tick
原因 %s" % [SimTypes.behavior_name(intent.behavior), target, intent.expires_tick - _world.tick, intent.reason]

	_inspector.text += "\n" + _world.ai.describe(_selected, _world.tick)
	var attack: AttackRequest = _world.interaction.get_attack(_selected)
	if attack != null:
		_inspector.text += "\n攻击 %s · 冷却至 %d" % [AttackRequest.Status.keys()[attack.status], attack.cooldown_until_tick]

func _on_capture(event: CaptureEvent) -> void:
	_view.add_capture(event.target, event.position, event.facing, event.tick)
