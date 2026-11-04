class_name WorldPresentation
extends Node2D
## Presentation owns no simulation truth. All records hold full lifetime handles.

@export var body_scale: float = 1.0
var probes: Probes
var visible_count: int = 0
var capture_visible_count: int = 0
var render_build_usec: int = 0
var sort_usec: int = 0
var sort_moves: int = 0
var sort_used_fallback: bool = false
var selected_handle: AgentHandle
var held_hidden_count: int = 0
# Display time of the last present() call; overlays align with it.
var display_tick: float = 0.0
var display_direct: bool = false

## Published behavior transitions, emitted once per life and change. Only the
## intent in effect drives it, never a task attempt or an animation frame.
signal behavior_changed(handle: AgentHandle, species: int, previous: int, current: int, tick: int)
## The world epoch changed; every life-scoped visual must be dropped.
signal epoch_cleared

class Change extends RefCounted:
	var tick: int
	var action: int = -1
	var direction: int = -1
	# -2 means no cue change; -1 explicitly cancels the previous cue.
	var cue_action: int = -2
	var cue_started_tick: int = 0

class DrawEntry extends RefCounted:
	var handle: AgentHandle
	var foot: Vector2
	var area: Rect2
	var region: Rect2
	var tint: Color = Color.WHITE
	var is_capture: bool = false
	var visible_frame: int = -1
	var listed: bool = false
	var clip_index: int = 0
	var local_animation_ms: float = 0.0

class AnimationState extends RefCounted:
	var handle: AgentHandle
	var action: int = AnimationCatalog.Action.SHEEP_IDLE
	var direction: int = 0
	var latest_action: int = -1
	var latest_behavior: int = SimTypes.Behavior.IDLE
	var latest_direction: int = 0
	var started_tick: int = 0
	var phase_ms: float = 0.0
	var latest_position: Vector2 = Vector2.ZERO
	var cue_action: int = -1
	var cue_started_tick: int = 0
	var latest_pose: PublishedPose
	var pose_history: PublishedPose.History
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
	var previous_cue_action: int = -1
	var previous_cue_started_tick: int = 0
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
var _ground: GroundLayer
var _shadows: MultiMeshInstance2D
var _selection: SelectionOverlay
var _shadow_capacity: int = 0
var _epoch: int = -1
var _observed_tick: int = -1
var _seed: int = 42
var _presentation_frame: int = 0
var _incremental_sort_active: bool = false
var _instance_animator: InstanceAnimator
var _visual_sample := AnimationCatalog.VisualSample.new()

func _init(instrumentation: Probes = null) -> void:
	probes = instrumentation if instrumentation != null else Probes.new()

func setup(store: AgentStore, intents: IntentBuffer, resources: ResourceGrid, config: SimulationConfig) -> void:
	_store = store
	_intents = intents
	_resources = resources
	_config = config
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_catalog.load_assets()
	_ground = GroundLayer.new()
	_ground.z_index = -3
	_ground.configure(_resources, _config.world_size)
	add_child(_ground)
	_create_shadows()
	if _config.gpu_presentation:
		_instance_animator = InstanceAnimator.new()
		_instance_animator.setup(self, _catalog)
	_selection = SelectionOverlay.new()
	_selection.z_index = -1
	add_child(_selection)
	_clear_epoch()

func set_seed(random_seed: int) -> void:
	_seed = random_seed

## Adopt owned read-only data on the main thread; art and draw buffers stay local.
func bind_publication(access: SimulationAccess) -> void:
	_store = access.store
	_intents = access.intents
	_resources = access.resources
	_config = access.config
	_ground.bind_resources(_resources, _config.world_size)
	if _seed != access.scenario.random_seed:
		set_seed(access.scenario.random_seed)

func set_selected(handle: AgentHandle) -> void:
	selected_handle = handle if _store != null and _store.is_alive(handle) else null

