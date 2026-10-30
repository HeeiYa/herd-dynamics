class_name GrabTool
extends Node2D
## Observer intervention: lift one life and put it down elsewhere.
##
## The tool only submits commands (SimulationWorld.queue_hold / queue_drop) and
## draws previews. The world applies them at the next stage 0, so while paused
## the lifted body is a preview labelled "pending" until a step runs. Every
## record keeps the complete handle; a dead, removed, reset or recycled life
## ends the operation with a message instead of acting on a new life.

enum State { IDLE, CARRYING, DROP_PENDING }

signal message(text: String)

var state: State = State.IDLE
var handle: AgentHandle
var pointer_world: Vector2 = Vector2.ZERO
var pointer_valid: bool = false
var camera_zoom: float = 1.0
# Mirrors the runner each frame; paused commands are labelled as pending.
var paused: bool = false

var _world: SimulationWorld
var _view: WorldPresentation
var _origin: Vector2 = Vector2.ZERO
var _drop_position: Vector2 = Vector2.ZERO
var _region: Array = []
var _font: Font

func setup(world: SimulationWorld, view: WorldPresentation) -> void:
	_world = world
	_view = view
	_font = UiStyle.interface_theme().default_font
	z_index = 6
	_view.epoch_cleared.connect(_on_epoch_cleared)

func is_busy() -> bool:
	return state != State.IDLE

## Left press on a body with the grab tool. Returns true when a lift starts.
func begin(target: AgentHandle, world_point: Vector2) -> bool:
	if state != State.IDLE or target == null or not _world.store.is_active(target):
		return false
	var foot: Variant = _view.display_foot(target)
	handle = target
	_origin = foot if foot != null else world_point
	_region = _view.body_region(target)
	pointer_world = world_point
	pointer_valid = true
	state = State.CARRYING
	_world.queue_hold(target)
	return true

## Left release. Invalid places return the body where it was picked up.
func release() -> void:
	if state != State.CARRYING:
		return
	if not pointer_valid:
		message.emit("此处不能放置，已放回原处")
		_queue_drop(_origin)
		return
	_queue_drop(pointer_world)

## Esc or right click: put the body back, or withdraw a lift not yet applied.
func cancel() -> void:
	if state == State.IDLE:
		return
	if state == State.CARRYING and _world.cancel_pending_hold(handle):
		message.emit("已取消抓取")
		_finish()
		return
	if state == State.CARRYING:
		message.emit("已取消，放回原处")
		_queue_drop(_origin)

func _queue_drop(position: Vector2) -> void:
	_drop_position = position
	_world.queue_drop(handle, position)
	state = State.DROP_PENDING
	if _world.store.is_held(handle) or _world.is_hold_pending(handle):
		message.emit("放下指令将在下一模拟步生效" if paused else "")

## Called every frame after the runner. Resolves pending phases and failures.
func update_state(runner_paused: bool) -> void:
	paused = runner_paused
	if state == State.IDLE:
		return
	if not _world.store.is_alive(handle):
		message.emit("被抓取的角色已不在牧场，操作结束")
		_finish()
		return
	if state == State.DROP_PENDING and not _world.store.is_held(handle) and not _world.is_hold_pending(handle):
		_finish()
		return
	if state == State.CARRYING and not _world.store.is_held(handle) and not _world.is_hold_pending(handle):
		# The lift was rejected at stage 0 (for example, the life died first).
		message.emit("无法抓取：角色状态已变化")
		_finish()
	queue_redraw()

func _finish() -> void:
	state = State.IDLE
	handle = null
	_region = []
	queue_redraw()

func _on_epoch_cleared() -> void:
	if state != State.IDLE:
		message.emit("场景已重置，抓取已结束")
	_finish()

func _draw() -> void:
	if state == State.IDLE or _region.is_empty():
		return
	var pixel: float = 1.0 / maxf(camera_zoom, 0.05)
	var ground: Vector2 = pointer_world if state == State.CARRYING else _drop_position
	var ring: Color = UiStyle.VALID_DROP if pointer_valid or state == State.DROP_PENDING else UiStyle.INVALID_DROP
	# Ground preview: where the body would land, plus the lift origin.
	draw_set_transform(ground, 0.0, Vector2(1.0, 0.43))
	draw_circle(Vector2.ZERO, 15.0, Color(ring, 0.25), true, -1.0, true)
	draw_arc(Vector2.ZERO, 15.0, 0.0, TAU, 32, ring, 2.0 * pixel / 0.43, true)
	draw_set_transform(_origin, 0.0, Vector2(1.0, 0.43))
	draw_arc(Vector2.ZERO, 12.0, 0.0, TAU, 24, Color(UiStyle.PAPER, 0.6), 1.0 * pixel / 0.43, true)
	draw_set_transform(Vector2.ZERO)
	if state == State.CARRYING:
		draw_dashed_line(_origin, ground, Color(UiStyle.PAPER, 0.5), 1.0 * pixel, 5.0 * pixel, true, true)
	# Lifted body floats above its landing point.
	var texture: Texture2D = _region[0]
	var region: Rect2 = _region[1]
	var pivot: Vector2 = _region[2]
	var lift: float = 14.0 if state == State.CARRYING else 6.0
	var body := Rect2(ground - pivot - Vector2(0, lift), region.size * _view.body_scale)
	draw_texture_rect_region(texture, body, region, Color(1, 1, 1, 0.92))
	var text: String = "提起中" if state == State.CARRYING else "放下中"
	if paused:
		text += " · 待生效"
	draw_set_transform(ground + Vector2(14, -lift - 24) * pixel, 0.0, Vector2.ONE * pixel)
	draw_string_outline(_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0.15, 0.12, 0.08, 0.8))
	draw_string(_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiStyle.PAPER)
	draw_set_transform(Vector2.ZERO)
