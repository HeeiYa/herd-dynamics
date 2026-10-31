class_name TuningPanel
extends VBoxContainer
signal regeneration_requested
signal generation_draft_changed
signal range_preview_changed(key: TuningCatalog.Param, radius: float, active: bool)
## Parameter editor. Dragging only previews; release (or a click/keyboard
## change) submits one TuningCatalog.Change to the world, which applies it at
## the next stage 0. While paused, submitted values show as pending.

var _submit_change: Callable
var _catalog: TuningCatalog
var _rows: Array[Row] = []
@onready var _status: Label = $Status

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
	# A reset discards the gesture until its release; no edit leaks into the new epoch.
	var discard_drag: bool = false

func setup(catalog: TuningCatalog, submit_change: Callable) -> void:
	_catalog = catalog
	_submit_change = submit_change
	for parameter: TuningCatalog.Parameter in _catalog.parameters:
		_add_row(parameter)
	$Footer/Restore.pressed.connect(_restore_all)
	$Footer/ApplyGeneration.pressed.connect(func() -> void: regeneration_requested.emit())
	refresh(false)

func _add_row(parameter: TuningCatalog.Parameter) -> void:
	var editor: Control = preload("res://scenes/ui/parameter_row.tscn").instantiate() as Control
	$Rows.add_child(editor)
	var row := Row.new()
	row.key = parameter.key
	(editor.get_node("Header/Name") as Label).text = parameter.label
	(editor.get_node("Header/Scope") as Label).text = parameter.scope
	(editor.get_node("Description") as Label).text = parameter.description
	row.marker = editor.get_node("Header/Marker") as Label
	row.slider = editor.get_node("Editor/Slider") as HSlider
	row.value_label = editor.get_node("Editor/Value") as Label
	row.slider.min_value = parameter.minimum
	row.slider.max_value = parameter.maximum
	row.slider.step = parameter.step
	row.slider.value = parameter.value
	row.slider.drag_started.connect(func() -> void: _begin_drag(row))
	row.slider.drag_ended.connect(func(changed: bool) -> void: _end_drag(row, changed))
	row.slider.value_changed.connect(func(value: float) -> void: _on_value(row, value))
	var reset: Button = editor.get_node("Editor/Reset") as Button
	reset.tooltip_text = "恢复默认值 %s" % _catalog.format_value(parameter.key, parameter.default_value)
	reset.pressed.connect(func() -> void: _submit(row, parameter.default_value))
	_rows.append(row)

func _on_value(row: Row, value: float) -> void:
	if row.syncing:
		return
	if row.discard_drag:
		_sync_slider(row, _catalog.get_parameter(row.key).value)
		return
	_show_value(row, value, true)
	if row.dragging:
		range_preview_changed.emit(row.key, value, true)
	else:
		_submit(row, value)

func _begin_drag(row: Row) -> void:
	row.dragging = true
	row.discard_drag = false
	range_preview_changed.emit(row.key, row.slider.value, true)

func _end_drag(row: Row, changed: bool) -> void:
	row.dragging = false
	if row.discard_drag:
		row.discard_drag = false
		_sync_slider(row, _catalog.get_parameter(row.key).value)
		return
	if changed:
		_submit(row, row.slider.value)
	elif not row.pending:
		range_preview_changed.emit(row.key, 0.0, false)

func _submit(row: Row, value: float) -> void:
	var parameter: TuningCatalog.Parameter = _catalog.get_parameter(row.key)
	var current: float = row.pending_value if row.pending else parameter.value
	if is_equal_approx(value, current):
		_sync_slider(row, value)
		range_preview_changed.emit(row.key, value, row.pending)
		return
	if parameter.requires_reset:
		row.pending = not is_equal_approx(value, parameter.value)
		row.pending_value = value
		_sync_slider(row, value)
		generation_draft_changed.emit()
		refresh(false)
		return
	if not _submit_change.call(TuningCatalog.Change.new(row.key, value)):
		return
	row.pending = true
	row.pending_value = value
	range_preview_changed.emit(row.key, value, true)
	_sync_slider(row, value)
	refresh(true)

func _restore_all() -> void:
	for row: Row in _rows:
		_submit(row, _catalog.get_parameter(row.key).default_value)

func _clear_pending() -> void:
	for row: Row in _rows:
		if _catalog.get_parameter(row.key).requires_reset:
			continue
		row.pending = false
		if row.dragging:
			# Another command may apply while this row is still only a draft.
			continue
		range_preview_changed.emit(row.key, 0.0, false)
		_sync_slider(row, _catalog.get_parameter(row.key).value)

func _on_reset(_epoch: int) -> void:
	for row: Row in _rows:
		row.pending = false
		row.discard_drag = row.dragging
		range_preview_changed.emit(row.key, 0.0, false)
		_sync_slider(row, _catalog.get_parameter(row.key).value)
	refresh(false)

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
	var generation_pending: int = 0
	for row: Row in _rows:
		if row.pending:
			if _catalog.get_parameter(row.key).requires_reset:
				generation_pending += 1
			else:
				pending += 1
		elif not row.dragging:
			_sync_slider(row, _catalog.get_parameter(row.key).value)
	var text: String = "本次运行已修改 %d 次" % _catalog.applied_count
	if pending > 0:
		text = "%d 项待生效（%s）· %s" % [pending, "暂停中，单步或继续后应用" if paused else "下一模拟步应用", text]
	if generation_pending > 0:
		text = "%d 项场地草稿，重新生成后应用\n%s" % [generation_pending, text]
	_status.text = text

func generation_draft() -> PastureSettings:
	var draft := PastureSettings.new()
	draft.world_size = Vector2(_generation_value(TuningCatalog.Param.WORLD_WIDTH), _generation_value(TuningCatalog.Param.WORLD_HEIGHT))
	draft.grass_cell_size = _generation_value(TuningCatalog.Param.GRASS_CELL_SIZE)
	draft.initial_coverage = _generation_value(TuningCatalog.Param.INITIAL_GRASS)
	draft.food_per_standard_area = _generation_value(TuningCatalog.Param.GRASS_CAPACITY)
	return draft.validated_copy()

func _generation_value(key: TuningCatalog.Param) -> float:
	var row: Row = _rows[key]
	return row.pending_value if row.pending else _catalog.get_parameter(key).value

func apply_generation_draft(draft: PastureSettings) -> void:
	assert(draft != null and draft.validated_copy() != null)
	_submit(_rows[TuningCatalog.Param.WORLD_WIDTH], draft.world_size.x)
	_submit(_rows[TuningCatalog.Param.WORLD_HEIGHT], draft.world_size.y)
	_submit(_rows[TuningCatalog.Param.GRASS_CELL_SIZE], draft.grass_cell_size)
	_submit(_rows[TuningCatalog.Param.INITIAL_GRASS], draft.initial_coverage)
	_submit(_rows[TuningCatalog.Param.GRASS_CAPACITY], draft.food_per_standard_area)