func _clear_epoch() -> void:
	_epoch = _store.epoch
	_states.clear()
	_reset_draw_list()
	_captures.clear()
	selected_handle = null
	_observed_tick = -1
	if _ground != null:
		_ground.clear_levels()
	epoch_cleared.emit()

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
	var started_usec: int = Time.get_ticks_usec() if probes.enabled else 0
	_observed_tick = tick
	if _states.size() < _store.capacity:
		_states.resize(_store.capacity)
	for dense: int in _store.count:
		var handle: AgentHandle = _store.handle_at(dense)
		var state: AnimationState = _states[handle.slot]
		var intent: MotionIntent = _intents.get_intent(handle, maxi(0, tick - 1))
		var moving: bool = _store.velocity_current[dense].length_squared() > 9.0
		if state == null or not state.handle.same_life(handle):
			state = AnimationState.new()
			state.handle = handle
			state.drawing.handle = handle
			state.pose_history = PublishedPose.History.new()
			var first: PublishedPose = PublishedPose.sample(handle, _store.species[dense], intent, moving, _store.facing[dense], tick, null, state.pose_history)
			state.action = first.action
			state.latest_action = first.action
			state.direction = first.direction
			state.latest_direction = first.direction
			state.started_tick = first.started_tick
			state.phase_ms = _phase_for(handle, first.action, first.phase_direction)
			state.latest_behavior = first.behavior
			state.latest_pose = first
			_states[handle.slot] = state
			# A life first seen mid-behavior (its decision ran before the first
			# publication) still reports that transition once, from IDLE.
			if first.behavior != SimTypes.Behavior.IDLE:
				behavior_changed.emit(handle, _store.species[dense], SimTypes.Behavior.IDLE, first.behavior, maxi(0, tick - 1))
		else:
			var pose: PublishedPose = PublishedPose.sample(handle, _store.species[dense], intent, moving, _store.facing[dense], tick, state.latest_pose, state.pose_history)
			_record_changes(state, pose, tick)
			if pose.behavior != state.latest_behavior:
				behavior_changed.emit(handle, _store.species[dense], state.latest_behavior, pose.behavior, maxi(0, tick - 1))
			state.latest_behavior = pose.behavior
			state.latest_pose = pose
		state.latest_position = _store.position_current[dense]
	if probes.enabled:
		probes.record(Probes.Tag.VISUAL_PUBLISH, Time.get_ticks_usec() - started_usec)

func _record_changes(state: AnimationState, pose: PublishedPose, tick: int) -> void:
	var cue_changed: bool = pose.cue_action != state.latest_pose.cue_action or pose.cue_started_tick != state.latest_pose.cue_started_tick
	if pose.action != state.latest_action or cue_changed:
		var change := Change.new()
		# Decisions made at n drive movement over [n,n+1].
		change.tick = maxi(0, tick - 1)
		if pose.action != state.latest_action:
			change.action = pose.action
		if cue_changed:
			change.cue_action = pose.cue_action
			change.cue_started_tick = pose.cue_started_tick
		state.changes.append(change)
		state.latest_action = pose.action
	if pose.direction != state.latest_direction:
		var change := Change.new()
		change.tick = tick
		change.direction = pose.direction
		state.changes.append(change)
		state.latest_direction = pose.direction

func _phase_for(handle: AgentHandle, action: int, direction: int) -> float:
	return phase_for_seed(handle, action, direction, _seed)

func phase_for_seed(handle: AgentHandle, action: int, direction: int, seed_value: int) -> float:
	var clip: AnimationCatalog.Clip = _catalog.get_clip(action, direction)
	if not clip.random_phase:
		return 0.0
	# Identity and scenario seed derive a visual stream, never the simulation RNG.
	var stable_hash: int = hash(Vector4i(handle.slot, handle.generation, handle.world_epoch, seed_value ^ action))
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
		if change.cue_action >= -1:
			state.cue_action = change.cue_action
			state.cue_started_tick = change.cue_started_tick

