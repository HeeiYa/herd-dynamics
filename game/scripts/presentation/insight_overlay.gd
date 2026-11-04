class_name InsightOverlay
extends Node2D
## Read-only explanation layer in world space: hover and selection marks, the
## selected life's action destination and AI-known target, perception and
## protection ranges, and short state-change marks.
##
## Target lines end at the AI's own observation (position, source, age), never
## at a hidden target's live position. Marks come from published intent changes
## and capture events and fade on simulation time, so they freeze while paused.
## Large or distant scenes cap the number of marks; AI work is never reduced.

enum MarkKind { STARTLE, RECOVER, LOCK_ON, POUNCE, GIVE_UP, RETREAT, BARK, RETURN, CAPTURE }

# Draft UI geometry never writes config or affects perception.
var preview_parameter: int = -1
var preview_radius: float = 0.0

class Mark extends RefCounted:
	var handle: AgentHandle
	var kind: MarkKind
	var position: Vector2
	var tick: int

const MARK_TICKS: int = 90
const MAX_MARKS: int = 40
# Below this zoom only the selected life and captures produce marks.
const DISTANT_ZOOM: float = 0.9
const REPEAT_TICKS: int = 45

var show_destination: bool = true
var show_target: bool = true
var show_perception: bool = false
var show_protection: bool = false
var show_marks: bool = true
var hovered: AgentHandle
var camera_zoom: float = 1.0

var _world: SimulationAccess
var _view: WorldPresentation
var _font: Font
var _marks: Array[Mark] = []
# Last mark tick per slot; full identity is checked on the stored mark.
var _last_mark: Dictionary[int, Mark] = {}

func set_range_preview(key: TuningCatalog.Param, radius: float, active: bool) -> void:
	if key not in [TuningCatalog.Param.PERCEPTION_RADIUS, TuningCatalog.Param.DOG_PROTECTION_RADIUS, TuningCatalog.Param.DOG_LEASH_RADIUS]:
		return
	if active:
		preview_parameter = key
		preview_radius = radius
	elif preview_parameter == key:
		preview_parameter = -1
	queue_redraw()

func setup(world: SimulationAccess, view: WorldPresentation) -> void:
	_world = world
	_view = view
	_font = UiStyle.interface_theme().default_font
	z_index = 5
	_view.behavior_changed.connect(_on_behavior_changed)
	_view.epoch_cleared.connect(_clear_old_epochs)
	_world.behavior_presented.connect(_on_reliable_behavior)
	_world.captured.connect(_on_captured)

func clear() -> void:
	_marks.clear()
	_last_mark.clear()
	hovered = null

func active_mark_count() -> int:
	return _marks.size()

func _on_behavior_changed(handle: AgentHandle, species: int, previous: int, current: int, tick: int) -> void:
	if not show_marks or _world.store.is_held(handle):
		return
	var kind: int = _mark_for(species, previous, current)
	if kind < 0:
		return
	var foot: Variant = _view.display_foot(handle)
	var position: Vector2 = foot if foot != null else Vector2.ZERO
	if foot == null:
		var dense: int = _world.store.resolve(handle)
		if dense < 0:
			return
		position = _world.store.position_current[dense]
	_add_mark(handle, kind as MarkKind, position, tick)

static func _mark_for(species: int, previous: int, current: int) -> int:
	match species:
		SimTypes.Species.SHEEP:
			if current == SimTypes.Behavior.FLEE:
				return MarkKind.STARTLE
			if previous == SimTypes.Behavior.FLEE:
				return MarkKind.RECOVER
		SimTypes.Species.WOLF:
			var hunting: bool = previous == SimTypes.Behavior.CHASE or previous == SimTypes.Behavior.FLANK or previous == SimTypes.Behavior.STALK
			var now_hunting: bool = current == SimTypes.Behavior.CHASE or current == SimTypes.Behavior.FLANK or current == SimTypes.Behavior.STALK
			if now_hunting and not hunting:
				return MarkKind.LOCK_ON
			if current == SimTypes.Behavior.ATTACK:
				return MarkKind.POUNCE
			if current == SimTypes.Behavior.RETREAT:
				return MarkKind.RETREAT
			if hunting and current == SimTypes.Behavior.SEARCH:
				return MarkKind.GIVE_UP
		SimTypes.Species.DOG:
			if current == SimTypes.Behavior.INTERCEPT:
				return MarkKind.BARK
			if current == SimTypes.Behavior.RETURN:
				return MarkKind.RETURN
	return -1

