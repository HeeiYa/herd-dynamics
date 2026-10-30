class_name TuningPanel
extends VBoxContainer
## Parameter editor. Dragging only previews; release (or a click/keyboard
## change) submits one TuningCatalog.Change to the world, which applies it at
## the next stage 0. While paused, submitted values show as pending.

var _world: SimulationWorld
var _catalog: TuningCatalog
var _rows: Array[Row] = []
var _status: Label

class Row extends RefCounted:
	var key: TuningCatalog.Param
	var slider: HSlider
	var value_label: Label
	var marker: Label
	var dragging: bool = false
	var pending: bool = false
	var pending_value: float = 0.0
	# Programmatic slider updates must not submit changes.
	var syncing: bool = false

func setup(world: SimulationWorld) -> void:
	_world = world
	_catalog = world.tuning
	add_theme_constant_override("separation", 4)
	var intro := Label.new()
	intro.text = "拖动预览，松开后提交；模拟参数在下一个固定步生效。重置场景不会还原这些参数。"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 12)
	intro.modulate = UiStyle.INK_SOFT
	add_child(intro)
	for parameter: TuningCatalog.Parameter in _catalog.parameters:
		_add_row(parameter)
	var footer := HBoxContainer.new()
	var restore := Button.new()
	restore.text = "全部恢复默认"
	restore.focus_mode = Control.FOCUS_NONE
	restore.pressed.connect(_restore_all)
	footer.add_child(restore)
	add_child(footer)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	add_child(_status)
	world.observer_commands_applied.connect(func(_tick: int) -> void: _clear_pending())
	refresh(false)

func _add_row(parameter: TuningCatalog.Parameter) -> void:
	var row := Row.new()
	row.key = parameter.key
	add_child(HSeparator.new())
	var header := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = parameter.label
	name_label.tooltip_text = parameter.description
	name_label.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_child(name_label)
	row.marker = Label.new()
	row.marker.add_theme_color_override("font_color", UiStyle.ACCENT)
	row.marker.tooltip_text = "已修改"
	row.marker.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_child(row.marker)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var scope := Label.new()
	scope.text = parameter.scope
	scope.add_theme_font_size_override("font_size", 11)
	scope.modulate = UiStyle.INK_SOFT
	header.add_child(scope)
	add_child(header)
	var description := Label.new()
	description.text = parameter.description
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_font_size_override("font_size", 11)
	description.modulate = UiStyle.INK_SOFT
	add_child(description)
	var line := HBoxContainer.new()
	row.slider = HSlider.new()
	row.slider.min_value = parameter.minimum
	row.slider.max_value = parameter.maximum
	row.slider.step = parameter.step
	row.slider.value = parameter.value
	row.slider.focus_mode = Control.FOCUS_NONE
	# Wheel input scrolls the panel instead of silently editing parameters.
	row.slider.scrollable = false
	row.slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.slider.drag_started.connect(func() -> void: row.dragging = true)
	row.slider.drag_ended.connect(func(changed: bool) -> void: _end_drag(row, changed))
	row.slider.value_changed.connect(func(value: float) -> void: _on_value(row, value))
	line.add_child(row.slider)
	row.value_label = Label.new()
	row.value_label.custom_minimum_size.x = 78
	row.value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(row.value_label)
	var reset := Button.new()
	reset.text = "↺"
	reset.tooltip_text = "恢复默认值 %s" % _catalog.format_value(parameter.key, parameter.default_value)
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(func() -> void: _submit(row, parameter.default_value))
	line.add_child(reset)
	add_child(line)
	_rows.append(row)

func _on_value(row: Row, value: float) -> void:
	if row.syncing:
		return
	_show_value(row, value, true)
	if not row.dragging:
		_submit(row, value)

func _end_drag(row: Row, changed: bool) -> void:
	row.dragging = false
	if changed:
		_submit(row, row.slider.value)

func _submit(row: Row, value: float) -> void:
	var parameter: TuningCatalog.Parameter = _catalog.get_parameter(row.key)
	var current: float = row.pending_value if row.pending else parameter.value
	if is_equal_approx(value, current):
		_sync_slider(row, value)
		return
	row.pending = true
	row.pending_value = value
	_world.queue_tuning(TuningCatalog.Change.new(row.key, value))
	_sync_slider(row, value)
	refresh(true)

func _restore_all() -> void:
	for row: Row in _rows:
		_submit(row, _catalog.get_parameter(row.key).default_value)

func _clear_pending() -> void:
	for row: Row in _rows:
		row.pending = false
		_sync_slider(row, _catalog.get_parameter(row.key).value)

func _sync_slider(row: Row, value: float) -> void:
	row.syncing = true
	row.slider.value = value
	row.syncing = false
	_show_value(row, value, false)

func _show_value(row: Row, value: float, previewing: bool) -> void:
	var parameter: TuningCatalog.Parameter = _catalog.get_parameter(row.key)
	var text: String = _catalog.format_value(row.key, value)
	if previewing and row.dragging:
		text = "预览 " + text
	row.value_label.text = text
	var modified: bool = not is_equal_approx(row.pending_value if row.pending else parameter.value, parameter.default_value)
	row.marker.text = " ●" if modified else ""

func refresh(paused: bool) -> void:
	var pending: int = 0
	for row: Row in _rows:
		if row.pending:
			pending += 1
		elif not row.dragging:
			_sync_slider(row, _catalog.get_parameter(row.key).value)
	var text: String = "本次运行已修改 %d 次" % _catalog.history.size()
	if pending > 0:
		text = "%d 项待生效（%s）· %s" % [pending, "暂停中，单步或继续后应用" if paused else "下一模拟步应用", text]
	_status.text = text
