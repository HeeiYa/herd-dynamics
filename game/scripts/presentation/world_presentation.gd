class_name WorldPresentation
extends Node2D
## Presentation owns no simulation truth. All records hold full lifetime handles.

@export var body_scale: float = 1.0
var visible_count: int = 0
var capture_visible_count: int = 0
var render_build_usec: int = 0
var sort_usec: int = 0
var selected_handle: AgentHandle

class Change extends RefCounted:
	var tick: int
	var action: int = -1
	var direction: int = -1

class DrawEntry extends RefCounted:
	var handle: AgentHandle
	var foot: Vector2
	var area: Rect2
	var region: Rect2
	var tint: Color = Color.WHITE
	var is_capture: bool = false

class AnimationState extends RefCounted:
	var handle: AgentHandle
	var action: int = AnimationCatalog.Action.SHEEP_IDLE
	var direction: int = 0
	var latest_action: int = -1
	var latest_direction: int = 0
	var started_tick: int = 0
	var phase_ms: float = 0.0
	var latest_position: Vector2 = Vector2.ZERO
	var changes: Array[Change] = []
	var drawing: DrawEntry = DrawEntry.new()

class CaptureVisual extends RefCounted:
	var handle: AgentHandle
	var position: Vector2
	var previous_position: Vector2
	var direction: int = 0
	var started_tick: int = 0
	var previous_action: int = AnimationCatalog.Action.SHEEP_IDLE
	var previous_started_tick: int = 0
	var previous_direction: int = 0
	var previous_phase_ms: float = 0.0
	var drawing: DrawEntry = DrawEntry.new()

class SelectionOverlay extends Node2D:
	var selected_position: Vector2 = Vector2.ZERO
	var has_selection: bool = false

	func _draw() -> void:
		if not has_selection:
			return
		draw_set_transform(selected_position, 0.0, Vector2(1.0, 0.43))
		draw_arc(Vector2.ZERO, 20.0, 0.0, TAU, 40, Color("#f7e9a2"), 2.5, true)
		draw_set_transform(Vector2.ZERO)

var _store: AgentStore
var _intents: IntentBuffer
var _resources: ResourceGrid
var _config: SimulationConfig
var _catalog: AnimationCatalog = AnimationCatalog.new()
var _states: Array[AnimationState] = []
var _draw_list: Array[DrawEntry] = []
var _captures: Array[CaptureVisual] = []
var _ground_chunks: Array[GrassChunk] = []
var _shadows: MultiMeshInstance2D
var _selection: SelectionOverlay
var _shadow_capacity: int = 0
var _epoch: int = -1
var _observed_tick: int = -1
var _seed: int = 42

func setup(store: AgentStore, intents: IntentBuffer, resources: ResourceGrid, config: SimulationConfig) -> void:
	_store = store
	_intents = intents
	_resources = resources
	_config = config
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_catalog.load_assets()
	_create_ground()
	_create_shadows()
	_selection = SelectionOverlay.new()
	_selection.z_index = -1
	add_child(_selection)
	_clear_epoch()

func set_seed(random_seed: int) -> void:
	_seed = random_seed

func set_selected(handle: AgentHandle) -> void:
	selected_handle = handle if _store != null and _store.is_alive(handle) else null

func _clear_epoch() -> void:
	_epoch = _store.epoch
	_states.clear()
	_draw_list.clear()
	_captures.clear()
	selected_handle = null
	_observed_tick = -1
	for chunk: GrassChunk in _ground_chunks:
		chunk.levels.fill(-1)

func _create_ground() -> void:
	var rich: Texture2D = load("res://assets/grass_tile.png") as Texture2D
	var grazed: Texture2D = load("res://assets/grass_grazed_tile.png") as Texture2D
	const CHUNK_CELLS: int = 4
	for top: int in range(0, _resources.rows, CHUNK_CELLS):
		for left: int in range(0, _resources.columns, CHUNK_CELLS):
			var indices: PackedInt32Array = PackedInt32Array()
			for y: int in range(top, mini(top + CHUNK_CELLS, _resources.rows)):
				for x: int in range(left, mini(left + CHUNK_CELLS, _resources.columns)):
					indices.append(y * _resources.columns + x)
			var chunk := GrassChunk.new()
			chunk.z_index = -3
			chunk.configure(_resources, indices, rich, grazed, _config.world_size)
			add_child(chunk)
			_ground_chunks.append(chunk)

func _create_shadows() -> void:
	_shadows = MultiMeshInstance2D.new()
	_shadows.z_index = -2
	_shadows.texture = load("res://assets/shadow_ellipse.png") as Texture2D
	var mesh := QuadMesh.new()
	mesh.size = Vector2(25.0, 11.0) * body_scale
	var instances := MultiMesh.new()
	# Format is immutable while allocated; configure before setting instance_count.
	instances.transform_format = MultiMesh.TRANSFORM_2D
	instances.use_colors = true
	instances.mesh = mesh
	_shadows.multimesh = instances
	_shadows.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_shadows)