func present(tick: int, alpha: float, direct: bool = false) -> void:
	if _store == null:
		return
	var started_usec: int = Time.get_ticks_usec()
	observe_published(tick)
	var interpolation: float = clampf(alpha, 0.0, 1.0)
	display_tick = float(tick) if direct else maxf(0.0, tick - 1 + interpolation)
	display_direct = direct
	var grass_start: int = Time.get_ticks_usec() if probes.enabled else 0
	_ground.update_at(display_tick)
	if probes.enabled:
		probes.record(Probes.Tag.GRASS, Time.get_ticks_usec() - grass_start)
	var bodies_start: int = Time.get_ticks_usec() if probes.enabled else 0
	_begin_draw_list()
	visible_count = 0
	capture_visible_count = 0
	held_hidden_count = 0
	var visible_world: Rect2 = get_global_transform_with_canvas().affine_inverse() * get_viewport_rect()
	for dense: int in _store.count:
		if _store.alive[dense] == 0:
			continue
		if _store.held[dense] != 0:
			# Lifted bodies are drawn by the grab tool, not in the pasture.
			held_hidden_count += 1
			continue
		var handle: AgentHandle = _store.handle_at(dense)
		var state: AnimationState = _states[handle.slot]
		_advance_state(state, display_tick)
		var foot: Vector2 = _store.position_current[dense]
		if not direct:
			foot = _store.position_previous[dense].lerp(foot, interpolation)
		var elapsed_ms: float = (display_tick - state.started_tick) * _config.fixed_dt * 1000.0 + state.phase_ms
		var cue_elapsed_ms: float = (display_tick - state.cue_started_tick) * _config.fixed_dt * 1000.0
		prepare_timeline_drawing(state.drawing, foot, state.action, state.direction, elapsed_ms, state.cue_action, cue_elapsed_ms, _config)
		if state.drawing.area.intersects(visible_world):
			_queue_drawing(state.drawing)
			visible_count += 1
	_append_captures(display_tick, visible_world)
	if probes.enabled:
		probes.record(Probes.Tag.BODY_PREPARE, Time.get_ticks_usec() - bodies_start)
	var sort_start: int = Time.get_ticks_usec()
	_finish_draw_list()
	sort_usec = Time.get_ticks_usec() - sort_start
	var shadows_start: int = Time.get_ticks_usec() if probes.enabled else 0
	if _config.gpu_presentation:
		if _instance_animator == null:
			_instance_animator = InstanceAnimator.new()
			_instance_animator.setup(self, _catalog)
		_instance_animator.set_enabled(true)
		_shadows.hide()
		_instance_animator.submit(_draw_list, body_scale, _config.world_size)
	else:
		if _instance_animator != null:
			_instance_animator.set_enabled(false)
		_shadows.show()
		_update_shadows()
	if probes.enabled:
		probes.record(Probes.Tag.BODY_SUBMIT if _config.gpu_presentation else Probes.Tag.SHADOWS, Time.get_ticks_usec() - shadows_start)
	_update_selection(interpolation, direct)
	queue_redraw()
	render_build_usec = Time.get_ticks_usec() - started_usec
	if probes.enabled:
		probes.record(Probes.Tag.BUILD, render_build_usec)
		probes.record(Probes.Tag.SORT, sort_usec)

func _prepare_drawing(entry: DrawEntry, foot: Vector2, action: int, direction: int, elapsed_ms: float) -> void:
	prepare_snapshot_drawing(entry, foot, action, direction, elapsed_ms, _config)

## Shared CPU/GPU and inline/worker clock resolution. Scratch never escapes
## this synchronous main-thread call; only completed values enter DrawEntry.
func prepare_timeline_drawing(entry: DrawEntry, foot: Vector2, action: int, direction: int, elapsed_ms: float, cue_action: int, cue_elapsed_ms: float, config: SimulationConfig) -> void:
	_catalog.resolve_visual(_visual_sample, action, direction, elapsed_ms, cue_action, cue_elapsed_ms)
	prepare_snapshot_drawing(entry, foot, _visual_sample.action, direction, _visual_sample.elapsed_ms, config)

func prepare_snapshot_drawing(entry: DrawEntry, foot: Vector2, action: int, direction: int, elapsed_ms: float, config: SimulationConfig) -> void:
	var clip: AnimationCatalog.Clip = _catalog.get_clip(action, direction)
	entry.foot = foot
	# Durations are integer milliseconds. Reduce in CPU double precision before
	# transport: integer local time is exact in float32 even after long sessions.
	if config.gpu_presentation:
		entry.clip_index = action * AnimationCatalog.DIRECTIONS.size() + direction
		var local_ms: float = maxf(elapsed_ms, 0.0)
		local_ms = fmod(local_ms, clip.duration_ms) if clip.loop else minf(local_ms, clip.duration_ms - 1)
		entry.local_animation_ms = floorf(local_ms)
	if config.gpu_presentation and clip.uniform_frame_size and not entry.is_capture:
		entry.region = clip.rectangles[0] # Bounds only; shader chooses atlas position.
	else:
		entry.region = clip.frame_at(elapsed_ms)
	entry.area = Rect2(foot - clip.pivot * body_scale, entry.region.size * body_scale)