func _on_captured(event: CaptureEvent) -> void:
	if show_marks:
		_add_mark(event.target, MarkKind.CAPTURE, event.position, event.tick)

func _add_mark(handle: AgentHandle, kind: MarkKind, position: Vector2, tick: int) -> void:
	var selected: bool = handle.same_life(_view.selected_handle)
	if camera_zoom < DISTANT_ZOOM and not selected and kind != MarkKind.CAPTURE:
		return
	var previous: Mark = _last_mark.get(handle.slot)
	if previous != null and previous.handle.same_life(handle) and previous.kind == kind and tick - previous.tick < REPEAT_TICKS:
		return
	if _marks.size() >= MAX_MARKS:
		if not selected and kind != MarkKind.CAPTURE:
			return
		_marks.pop_front()
	var mark := Mark.new()
	mark.handle = handle
	mark.kind = kind
	mark.position = position
	mark.tick = tick
	_marks.append(mark)
	_last_mark[handle.slot] = mark

func refresh() -> void:
	var now: float = _view.display_tick
	for index: int in range(_marks.size() - 1, -1, -1):
		if _marks[index].handle.world_epoch == _view._epoch and now - _marks[index].tick > MARK_TICKS:
			_marks.remove_at(index)
	queue_redraw()

func _draw() -> void:
	if _world == null:
		return
	var pixel: float = 1.0 / maxf(camera_zoom, 0.05)
	if hovered != null and not hovered.same_life(_view.selected_handle):
		var hover_foot: Variant = _view.display_foot(hovered)
		if hover_foot != null:
			_ellipse(hover_foot, 17.0, UiStyle.HOVER, 1.5 * pixel)
	var selected: AgentHandle = _view.selected_handle
	if selected != null and not _world.store.is_held(selected):
		var foot: Variant = _view.display_foot(selected)
		if foot != null:
			_draw_selected(selected, foot, pixel)
	_draw_marks(pixel)

func _draw_selected(handle: AgentHandle, foot: Vector2, pixel: float) -> void:
	var context: AgentInspection = _world.inspect(handle)
	var dense: int = _world.store.resolve(handle)
	_draw_range_preview(context, dense, foot, pixel)
	if show_perception:
		_dashed_circle(foot, _world.config.perception_radius, UiStyle.PERCEPTION, 1.5 * pixel, 10.0 * pixel)
	if show_protection and context != null and _world.store.species[dense] == SimTypes.Species.DOG and context.flock_count > 0:
		draw_circle(context.protection_anchor, _world.settings.protection_radius, Color(UiStyle.PROTECTION, 0.12), true, -1.0, true)
		_dashed_circle(context.protection_anchor, _world.settings.protection_radius, UiStyle.PROTECTION, 2.0 * pixel, 14.0 * pixel)
		_dashed_circle(context.protection_anchor, _world.config.dog_leash_radius, Color(UiStyle.PROTECTION, 0.35), 1.0 * pixel, 6.0 * pixel)
		_diamond(context.protection_anchor, 6.0 * pixel, UiStyle.PROTECTION)
	var intent: MotionIntent = _world.intents.get_intent(handle, _world.tick)
	if intent == null:
		return
	if show_destination and intent.mode != SimTypes.IntentMode.STOP and intent.mode != SimTypes.IntentMode.GRAZE:
		_dashed_line(foot, intent.destination, Color(UiStyle.DESTINATION, 0.85), 1.5 * pixel, 6.0 * pixel)
		_cross(intent.destination, 5.0 * pixel, UiStyle.DESTINATION, 2.0 * pixel)
	if show_target and intent.target != null and context != null:
		_draw_known_target(context, intent.target, foot, pixel)

func _draw_range_preview(context: AgentInspection, dense: int, foot: Vector2, pixel: float) -> void:
	if preview_parameter < 0:
		return
	var center: Vector2 = foot
	if preview_parameter != TuningCatalog.Param.PERCEPTION_RADIUS:
		if context == null or _world.store.species[dense] != SimTypes.Species.DOG or context.flock_count <= 0:
			return
		center = context.protection_anchor
	_dashed_circle(center, preview_radius, UiStyle.DESTINATION, 2.0 * pixel, 5.0 * pixel)
	_label(center + Vector2(0, -preview_radius), "范围预览 / 待生效 · %d px" % roundi(preview_radius), UiStyle.DESTINATION, pixel)