## Call after every fixed-step publication, including catch-up steps. No draw work here.
func observe_published(tick: int) -> void:
	if _store == null:
		return
	if _epoch != _store.epoch:
		_clear_epoch()
	if tick <= _observed_tick:
		return
	_observed_tick = tick
	if _states.size() < _store.capacity:
		_states.resize(_store.capacity)
	for dense: int in _store.count:
		var handle: AgentHandle = _store.handle_at(dense)
		var state: AnimationState = _states[handle.slot]
		var intent: MotionIntent = _intents.get_intent(handle, maxi(0, tick - 1))
		var behavior: int = SimTypes.Behavior.IDLE
		var pressure: bool = false
		if intent != null:
			behavior = intent.behavior
			pressure = intent.mode == SimTypes.IntentMode.PRESSURE
		var moving: bool = _store.velocity_current[dense].length_squared() > 9.0
		var action: int = AnimationCatalog.action_for(_store.species[dense], behavior, moving, pressure)
		if state == null or not state.handle.same_life(handle):
			state = _new_state(handle, action, _store.facing[dense], maxi(0, tick - 1))
			_states[handle.slot] = state
		_record_changes(state, action, _store.facing[dense], tick)
		state.latest_position = _store.position_current[dense]

func _new_state(handle: AgentHandle, action: int, facing: Vector2, tick: int) -> AnimationState:
	var state := AnimationState.new()
	state.handle = handle
	state.drawing.handle = handle
	state.action = action
	state.latest_action = action
	state.direction = AnimationCatalog.direction_for(facing, 0)
	state.latest_direction = state.direction
	state.started_tick = tick
	state.phase_ms = _phase_for(handle, action, state.direction)
	return state

func _record_changes(state: AnimationState, action: int, facing: Vector2, tick: int) -> void:
	if action != state.latest_action:
		var change := Change.new()
		# Decisions made at n drive movement over [n,n+1].
		change.tick = maxi(0, tick - 1)
		change.action = action
		state.changes.append(change)
		state.latest_action = action
	var direction: int = AnimationCatalog.direction_for(facing, state.latest_direction)
	if direction != state.latest_direction:
		var change := Change.new()
		change.tick = tick
		change.direction = direction
		state.changes.append(change)
		state.latest_direction = direction

func _phase_for(handle: AgentHandle, action: int, direction: int) -> float:
	var clip: AnimationCatalog.Clip = _catalog.get_clip(action, direction)
	if not clip.random_phase:
		return 0.0
	# Identity and scenario seed derive a visual stream, never the simulation RNG.
	var stable_hash: int = hash(Vector4i(handle.slot, handle.generation, handle.world_epoch, _seed ^ action))
	return float(posmod(stable_hash, clip.duration_ms))

func _advance_state(state: AnimationState, display_tick: float) -> void:
	while not state.changes.is_empty() and state.changes[0].tick <= display_tick:
		var change: Change = state.changes.pop_front()
		if change.action >= 0:
			state.action = change.action
			state.started_tick = change.tick
			state.phase_ms = _phase_for(state.handle, state.action, state.direction)
		if change.direction >= 0:
			state.direction = change.direction

func present(tick: int, alpha: float, direct: bool = false) -> void:
	if _store == null:
		return
	var started_usec: int = Time.get_ticks_usec()
	observe_published(tick)
	var interpolation: float = clampf(alpha, 0.0, 1.0)
	var display_tick: float = float(tick) if direct else maxf(0.0, tick - 1 + interpolation)
	for chunk: GrassChunk in _ground_chunks:
		chunk.update_at(display_tick)
	_draw_list.clear()
	visible_count = 0
	capture_visible_count = 0
	var visible_world: Rect2 = get_global_transform_with_canvas().affine_inverse() * get_viewport_rect()
	for dense: int in _store.count:
		if _store.alive[dense] == 0:
			continue
		var handle: AgentHandle = _store.handle_at(dense)
		var state: AnimationState = _states[handle.slot]
		_advance_state(state, display_tick)
		var foot: Vector2 = _store.position_current[dense]
		if not direct:
			foot = _store.position_previous[dense].lerp(foot, interpolation)
		var elapsed_ms: float = (display_tick - state.started_tick) * _config.fixed_dt * 1000.0 + state.phase_ms
		_prepare_drawing(state.drawing, foot, state.action, state.direction, elapsed_ms)
		if state.drawing.area.intersects(visible_world):
			_draw_list.append(state.drawing)
			visible_count += 1
	_append_captures(display_tick, visible_world)
	var sort_start: int = Time.get_ticks_usec()
	_draw_list.sort_custom(_draw_before)
	sort_usec = Time.get_ticks_usec() - sort_start
	_update_shadows()
	_update_selection(interpolation, direct)
	queue_redraw()
	render_build_usec = Time.get_ticks_usec() - started_usec