func _reset_draw_list() -> void:
	for entry: DrawEntry in _draw_list:
		entry.listed = false
	_draw_list.clear()

func _begin_draw_list() -> void:
	_presentation_frame += 1
	if _incremental_sort_active != _config.incremental_render_sort:
		_reset_draw_list()
		_incremental_sort_active = _config.incremental_render_sort
	if not _incremental_sort_active:
		_draw_list.clear()

func _queue_drawing(entry: DrawEntry) -> void:
	if not _incremental_sort_active:
		_draw_list.append(entry)
		return
	entry.visible_frame = _presentation_frame
	if not entry.listed:
		entry.listed = true
		_draw_list.append(entry)

func _finish_draw_list() -> void:
	sort_moves = 0
	sort_used_fallback = false
	if not _incremental_sort_active:
		_draw_list.sort_custom(_draw_before)
		return
	# Preserve surviving entries in their previous order, including retired-life
	# capture visuals. Offscreen or expired entries cannot retain membership.
	var retained: int = 0
	for entry: DrawEntry in _draw_list:
		if entry.visible_frame == _presentation_frame:
			_draw_list[retained] = entry
			retained += 1
		else:
			entry.listed = false
	_draw_list.resize(retained)
	_repair_draw_order()

func _repair_draw_order() -> void:
	# Insertion repair is linear for nearly sorted frames. Bound shifts before
	# falling back so crossings, spawns and resets never cause quadratic work.
	var move_budget: int = maxi(32, _draw_list.size() * 4)
	for index: int in range(1, _draw_list.size()):
		var entry: DrawEntry = _draw_list[index]
		var gap: int = index
		while gap > 0 and _draw_before(entry, _draw_list[gap - 1]):
			_draw_list[gap] = _draw_list[gap - 1]
			gap -= 1
			sort_moves += 1
			if sort_moves >= move_budget:
				# Restore the displaced entry before handing the complete list over.
				_draw_list[gap] = entry
				_draw_list.sort_custom(_draw_before)
				sort_used_fallback = true
				return
		_draw_list[gap] = entry

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
	# A lifted body keeps its selection, but its ring belongs to the grab preview.
	_selection.has_selection = dense >= 0 and _store.held[dense] == 0
	if dense < 0:
		selected_handle = null
	else:
		_selection.selected_position = _store.position_current[dense]
		if not direct:
			_selection.selected_position = _store.position_previous[dense].lerp(_selection.selected_position, alpha)
	_selection.queue_redraw()

func _draw() -> void:
	if _catalog.texture == null or _config.gpu_presentation:
		return
	var started_usec: int = Time.get_ticks_usec() if probes.enabled else 0
	# One texture/material and one globally sorted body submission stream.
	for entry: DrawEntry in _draw_list:
		draw_texture_rect_region(_catalog.texture, entry.area, entry.region, entry.tint, false, true)
	if probes.enabled:
		probes.record(Probes.Tag.BODY_SUBMIT, Time.get_ticks_usec() - started_usec)

func pick(world_point: Vector2) -> AgentHandle:
	for index: int in range(_draw_list.size() - 1, -1, -1):
		var entry: DrawEntry = _draw_list[index]
		if not entry.is_capture and entry.area.has_point(world_point) and _store.is_active(entry.handle):
			return entry.handle
	return null

## Last displayed foot of a live life, or null once it is dead, removed or
## reset. A held life keeps the foot where it was lifted.
func display_foot(handle: AgentHandle) -> Variant:
	if handle == null or _store == null or not _store.is_alive(handle) or handle.slot >= _states.size():
		return null
	var state: AnimationState = _states[handle.slot]
	if state == null or not state.handle.same_life(handle):
		return null
	return state.drawing.foot

## Sprite region and pivot for drawing a life outside the pasture (lifted).
func body_region(handle: AgentHandle) -> Array:
	if handle == null or handle.slot >= _states.size():
		return []
	var state: AnimationState = _states[handle.slot]
	if state == null or not state.handle.same_life(handle):
		return []
	var clip: AnimationCatalog.Clip = _catalog.get_clip(state.action, state.direction)
	return [_catalog.texture, clip.frame_at(state.phase_ms), clip.pivot * body_scale]

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
			visual.previous_cue_action = state.cue_action
			visual.previous_cue_started_tick = state.cue_started_tick
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
			var cue_ms: float = (display_tick - visual.previous_cue_started_tick) * _config.fixed_dt * 1000.0
			prepare_timeline_drawing(visual.drawing, foot, visual.previous_action, visual.previous_direction, previous_ms, visual.previous_cue_action, cue_ms, _config)
		else:
			_prepare_drawing(visual.drawing, visual.position, AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction, elapsed_ms)
		visual.drawing.tint.a = clampf((lifetime_ms - elapsed_ms) / 400.0, 0.0, 1.0)
		if visual.drawing.area.intersects(visible_world):
			_queue_drawing(visual.drawing)
			capture_visible_count += 1