## The line ends at the remembered sighting. An expired or invalid memory
## draws no line, so the overlay cannot leak where the target went.
func _draw_known_target(context: AgentInspection, target: AgentHandle, foot: Vector2, pixel: float) -> void:
	var sighting: LocalObservation = context.observation_for(target, _world.tick)
	if sighting == null:
		_label(foot + Vector2(0, -42) * pixel, "目标信息已失效", UiStyle.INVALID_DROP, pixel)
		return
	var age: int = _world.tick - sighting.observed_tick
	var direct: bool = sighting.source == LocalObservation.Source.DIRECT
	var visible_at_scan: bool = direct and sighting.was_visible_at_scan(context.last_perception_tick, _world.tick, _world.config.memory_ticks)
	var color: Color = UiStyle.TARGET_DIRECT if direct else UiStyle.TARGET_SHARED
	# Older knowledge fades toward its expiry.
	var freshness: float = clampf(1.0 - float(age) / maxf(1.0, _world.config.memory_ticks), 0.25, 1.0)
	color.a = 0.45 + 0.5 * freshness
	if visible_at_scan:
		draw_line(foot, sighting.position, color, 2.0 * pixel, true)
	else:
		_dashed_line(foot, sighting.position, color, 2.0 * pixel, (7.0 if direct else 3.0) * pixel)
	draw_arc(sighting.position, 9.0 * pixel, 0.0, TAU, 20, color, 2.0 * pixel, true)
	var source: String = "记忆" if direct else "转告"
	if visible_at_scan:
		source = "最近扫描看到"
	_label(sighting.position + Vector2(10, -10) * pixel, "%s · %s" % [source, BehaviorText.age_text(age, _world.config.fixed_dt)], color, pixel)

func _draw_marks(pixel: float) -> void:
	var now: float = _view.display_tick
	for mark: Mark in _marks:
		if mark.handle.world_epoch != _view._epoch:
			continue
		var age: float = now - mark.tick
		if age < 0.0:
			continue
		var fade: float = clampf(1.0 - age / MARK_TICKS, 0.0, 1.0)
		var anchor: Vector2 = mark.position
		if mark.kind != MarkKind.CAPTURE:
			var foot: Variant = _view.display_foot(mark.handle)
			if foot != null:
				anchor = foot
		# A short rise on appearance, then a steady fade.
		var lift: float = 34.0 + minf(age, 10.0) * 0.6
		_draw_glyph(mark.kind, anchor + Vector2(0, -lift) * pixel, pixel, fade)

