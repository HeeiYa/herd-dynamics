class_name ObserverCamera
extends Camera2D
## Observer-only view. Never changes simulation rates or quality.
##
## The camera keeps a "focus": the world point shown at the center of the
## usable pasture rectangle (the viewport minus HUD panels). All screen/world
## conversions go through this class, so selection, picking, drop previews and
## follow agree with what is drawn. Animation uses wall-clock UI time and keeps
## working while the simulation is paused.

enum Mode { OVERVIEW, FREE, FOLLOW }

signal mode_changed(new_mode: Mode)
## Follow ended because the target life is gone (death, removal or reset).
signal follow_lost

const MAX_ZOOM: float = 4.0
const WHEEL_FACTOR: float = 1.25
# Wheel targets close to an integer zoom snap to it, keeping pixel art crisp.
const INTEGER_SNAP: float = 0.07
const ZOOM_RATE: float = 14.0
const FOLLOW_RATE: float = 5.0
const OVERVIEW_MARGIN: float = 24.0
# Follow tolerates this fraction of the usable half-size before moving.
const FOLLOW_DEAD_ZONE: float = 0.12
# The world may be pushed this far (world px) past the pasture edge.
const EDGE_SLACK: float = 80.0

var mode: Mode = Mode.OVERVIEW
var follow_handle: AgentHandle
var focus: Vector2 = Vector2.ZERO
var zoom_level: float = 1.0
# Overview zoom relative to the fit; benchmarks may request a closer view.
var overview_scale: float = 1.0

var _world_size: Vector2 = Vector2(1600, 1000)
var _usable: Rect2 = Rect2(0, 0, 1280, 800)
var _target_zoom: float = 1.0
var _target_focus: Vector2 = Vector2.ZERO
var _animating_focus: bool = false
# Wheel zoom keeps this world point under this screen point while animating.
var _zoom_anchor_world: Vector2 = Vector2.ZERO
var _zoom_anchor_screen: Vector2 = Vector2.ZERO
var _anchored_zoom: bool = false
var _dragging: bool = false
var _position_source: Callable

func setup(world_size: Vector2, position_source: Callable) -> void:
	_world_size = world_size
	# position_source(handle) -> Variant: Vector2 display foot, or null when gone.
	_position_source = position_source
	# Update after the runner and main so follow reads this frame's display.
	process_priority = 20
	position_smoothing_enabled = false
	ignore_rotation = true
	anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	show_overview(true)

## The HUD reports the screen rectangle that still shows the pasture.
func set_usable_rect(rect: Rect2) -> void:
	if rect.size.x < 64.0 or rect.size.y < 64.0:
		return
	var anchor: Vector2 = focus
	_usable = rect
	if mode == Mode.OVERVIEW:
		show_overview(true, overview_scale)
		return
	focus = anchor
	_target_focus = anchor
	_apply()

func usable_rect() -> Rect2:
	return _usable

func overview_zoom() -> float:
	var available: Vector2 = _usable.size - Vector2.ONE * OVERVIEW_MARGIN * 2.0
	return maxf(0.05, minf(available.x / _world_size.x, available.y / _world_size.y))

func min_zoom() -> float:
	return minf(overview_zoom() * 0.85, 1.0)

func screen_to_world(screen: Vector2) -> Vector2:
	return focus + (screen - _usable.get_center()) / zoom_level

func world_to_screen(world: Vector2) -> Vector2:
	return _usable.get_center() + (world - focus) * zoom_level

func is_on_pasture_screen(screen: Vector2) -> bool:
	return _usable.has_point(screen)

func show_overview(immediate: bool = false, scale: float = 1.0) -> void:
	_set_mode(Mode.OVERVIEW)
	overview_scale = scale
	follow_handle = null
	_anchored_zoom = false
	_target_zoom = overview_zoom() * scale
	_target_focus = _world_size * 0.5
	_animating_focus = true
	if immediate:
		zoom_level = _target_zoom
		focus = _target_focus
		_animating_focus = false
		_apply()

