class_name PresentationJob
extends RefCounted
## A reusable back frame. No front DrawEntry or GPU buffer is changed until commit.
enum Phase { BODIES, CAPTURES, COMPACT, REPAIR, SORT, GROUND, PACK, READY }
var source: SimulationPublication
var phase: Phase
var states: Array[WorldPresentation.AnimationState] = []
var drawings: Array[WorldPresentation.DrawEntry] = []
var _scratch: Array[WorldPresentation.DrawEntry] = []
var _capture_drawings: Array[WorldPresentation.DrawEntry] = []
var captures: Array[WorldPresentation.CaptureVisual] = []
var visible_count: int = 0
var capture_count: int = 0
var held_count: int = 0
var display_tick: float
var alpha: float
var direct: bool
var image: Image
var levels := PackedInt32Array()
var _view: WorldPresentation
var _viewport: Rect2
var _index: int = 0
var _merge_width: int
var _merge_start: int
var _left: int
var _right: int
var _left_end: int
var _right_end: int
var _write: int
var _version: int = 0
var _retained: int = 0
var _repair_index: int = 1
var _repair_gap: int = 0
var _repair_entry: WorldPresentation.DrawEntry
var _repair_moves: int = 0

func begin(view: WorldPresentation, snapshot: SimulationPublication, interpolation: float, show_current: bool) -> void:
	_view = view
	if source != null and source.epoch != snapshot.epoch:
		for entry: WorldPresentation.DrawEntry in drawings:
			entry.listed = false
		drawings.clear()
		states.clear()
		# A suspended insertion can hold an entry outside drawings. Discard all
		# old-epoch owners so a capture cannot retain a stale listed flag.
		_capture_drawings.clear()
		_scratch.clear()
		_repair_entry = null
	source = snapshot
	alpha = clampf(interpolation, 0.0, 1.0)
	if view._epoch == snapshot.epoch:
		# A rapid pause/resume may publish twice in the same fixed tick. Never
		# interpolate backward into an interval that was already shown complete.
		alpha = maxf(alpha, clampf(view.display_tick - (snapshot.tick - 1), 0.0, 1.0))
	direct = show_current
	display_tick = float(source.tick) if direct else maxf(0.0, source.tick - 1 + alpha)
	_viewport = view.get_global_transform_with_canvas().affine_inverse() * view.get_viewport_rect()
	states.resize(source.store.capacity)
	_version += 1
	captures = view.reliable_captures(source, display_tick)
	visible_count = 0
	capture_count = 0
	held_count = 0
	_index = 0
	phase = Phase.BODIES
	var size := Vector2i(source.resources.columns, source.resources.rows)
	if image == null or image.get_size() != size:
		image = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGB8)
		levels.resize(source.resources.cell_count)
		levels.fill(-1)

func advance(deadline_usec: int) -> void:
	while phase != Phase.READY and Time.get_ticks_usec() < deadline_usec:
		# Check between bounded groups, never inside an engine/GPU wait.
		for unit: int in 16:
			match phase:
				Phase.BODIES: _body()
				Phase.CAPTURES: _capture()
				Phase.COMPACT: _compact()
				Phase.REPAIR: _repair()
				Phase.SORT: _sort_unit()
				Phase.GROUND: _ground()
				Phase.PACK: _pack()
				Phase.READY: return

func _body() -> void:
	if _index >= source.store.count:
		_index = 0
		phase = Phase.CAPTURES
		return
	var dense: int = _index
	_index += 1
	var pose: PublishedPose = source.pose_at(dense)
	var state: WorldPresentation.AnimationState = states[pose.handle.slot]
	if state == null:
		state = WorldPresentation.AnimationState.new()
		states[pose.handle.slot] = state
	if state.handle == null or not state.handle.same_life(pose.handle) or state.action != pose.action or state.started_tick != pose.started_tick:
		state.phase_ms = _view.phase_for_seed(pose.handle, pose.action, pose.phase_direction, source.scenario.random_seed)
	state.handle = pose.handle
	state.action = pose.action
	state.direction = pose.previous_direction if display_tick < pose.direction_tick else pose.direction
	state.started_tick = pose.started_tick
	state.cue_action = pose.cue_action
	state.cue_started_tick = pose.cue_started_tick
	state.latest_position = source.store.position_current[dense]
	state.drawing.handle = pose.handle
	state.drawing.tint = Color.WHITE
	var foot: Vector2 = state.latest_position if direct else source.store.position_previous[dense].lerp(state.latest_position, alpha)
	state.drawing.foot = foot
	if source.store.held[dense] != 0:
		held_count += 1
		return
	var milliseconds: float = (display_tick - state.started_tick) * source.config.fixed_dt * 1000.0 + state.phase_ms
	var cue_ms: float = (display_tick - state.cue_started_tick) * source.config.fixed_dt * 1000.0
	_view.prepare_timeline_drawing(state.drawing, foot, state.action, state.direction, milliseconds, state.cue_action, cue_ms, source.config)
	if state.drawing.area.intersects(_viewport):
		_queue(state.drawing)
		visible_count += 1