func _prepare_drawing(entry: DrawEntry, foot: Vector2, action: int, direction: int, elapsed_ms: float) -> void:
	var clip: AnimationCatalog.Clip = _catalog.get_clip(action, direction)
	entry.foot = foot
	entry.region = clip.frame_at(elapsed_ms)
	entry.area = Rect2(foot - clip.pivot * body_scale, entry.region.size * body_scale)

static func _draw_before(first: DrawEntry, second: DrawEntry) -> bool:
	if first.foot.y != second.foot.y:
		return first.foot.y < second.foot.y
	if first.handle.slot != second.handle.slot:
		return first.handle.slot < second.handle.slot
	if first.handle.generation != second.handle.generation:
		return first.handle.generation < second.handle.generation
	return first.handle.world_epoch < second.handle.world_epoch

func _update_shadows() -> void:
	var required: int = _draw_list.size()
	if required > _shadow_capacity:
		_shadow_capacity = maxi(128, maxi(required, _shadow_capacity * 2))
		_shadows.multimesh.instance_count = _shadow_capacity
	_shadows.multimesh.visible_instance_count = required
	for index: int in required:
		var foot: Vector2 = _draw_list[index].foot
		_shadows.multimesh.set_instance_transform_2d(index, Transform2D(0.0, foot + Vector2(0.0, -2.0)))
		_shadows.multimesh.set_instance_color(index, _draw_list[index].tint)

func _update_selection(alpha: float, direct: bool) -> void:
	var dense: int = _store.resolve(selected_handle)
	_selection.has_selection = dense >= 0
	if dense < 0:
		selected_handle = null
	else:
		_selection.selected_position = _store.position_current[dense]
		if not direct:
			_selection.selected_position = _store.position_previous[dense].lerp(_selection.selected_position, alpha)
	_selection.queue_redraw()

func _draw() -> void:
	if _catalog.texture == null:
		return
	# One texture/material and one globally sorted body submission stream.
	for entry: DrawEntry in _draw_list:
		draw_texture_rect_region(_catalog.texture, entry.area, entry.region, entry.tint, false, true)

func pick(world_point: Vector2) -> AgentHandle:
	for index: int in range(_draw_list.size() - 1, -1, -1):
		var entry: DrawEntry = _draw_list[index]
		if not entry.is_capture and entry.area.has_point(world_point) and _store.is_alive(entry.handle):
			return entry.handle
	return null

func add_capture(handle: AgentHandle, position: Vector2, facing: Vector2, tick: int) -> void:
	if _store == null or handle.world_epoch != _store.epoch:
		return
	var visual := CaptureVisual.new()
	visual.handle = handle
	visual.position = position
	visual.previous_position = position
	visual.direction = AnimationCatalog.direction_for(facing, 0)
	visual.started_tick = tick
	visual.drawing.handle = handle
	visual.drawing.is_capture = true
	# Copy display facts before a slot is reused. Never resolve this old life again.
	if handle.slot < _states.size():
		var state: AnimationState = _states[handle.slot]
		if state != null and state.handle.same_life(handle):
			_advance_state(state, maxi(0, tick - 1))
			visual.previous_direction = state.direction
			visual.previous_position = state.latest_position
			visual.previous_action = state.action
			visual.previous_started_tick = state.started_tick
			visual.previous_phase_ms = state.phase_ms
	_captures.append(visual)

func _append_captures(display_tick: float, visible_world: Rect2) -> void:
	for index: int in range(_captures.size() - 1, -1, -1):
		var visual: CaptureVisual = _captures[index]
		var clip: AnimationCatalog.Clip = _catalog.get_clip(AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction)
		var elapsed_ms: float = (display_tick - visual.started_tick) * _config.fixed_dt * 1000.0
		var lifetime_ms: float = clip.duration_ms + 900.0
		if elapsed_ms >= lifetime_ms:
			_captures.remove_at(index)
			continue
		if elapsed_ms < 0.0:
			var alpha: float = clampf(display_tick - visual.started_tick + 1.0, 0.0, 1.0)
			var foot: Vector2 = visual.previous_position.lerp(visual.position, alpha)
			var previous_ms: float = (display_tick - visual.previous_started_tick) * _config.fixed_dt * 1000.0 + visual.previous_phase_ms
			_prepare_drawing(visual.drawing, foot, visual.previous_action, visual.previous_direction, previous_ms)
		else:
			_prepare_drawing(visual.drawing, visual.position, AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction, elapsed_ms)
		visual.drawing.tint.a = clampf((lifetime_ms - elapsed_ms) / 400.0, 0.0, 1.0)
		if visual.drawing.area.intersects(visible_world):
			_draw_list.append(visual.drawing)
			capture_visible_count += 1