## Starts following one complete life. Returns false when it is not on view.
func follow(handle: AgentHandle) -> bool:
	if handle == null or _position_source.call(handle) == null:
		return false
	follow_handle = handle
	_set_mode(Mode.FOLLOW)
	# Following from the overview zooms in to a readable scale.
	if zoom_level < 1.5:
		_target_zoom = clampf(2.0, min_zoom(), MAX_ZOOM)
		_anchored_zoom = false
	return true

func stop_follow() -> void:
	if mode == Mode.FOLLOW:
		follow_handle = null
		_set_mode(Mode.FREE)

func zoom_at(screen: Vector2, steps: int) -> void:
	var target: float = _target_zoom * pow(WHEEL_FACTOR, steps)
	var nearest_integer: float = roundf(target)
	if nearest_integer >= 1.0 and absf(target - nearest_integer) / nearest_integer < INTEGER_SNAP:
		target = nearest_integer
	_target_zoom = clampf(target, min_zoom(), MAX_ZOOM)
	if mode == Mode.FOLLOW:
		# Following keeps the target centered; zoom around it, not the cursor.
		_anchored_zoom = false
		return
	_zoom_anchor_screen = screen
	_zoom_anchor_world = screen_to_world(screen)
	_anchored_zoom = true
	_animating_focus = false
	_set_mode(Mode.FREE)

func begin_drag() -> void:
	_dragging = true

func end_drag() -> void:
	_dragging = false

func is_dragging() -> bool:
	return _dragging

## Manual panning always leaves follow and overview.
func pan_screen(relative: Vector2) -> void:
	stop_follow()
	_set_mode(Mode.FREE)
	_anchored_zoom = false
	_animating_focus = false
	focus -= relative / zoom_level
	_target_focus = focus
	_clamp_focus()
	_apply()

func _process(delta: float) -> void:
	var blend: float = 1.0 - exp(-ZOOM_RATE * delta)
	if absf(zoom_level - _target_zoom) > 0.0005:
		zoom_level = lerpf(zoom_level, _target_zoom, blend)
	else:
		zoom_level = _target_zoom
	if _anchored_zoom:
		focus = _zoom_anchor_world - (_zoom_anchor_screen - _usable.get_center()) / zoom_level
		if zoom_level == _target_zoom:
			_anchored_zoom = false
	if mode == Mode.FOLLOW:
		_update_follow(delta)
	elif _animating_focus:
		focus = focus.lerp(_target_focus, blend)
		if focus.distance_to(_target_focus) < 0.25:
			focus = _target_focus
			_animating_focus = false
	_clamp_focus()
	_apply()

func _update_follow(delta: float) -> void:
	var source: Variant = _position_source.call(follow_handle)
	if source == null:
		# Stay on the last valid place; never jump to a recycled slot.
		follow_handle = null
		_set_mode(Mode.FREE)
		follow_lost.emit()
		return
	var target: Vector2 = source
	var tolerance: Vector2 = _usable.size * FOLLOW_DEAD_ZONE / zoom_level
	var offset: Vector2 = target - focus
	var excess := Vector2(
		signf(offset.x) * maxf(0.0, absf(offset.x) - tolerance.x),
		signf(offset.y) * maxf(0.0, absf(offset.y) - tolerance.y))
	focus += excess * (1.0 - exp(-FOLLOW_RATE * delta))

func _clamp_focus() -> void:
	var half: Vector2 = _usable.size * 0.5 / zoom_level
	for axis: int in 2:
		var lower: float = half[axis] - EDGE_SLACK
		var upper: float = _world_size[axis] - half[axis] + EDGE_SLACK
		if lower > upper:
			focus[axis] = _world_size[axis] * 0.5
		else:
			focus[axis] = clampf(focus[axis], lower, upper)

func _apply() -> void:
	zoom = Vector2.ONE * zoom_level
	var viewport_center: Vector2 = get_viewport_rect().size * 0.5
	position = focus + (viewport_center - _usable.get_center()) / zoom_level

func _set_mode(next: Mode) -> void:
	if mode == next:
		return
	mode = next
	mode_changed.emit(mode)

## A new world invalidates the prior bounds, follow handle and camera transition.
func set_world_size(size: Vector2) -> void:
	stop_follow()
	_world_size = size
	show_overview(true)