func _capture() -> void:
	if _index >= captures.size():
		_index = 0
		_retained = 0
		phase = Phase.COMPACT
		return
	var visual: WorldPresentation.CaptureVisual = captures[_index]
	if _index >= _capture_drawings.size():
		_capture_drawings.append(WorldPresentation.DrawEntry.new())
	var entry: WorldPresentation.DrawEntry = _capture_drawings[_index]
	_index += 1
	entry.handle = visual.handle
	entry.is_capture = true
	var elapsed: float = (display_tick - visual.started_tick) * source.config.fixed_dt * 1000.0
	var clip: AnimationCatalog.Clip = _view._catalog.get_clip(AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction)
	if elapsed < 0.0:
		var foot: Vector2 = visual.previous_position.lerp(visual.position, clampf(display_tick - visual.started_tick + 1.0, 0.0, 1.0))
		var previous_ms: float = (display_tick - visual.previous_started_tick) * source.config.fixed_dt * 1000.0 + visual.previous_phase_ms
		var cue_ms: float = (display_tick - visual.previous_cue_started_tick) * source.config.fixed_dt * 1000.0
		_view.prepare_timeline_drawing(entry, foot, visual.previous_action, visual.previous_direction, previous_ms, visual.previous_cue_action, cue_ms, source.config)
	else:
		_view.prepare_snapshot_drawing(entry, visual.position, AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction, elapsed, source.config)
	entry.tint.a = clampf((clip.duration_ms + 900.0 - elapsed) / 400.0, 0.0, 1.0)
	if entry.area.intersects(_viewport):
		_queue(entry)
		capture_count += 1

func _queue(entry: WorldPresentation.DrawEntry) -> void:
	entry.visible_frame = _version
	if not entry.listed:
		entry.listed = true
		drawings.append(entry)

func _compact() -> void:
	if _index >= drawings.size():
		drawings.resize(_retained)
		_repair_index = 1
		_repair_entry = null
		_repair_moves = 0
		phase = Phase.REPAIR
		if not source.config.incremental_render_sort:
			_begin_merge_sort()
		return
	var entry: WorldPresentation.DrawEntry = drawings[_index]
	_index += 1
	if entry.visible_frame == _version:
		drawings[_retained] = entry
		_retained += 1
	else:
		entry.listed = false

## Retain this bank's last sorted order. Repair is resumable per shift and has
## the same bounded fallback as the inline path, even on a reversed field.
func _repair() -> void:
	if _repair_index >= drawings.size():
		_index = 0
		phase = Phase.GROUND
		return
	if _repair_entry == null:
		_repair_entry = drawings[_repair_index]
		_repair_gap = _repair_index
	if _repair_gap > 0 and WorldPresentation._draw_before(_repair_entry, drawings[_repair_gap - 1]):
		drawings[_repair_gap] = drawings[_repair_gap - 1]
		_repair_gap -= 1
		_repair_moves += 1
		if _repair_moves >= maxi(32, drawings.size() * 4):
			drawings[_repair_gap] = _repair_entry
			_repair_entry = null
			_begin_merge_sort()
		return
	drawings[_repair_gap] = _repair_entry
	_repair_entry = null
	_repair_index += 1

func _begin_merge_sort() -> void:
	_scratch.resize(drawings.size())
	_merge_width = 1
	_merge_start = 0
	_write = 0
	_right_end = 0
	phase = Phase.SORT

## Bottom-up merge sorting is resumable even during adversarial reversals.
func _sort_unit() -> void:
	var count: int = drawings.size()
	if _merge_width >= count:
		_index = 0
		phase = Phase.GROUND
		return
	if _write >= _right_end:
		if _merge_start >= count:
			var swap: Array[WorldPresentation.DrawEntry] = drawings
			drawings = _scratch
			_scratch = swap
			_merge_width *= 2
			_merge_start = 0
			_write = 0
			_right_end = 0
			return
		_left = _merge_start
		_left_end = mini(count, _left + _merge_width)
		_right = _left_end
		_right_end = mini(count, _right + _merge_width)
		_write = _merge_start
		_merge_start = _right_end
	if _left < _left_end and (_right >= _right_end or not WorldPresentation._draw_before(drawings[_right], drawings[_left])):
		_scratch[_write] = drawings[_left]
		_left += 1
	else:
		_scratch[_write] = drawings[_right]
		_right += 1
	_write += 1

func _ground() -> void:
	if _index >= source.resources.cell_count:
		if not source.config.gpu_presentation:
			phase = Phase.READY
			return
		_view.instance_animator().begin_prepare(drawings.size(), _view.body_scale, source.config.world_size)
		_index = 0
		phase = Phase.PACK
		return
	var cell: int = _index
	_index += 1
	var amount: float = lerpf(source.resources.get_effective_amount(cell, floori(display_tick)), source.resources.get_effective_amount(cell, ceili(display_tick)), display_tick - floorf(display_tick))
	var level: int = clampi(roundi(amount * (GroundLayer.LEVELS - 1)), 0, GroundLayer.LEVELS - 1)
	if levels[cell] != level:
		levels[cell] = level
		image.set_pixel(cell % source.resources.columns, cell / source.resources.columns, GroundLayer._level_color(level))

func _pack() -> void:
	if _index >= drawings.size():
		phase = Phase.READY
		return
	_view.instance_animator().prepare_entry(_index, drawings[_index])
	_index += 1