func _draw_glyph(kind: MarkKind, center: Vector2, pixel: float, fade: float) -> void:
	var radius: float = 8.0 * pixel
	var ink := Color(UiStyle.INK, fade)
	var fill: Color
	match kind:
		MarkKind.STARTLE, MarkKind.BARK:
			fill = Color("f2c14e")
		MarkKind.RECOVER, MarkKind.RETURN:
			fill = Color("b8e08a")
		MarkKind.LOCK_ON, MarkKind.POUNCE:
			fill = Color("e07b62")
		MarkKind.CAPTURE:
			fill = Color("c94f3d")
		_:
			fill = Color("d9d2c3")
	fill.a = 0.92 * fade
	draw_circle(center, radius, fill, true, -1.0, true)
	draw_arc(center, radius, 0.0, TAU, 18, ink, 1.2 * pixel, true)
	var width: float = 1.6 * pixel
	var unit: float = radius * 0.5
	match kind:
		MarkKind.STARTLE:
			draw_line(center + Vector2(0, -unit * 1.2), center + Vector2(0, unit * 0.3), ink, width * 1.3)
			draw_circle(center + Vector2(0, unit * 0.95), width * 0.8, ink)
		MarkKind.BARK:
			for side: float in [-0.55, 0.55]:
				draw_line(center + Vector2(unit * side, -unit * 1.2), center + Vector2(unit * side, unit * 0.3), ink, width)
				draw_circle(center + Vector2(unit * side, unit * 0.95), width * 0.7, ink)
		MarkKind.RECOVER:
			draw_polyline(PackedVector2Array([center + Vector2(-unit, 0), center + Vector2(-unit * 0.2, unit * 0.8), center + Vector2(unit, -unit * 0.8)]), ink, width, true)
		MarkKind.LOCK_ON:
			draw_arc(center, unit, 0.0, TAU, 14, ink, width, true)
			draw_line(center + Vector2(-unit * 1.5, 0), center + Vector2(unit * 1.5, 0), ink, width * 0.7)
			draw_line(center + Vector2(0, -unit * 1.5), center + Vector2(0, unit * 1.5), ink, width * 0.7)
		MarkKind.POUNCE:
			draw_polyline(PackedVector2Array([center + Vector2(-unit * 1.2, unit * 0.6), center + Vector2(-unit * 0.4, -unit * 0.6), center + Vector2(unit * 0.4, unit * 0.6), center + Vector2(unit * 1.2, -unit * 0.6)]), ink, width, true)
		MarkKind.GIVE_UP:
			draw_arc(center + Vector2(0, -unit * 0.4), unit * 0.6, PI, TAU + PI * 0.5, 10, ink, width, true)
			draw_circle(center + Vector2(0, unit * 1.0), width * 0.7, ink)
		MarkKind.RETREAT, MarkKind.RETURN:
			draw_line(center + Vector2(unit, 0), center + Vector2(-unit, 0), ink, width)
			draw_polyline(PackedVector2Array([center + Vector2(-unit * 0.3, -unit * 0.7), center + Vector2(-unit, 0), center + Vector2(-unit * 0.3, unit * 0.7)]), ink, width, true)
		MarkKind.CAPTURE:
			draw_line(center + Vector2(-unit, -unit), center + Vector2(unit, unit), Color(Color.WHITE, fade), width)
			draw_line(center + Vector2(-unit, unit), center + Vector2(unit, -unit), Color(Color.WHITE, fade), width)

func _ellipse(center: Vector2, radius: float, color: Color, width: float) -> void:
	draw_set_transform(center, 0.0, Vector2(1.0, 0.43))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 36, color, width / 0.43, true)
	draw_set_transform(Vector2.ZERO)

func _dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash: float) -> void:
	if from.distance_to(to) < 0.5:
		return
	draw_dashed_line(from, to, color, width, dash, true, true)

func _dashed_circle(center: Vector2, radius: float, color: Color, width: float, dash: float) -> void:
	var segments: int = clampi(roundi(TAU * radius / maxf(dash * 2.0, 0.001)), 12, 160)
	var step: float = TAU / segments
	for index: int in segments:
		var start: float = index * step
		draw_arc(center, radius, start, start + step * 0.55, 3, color, width, true)

func _cross(center: Vector2, size: float, color: Color, width: float) -> void:
	draw_line(center + Vector2(-size, -size), center + Vector2(size, size), color, width, true)
	draw_line(center + Vector2(-size, size), center + Vector2(size, -size), color, width, true)

func _diamond(center: Vector2, size: float, color: Color) -> void:
	draw_colored_polygon(PackedVector2Array([center + Vector2(0, -size), center + Vector2(size, 0), center + Vector2(0, size), center + Vector2(-size, 0)]), color)

## Constant on-screen text size at any zoom.
func _label(position: Vector2, text: String, color: Color, pixel: float) -> void:
	draw_set_transform(position, 0.0, Vector2.ONE * pixel)
	draw_string_outline(_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0.15, 0.12, 0.08, 0.75 * color.a))
	draw_string(_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)
	draw_set_transform(Vector2.ZERO)

func _on_reliable_behavior(notice: SimulationNotice) -> void:
	if not show_marks or notice.held:
		return
	var pose: PublishedPose = notice.pose
	var kind: int = _mark_for(pose.species, notice.previous_behavior, pose.behavior)
	if kind >= 0:
		_add_mark(pose.handle, kind as MarkKind, notice.position, notice.tick)

func _clear_old_epochs() -> void:
	# New-epoch events can arrive before its first completed display frame.
	for index: int in range(_marks.size() - 1, -1, -1):
		if _marks[index].handle.world_epoch < _view._epoch:
			_marks.remove_at(index)
	for slot: int in _last_mark.keys():
		if _last_mark[slot].handle.world_epoch < _view._epoch:
			_last_mark.erase(slot)
	hovered = null