## Inline reset adopts resized resources before observing the new epoch.
func bind_world(world: SimulationWorld) -> void:
	_resources = world.resources
	_config = world.config
	_ground.bind_resources(_resources, _config.world_size)

## Reliable capture records are independent of whichever state wins the mailbox.
var _reliable_captures: Array[SimulationNotice] = []

func queue_reliable_capture(event: CaptureEvent, pose: PublishedPose) -> void:
	var notice := SimulationNotice.new()
	notice.capture = event
	notice.pose = pose
	_reliable_captures.append(notice)

func reliable_captures(snapshot: SimulationPublication, at_tick: float) -> Array[CaptureVisual]:
	for index: int in range(_captures.size() - 1, -1, -1):
		var visual: CaptureVisual = _captures[index]
		var duration: float = _catalog.get_clip(AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction).duration_ms + 900.0
		if visual.handle.world_epoch != snapshot.epoch or (at_tick - visual.started_tick) * snapshot.config.fixed_dt * 1000.0 >= duration:
			_captures.remove_at(index)
	for index: int in range(_reliable_captures.size() - 1, -1, -1):
		var notice: SimulationNotice = _reliable_captures[index]
		var event: CaptureEvent = notice.capture
		if event.target.world_epoch > snapshot.epoch or (event.target.world_epoch == snapshot.epoch and event.tick > snapshot.tick):
			continue
		_reliable_captures.remove_at(index)
		if event.target.world_epoch != snapshot.epoch:
			continue
		var visual := CaptureVisual.new()
		visual.handle = event.target
		visual.position = event.position
		visual.previous_position = event.previous_position
		visual.direction = AnimationCatalog.direction_for(event.facing, 0)
		visual.started_tick = event.tick
		var pose: PublishedPose = notice.pose
		if pose != null:
			visual.previous_action = pose.action
			visual.previous_direction = pose.direction
			visual.previous_started_tick = pose.started_tick
			visual.previous_phase_ms = phase_for_seed(pose.handle, pose.action, pose.phase_direction, snapshot.scenario.random_seed)
			visual.previous_cue_action = pose.cue_action
			visual.previous_cue_started_tick = pose.cue_started_tick
		var lifetime_ms: float = _catalog.get_clip(AnimationCatalog.Action.SHEEP_CAPTURED, visual.direction).duration_ms + 900.0
		if (at_tick - visual.started_tick) * snapshot.config.fixed_dt * 1000.0 < lifetime_ms:
			_captures.append(visual)
	return _captures.duplicate()

func instance_animator() -> InstanceAnimator:
	if _instance_animator == null:
		_instance_animator = InstanceAnimator.new()
		_instance_animator.setup(self, _catalog)
	return _instance_animator

## Only this boundary replaces the front frame. Engine uploads cannot be preempted.
func commit_job(job: PresentationJob) -> void:
	var source: SimulationPublication = job.source
	if _epoch != source.epoch:
		_epoch = source.epoch
		selected_handle = null
		epoch_cleared.emit()
	_store = source.store
	_intents = source.intents
	_resources = source.resources
	_config = source.config
	_seed = source.scenario.random_seed
	_observed_tick = source.tick
	_states = job.states
	_draw_list = job.drawings
	display_tick = job.display_tick
	display_direct = job.direct
	visible_count = job.visible_count
	capture_visible_count = job.capture_count
	held_hidden_count = job.held_count
	_ground.commit_image(_resources, _config.world_size, job.image, job.levels)
	if _config.gpu_presentation:
		_instance_animator.set_enabled(true)
		_shadows.hide()
		_instance_animator.commit(_draw_list.size())
	else:
		if _instance_animator != null:
			_instance_animator.set_enabled(false)
		_shadows.show()
		_update_shadows()
	_update_selection(job.alpha, job.direct)
	queue_redraw()
