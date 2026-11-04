class_name GpuMotionKernel
extends RefCounted
## Synchronous numerical backend: CPU owns identities, field build and commit.
## The local device is used and destroyed on its creating thread. No SceneTree
## access occurs in a shader; no GPU result survives this fixed-step boundary.

const ACTOR_FLOATS: int = 20
const RESULT_FLOATS: int = 12
const BYTES_PER_FLOAT: int = 4
enum LifeState { DEAD, HELD, ACTIVE }
const NO_INTENT_RECORD := Vector4(0.0, 0.0, 0.0, -1.0)
enum ActorColumn {
	POSITION_X, POSITION_Y, VELOCITY_X, VELOCITY_Y,
	DESTINATION_X, DESTINATION_Y, SPEED, RADIUS,
	FACING_X, FACING_Y, FALLBACK_X, FALLBACK_Y,
	ALIVE, HELD, SPECIES, MODE,
	NEXT_NEIGHBOR, DENSE_SAMPLE, SLOT, RETREAT,
}
enum ResultColumn {
	POSITION_X, POSITION_Y, VELOCITY_X, VELOCITY_Y,
	FACING_X, FACING_Y, DISPLACEMENT, MOVING,
	CANDIDATES, NEIGHBORS, CONTRIBUTIONS, CELLS,
}

var field_agent_count: int = 0
var exact_agent_count: int = 0
var candidate_visits: int = 0
var neighbor_visits: int = 0
var contributions: int = 0
var cell_visits: int = 0
var moving_count: int = 0
var displacement_sum: float = 0.0
var steps: int = 0
var pack_usec: int = 0
# Both bulk counters are subsets of pack_usec, never additive to it.
var bulk_rows_usec: int = 0
var bulk_columns_usec: int = 0
var upload_usec: int = 0
var submit_wait_usec: int = 0
var readback_usec: int = 0
var commit_usec: int = 0
var gpu_elapsed_usec: float = 0.0
var gpu_timestamp_samples: int = 0
var timestamp_count_last: int = 0
var identity_cache_rebuilds: int = 0
var uploaded_bytes: int = 0
var _bulk_upload: bool = true

var _device: RenderingDevice
var _shader: RID
var _pipeline: RID
var _uniform_set: RID
var _pack_shader: RID
var _pack_pipeline: RID
var _pack_uniform_set: RID
var _buffers: Array[RID] = []
var _capacity: int = 0
var _cell_capacity_bytes: int = 0
var _lookup_capacity_bytes: int = 0
var _actors := PackedFloat32Array()
var _parameters := PackedFloat32Array()
var _intent_records := PackedVector4Array()
var _phase_flags := PackedVector4Array()
var _identity_directions := PackedVector2Array()
var _cached_store: AgentStore
var _cached_life_revision: int = -1
var _cached_epoch: int = -1
# Private dense projections are valid only under the bound store lifecycle.
# They never leave this kernel or retain a MotionIntent/publication reference.
var _input_handles: Array[AgentHandle] = []
var _input_life_states := PackedByteArray()
var _input_versions := PackedInt64Array()
var _input_expires_ticks := PackedInt64Array()
var _input_retreats := PackedByteArray()
var _cached_intents: IntentBuffer
var _last_input_tick: int = -1

func initialize() -> bool:
	_device = RenderingServer.create_local_rendering_device()
	if _device == null:
		return false
	var shader_file: RDShaderFile = load("res://scripts/simulation/gpu_motion.glsl") as RDShaderFile
	if shader_file == null:
		close()
		return false
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		close()
		return false
	_shader = _device.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		close()
		return false
	_pipeline = _device.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		close()
		return false
	var pack_file: RDShaderFile = load("res://scripts/simulation/gpu_motion_pack.glsl") as RDShaderFile
	if pack_file == null:
		close()
		return false
	var pack_spirv: RDShaderSPIRV = pack_file.get_spirv()
	if not pack_spirv.compile_error_compute.is_empty():
		push_error(pack_spirv.compile_error_compute)
		close()
		return false
	_pack_shader = _device.shader_create_from_spirv(pack_spirv)
	if not _pack_shader.is_valid():
		close()
		return false
	_pack_pipeline = _device.compute_pipeline_create(_pack_shader)
	if not _pack_pipeline.is_valid():
		close()
		return false
	return true

func _ensure_capacity(count: int, cell_bytes: int, lookup_bytes: int) -> void:
	# An all-held sparse world has no occupied cells but still dispatches actors.
	# Bound storage remains non-empty even when this step has nothing to upload.
	cell_bytes = maxi(48, cell_bytes)
	if count <= _capacity and cell_bytes <= _cell_capacity_bytes and lookup_bytes <= _lookup_capacity_bytes:
		return
	_release_buffers()
	if count > _capacity:
		_capacity = maxi(128, maxi(count, _capacity * 2))
	if cell_bytes > _cell_capacity_bytes:
		_cell_capacity_bytes = maxi(48, maxi(cell_bytes, _cell_capacity_bytes * 2))
	if lookup_bytes > _lookup_capacity_bytes:
		_lookup_capacity_bytes = maxi(16, maxi(lookup_bytes, _lookup_capacity_bytes * 2))
	_actors.resize(_capacity * ACTOR_FLOATS)
	_buffers = [
		_device.storage_buffer_create(_capacity * ACTOR_FLOATS * BYTES_PER_FLOAT),
		_device.storage_buffer_create(_cell_capacity_bytes),
		_device.storage_buffer_create(_capacity * RESULT_FLOATS * BYTES_PER_FLOAT),
		_device.storage_buffer_create(_capacity * ACTOR_FLOATS * BYTES_PER_FLOAT),
		_device.storage_buffer_create(_cell_capacity_bytes),
		_device.storage_buffer_create(_lookup_capacity_bytes),
	]
	var uniforms: Array[RDUniform] = []
	var pack_uniforms: Array[RDUniform] = []
	for binding: int in _buffers.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(_buffers[binding])
		if binding < 3 or binding == 5:
			uniforms.append(uniform)
		if binding in [0, 1, 3, 4]:
			pack_uniforms.append(uniform)
	_uniform_set = _device.uniform_set_create(uniforms, _shader, 0)
	_pack_uniform_set = _device.uniform_set_create(pack_uniforms, _pack_shader, 0)

func run(store: AgentStore, intents: IntentBuffer, field: CrowdMotionField, config: SimulationConfig, tick: int, dt: float) -> void:
	# Float-encoded phase-local indices must remain exact. Full generations and
	# epoch stay on CPU; they are never truncated into the shader buffer.
	assert(store.capacity < 16777216)
	var revision: int = store.life_revision
	var started: int = Time.get_ticks_usec()
	var lookup: PackedInt32Array = field.cell_map.gpu_lookup()
	var lookup_bytes: PackedByteArray = lookup.to_byte_array()
	var cell_count: int = field.cell_map.storage_count
	_ensure_capacity(store.capacity, cell_count * CrowdMotionField.GPU_CELL_FLOATS * BYTES_PER_FLOAT, lookup_bytes.size())
	_bulk_upload = config.gpu_bulk_upload
	var actor_bytes: PackedByteArray
	var cell_bytes: PackedByteArray
	var actor_upload_size: int
	if _bulk_upload:
		actor_bytes = _pack_bulk(store, intents, field, config, tick)
		cell_bytes = field.gpu_cell_bytes_bulk()
		actor_upload_size = actor_bytes.size()
	else:
		_pack_actors(store, intents, field, config, tick)
		actor_bytes = _actors.to_byte_array()
		cell_bytes = field.gpu_cell_snapshot().to_byte_array()
		actor_upload_size = store.count * ACTOR_FLOATS * BYTES_PER_FLOAT
	_parameters = PackedFloat32Array([
		config.world_size.x, config.world_size.y, dt, store.count,
		field.columns, field.rows, field.cell_size, config.neighbor_radius,
		config.acceleration, config.arrival_radius, config.separation_strength, config.facing_min_speed,
		config.alignment_weight, config.cohesion_weight, float(_bulk_upload), store.capacity,
		cell_count, field.cell_map.block_columns, float(field.cell_map.sparse), lookup.size() / 2 - 1,
	])
	var parameter_bytes: PackedByteArray = _parameters.to_byte_array()
	pack_usec += Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	_device.buffer_update(_buffers[3 if _bulk_upload else 0], 0, actor_upload_size, actor_bytes)
	if not cell_bytes.is_empty():
		_device.buffer_update(_buffers[4 if _bulk_upload else 1], 0, cell_bytes.size(), cell_bytes)
	_device.buffer_update(_buffers[5], 0, lookup_bytes.size(), lookup_bytes)
	uploaded_bytes += actor_upload_size + cell_bytes.size() + lookup_bytes.size()
	upload_usec += Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	_device.capture_timestamp("motion_begin")
	var compute_list: int = _device.compute_list_begin()
	if _bulk_upload:
		_device.compute_list_bind_compute_pipeline(compute_list, _pack_pipeline)
		_device.compute_list_bind_uniform_set(compute_list, _pack_uniform_set, 0)
		_device.compute_list_set_push_constant(compute_list, parameter_bytes, parameter_bytes.size())
		var pack_items: int = maxi(store.count, cell_count)
		_device.compute_list_dispatch(compute_list, ceili(float(pack_items) / 64.0), 1, 1)
		_device.compute_list_add_barrier(compute_list)
	_device.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _uniform_set, 0)
	_device.compute_list_set_push_constant(compute_list, parameter_bytes, parameter_bytes.size())
	_device.compute_list_dispatch(compute_list, ceili(float(store.count) / 64.0), 1, 1)
	_device.compute_list_end()
	_device.capture_timestamp("motion_end")
	_device.submit()
	_device.sync()
	submit_wait_usec += Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var result: PackedFloat32Array = _device.buffer_get_data(_buffers[2], 0, store.count * RESULT_FLOATS * BYTES_PER_FLOAT).to_float32_array()
	readback_usec += Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	assert(revision == store.life_revision, "Lifecycle changed during synchronous GPU motion")
	_commit(store, result)
	commit_usec += Time.get_ticks_usec() - started
	timestamp_count_last = _device.get_captured_timestamps_count()
	var begin_nanoseconds: int = -1
	var end_nanoseconds: int = -1
	for index: int in timestamp_count_last:
		var label: String = _device.get_captured_timestamp_name(index)
		if label == "motion_begin":
			begin_nanoseconds = _device.get_captured_timestamp_gpu_time(index)
		elif label == "motion_end":
			end_nanoseconds = _device.get_captured_timestamp_gpu_time(index)
	if begin_nanoseconds >= 0 and end_nanoseconds >= 0:
		var elapsed_nanoseconds: int = end_nanoseconds - begin_nanoseconds
		if elapsed_nanoseconds > 0:
			gpu_elapsed_usec += float(elapsed_nanoseconds) / 1000.0
			gpu_timestamp_samples += 1
	steps += 1

## Capacity-sized columns preserve AgentStore's native packed representation.
## Only intents and phase decisions need a GDScript row loop. These copies are
## synchronous snapshots, not aliases or a second authoritative world state.
func _pack_bulk(store: AgentStore, intents: IntentBuffer, field: CrowdMotionField, config: SimulationConfig, tick: int) -> PackedByteArray:
	_refresh_identity_directions(store)
	var rows_started: int = Time.get_ticks_usec()
	if _cached_intents != intents or tick < _last_input_tick:
		# Live world time is monotonic within an epoch. Explicit rewind also
		# invalidates null-at-expiry entries for fixed-input diagnostic replays.
		_input_versions.fill(-1)
		_cached_intents = intents
	_last_input_tick = tick
	# The owner's version column is borrowed only for this fixed phase; the
	# cache stores scalar stamps, never the returned shared Packed array.
	var versions: PackedInt64Array = intents.mutation_versions_for_slots(store.capacity)
	_phase_flags.resize(store.capacity)
	field_agent_count = 0
	exact_agent_count = 0
	for dense: int in store.count:
		var life_state: LifeState = _input_life_states[dense] as LifeState
		if life_state == LifeState.ACTIVE:
			var version: int = versions[store.dense_to_slot[dense]]
			if _input_versions[dense] != version:
				_project_changed_intent(dense, intents, tick, version)
			elif tick >= _input_expires_ticks[dense] and _intent_records[dense].w >= 0.0:
				# Expiry does not require a write to the intent buffer. Clear the
				# submitted record once; the raw intent remains owned by its buffer.
				_intent_records[dense] = NO_INTENT_RECORD
				_input_retreats[dense] = 0
		var mode: int = int(_intent_records[dense].w)
		var use_field: bool = false
		if life_state == LifeState.ACTIVE and mode >= 0 and mode != SimTypes.IntentMode.STOP:
			use_field = field.uses_dense_sample(dense, config.neighbor_radius, config.crowd_enter_count, config.crowd_exit_count)
			field_agent_count += int(use_field)
			exact_agent_count += int(not use_field)
		_phase_flags[dense] = Vector4(life_state, float(use_field), float(_input_retreats[dense]), 0.0)
	bulk_rows_usec += Time.get_ticks_usec() - rows_started
	var columns_started: int = Time.get_ticks_usec()
	# Word offsets (C = store.capacity) match gpu_motion_pack.glsl/pack_actor:
	# position 0C, velocity 2C, facing 4C, radius 6C, species 7C, slot 8C,
	# next 9C, identity direction 10C, intent 12C, phase flags 16C.
	var bytes: PackedByteArray = store.position_current.to_byte_array()
	bytes.append_array(store.velocity_current.to_byte_array())
	bytes.append_array(store.facing.to_byte_array())
	bytes.append_array(store.radius.to_byte_array())
	bytes.append_array(store.species.to_byte_array())
	bytes.append_array(store.dense_to_slot.to_byte_array())
	bytes.append_array(field.gpu_next_links_bytes())
	bytes.append_array(_identity_directions.to_byte_array())
	bytes.append_array(_intent_records.to_byte_array())
	bytes.append_array(_phase_flags.to_byte_array())
	assert(bytes.size() == store.capacity * ACTOR_FLOATS * BYTES_PER_FLOAT)
	bulk_columns_usec += Time.get_ticks_usec() - columns_started
	return bytes

func _project_changed_intent(dense: int, intents: IntentBuffer, tick: int, version: int) -> void:
	# Refreshes always pass the existing complete identity and TTL lookup.
	# The canonical handle belongs to this exact store/lifecycle projection.
	var intent: MotionIntent = intents.get_intent(_input_handles[dense], tick)
	if intent == null:
		_intent_records[dense] = NO_INTENT_RECORD
		_input_expires_ticks[dense] = -1
		_input_retreats[dense] = 0
	else:
		_intent_records[dense] = Vector4(intent.destination.x, intent.destination.y, intent.speed, intent.mode)
		_input_expires_ticks[dense] = intent.expires_tick
		_input_retreats[dense] = int(intent.behavior == SimTypes.Behavior.RETREAT)
	_input_versions[dense] = version

func _refresh_identity_directions(store: AgentStore) -> void:
	# Dense projection is valid only for this store's complete lifecycle revision.
	# Swap deletion, slot reuse, reset and held changes all invalidate it.
	if _cached_store == store and _cached_life_revision == store.life_revision and _cached_epoch == store.epoch:
		return
	_identity_directions.resize(store.capacity)
	_input_handles.resize(store.count)
	_input_life_states.resize(store.capacity)
	_input_versions.resize(store.capacity)
	_input_expires_ticks.resize(store.capacity)
	_input_retreats.resize(store.capacity)
	_intent_records.resize(store.capacity)
	_input_versions.fill(-1)
	for dense: int in store.count:
		var handle: AgentHandle = store.handle_at(dense)
		_input_handles[dense] = handle
		_identity_directions[dense] = CrowdMotionField.identity_direction(handle)
		var life_state: LifeState = LifeState.DEAD
		if store.alive[dense] != 0:
			life_state = LifeState.HELD if store.held[dense] != 0 else LifeState.ACTIVE
		_input_life_states[dense] = life_state
		_intent_records[dense] = NO_INTENT_RECORD
		_input_expires_ticks[dense] = -1
		_input_retreats[dense] = 0
	_cached_store = store
	_cached_life_revision = store.life_revision
	_cached_epoch = store.epoch
	identity_cache_rebuilds += 1

func _pack_actors(store: AgentStore, intents: IntentBuffer, field: CrowdMotionField, config: SimulationConfig, tick: int) -> void:
	field_agent_count = 0
	exact_agent_count = 0
	for dense: int in store.count:
		var base: int = dense * ACTOR_FLOATS
		var handle: AgentHandle = store.handle_at(dense)
		var active: bool = store.alive[dense] != 0 and store.held[dense] == 0
		var intent: MotionIntent = intents.get_intent(handle, tick) if active else null
		var use_field: bool = false
		if intent != null and intent.mode != SimTypes.IntentMode.STOP:
			use_field = field.uses_dense_sample(dense, config.neighbor_radius, config.crowd_enter_count, config.crowd_exit_count)
			field_agent_count += int(use_field)
			exact_agent_count += int(not use_field)
		var fallback: Vector2 = field.gpu_overlap_direction(dense, config.world_size) if use_field else Vector2.ZERO
		_actors[base + ActorColumn.POSITION_X] = store.position_current[dense].x
		_actors[base + ActorColumn.POSITION_Y] = store.position_current[dense].y
		_actors[base + ActorColumn.VELOCITY_X] = store.velocity_current[dense].x
		_actors[base + ActorColumn.VELOCITY_Y] = store.velocity_current[dense].y
		_actors[base + ActorColumn.DESTINATION_X] = intent.destination.x if intent != null else 0.0
		_actors[base + ActorColumn.DESTINATION_Y] = intent.destination.y if intent != null else 0.0
		_actors[base + ActorColumn.SPEED] = intent.speed if intent != null else 0.0
		_actors[base + ActorColumn.RADIUS] = store.radius[dense]
		_actors[base + ActorColumn.FACING_X] = store.facing[dense].x
		_actors[base + ActorColumn.FACING_Y] = store.facing[dense].y
		_actors[base + ActorColumn.FALLBACK_X] = fallback.x
		_actors[base + ActorColumn.FALLBACK_Y] = fallback.y
		_actors[base + ActorColumn.ALIVE] = store.alive[dense]
		_actors[base + ActorColumn.HELD] = store.held[dense]
		_actors[base + ActorColumn.SPECIES] = store.species[dense]
		_actors[base + ActorColumn.MODE] = intent.mode if intent != null else -1
		_actors[base + ActorColumn.NEXT_NEIGHBOR] = field.gpu_next_neighbor(dense) if active else -1
		_actors[base + ActorColumn.DENSE_SAMPLE] = float(use_field)
		_actors[base + ActorColumn.SLOT] = handle.slot
		_actors[base + ActorColumn.RETREAT] = float(intent != null and intent.behavior == SimTypes.Behavior.RETREAT)

func _commit(store: AgentStore, result: PackedFloat32Array) -> void:
	candidate_visits = 0
	neighbor_visits = 0
	contributions = 0
	cell_visits = 0
	moving_count = 0
	displacement_sum = 0.0
	for dense: int in store.count:
		if store.alive[dense] == 0:
			continue
		var base: int = dense * RESULT_FLOATS
		store.position_next[dense] = Vector2(result[base + ResultColumn.POSITION_X], result[base + ResultColumn.POSITION_Y])
		store.velocity_next[dense] = Vector2(result[base + ResultColumn.VELOCITY_X], result[base + ResultColumn.VELOCITY_Y])
		store.facing[dense] = Vector2(result[base + ResultColumn.FACING_X], result[base + ResultColumn.FACING_Y])
		displacement_sum += result[base + ResultColumn.DISPLACEMENT]
		moving_count += int(result[base + ResultColumn.MOVING])
		candidate_visits += int(result[base + ResultColumn.CANDIDATES])
		neighbor_visits += int(result[base + ResultColumn.NEIGHBORS])
		contributions += int(result[base + ResultColumn.CONTRIBUTIONS])
		cell_visits += int(result[base + ResultColumn.CELLS])

func reset_metrics() -> void:
	steps = 0
	pack_usec = 0
	bulk_rows_usec = 0
	bulk_columns_usec = 0
	upload_usec = 0
	submit_wait_usec = 0
	readback_usec = 0
	commit_usec = 0
	gpu_elapsed_usec = 0.0
	gpu_timestamp_samples = 0
	identity_cache_rebuilds = 0
	uploaded_bytes = 0

func metrics() -> Dictionary:
	return {"steps": steps, "pack_us": pack_usec, "upload_us": upload_usec,
		"bulk_rows_us": bulk_rows_usec, "bulk_columns_us": bulk_columns_usec,
		"submit_wait_us": submit_wait_usec, "readback_us": readback_usec, "commit_us": commit_usec,
		"gpu_timestamp_us": gpu_elapsed_usec if gpu_timestamp_samples > 0 else null, "gpu_timestamp_samples": gpu_timestamp_samples,
		"timestamp_count_last": timestamp_count_last,
		"input_transport": "bulk_columns" if _bulk_upload else "scalar_records",
		"identity_cache_rebuilds": identity_cache_rebuilds, "uploaded_bytes": uploaded_bytes,
		"scope": "Window totals; GPU timestamp is nested in submit/wait, excludes packing and host transfers."}

func _release_buffers() -> void:
	if _pack_uniform_set.is_valid():
		_device.free_rid(_pack_uniform_set)
		_pack_uniform_set = RID()
	if _uniform_set.is_valid():
		_device.free_rid(_uniform_set)
		_uniform_set = RID()
	for buffer: RID in _buffers:
		_device.free_rid(buffer)
	_buffers.clear()

func close() -> void:
	_cached_store = null
	_cached_life_revision = -1
	_cached_epoch = -1
	_cached_intents = null
	_last_input_tick = -1
	_input_handles.clear()
	_input_life_states.clear()
	_input_versions.clear()
	_input_expires_ticks.clear()
	_input_retreats.clear()
	_intent_records.clear()
	if _device == null:
		return
	_release_buffers()
	if _pack_pipeline.is_valid():
		_device.free_rid(_pack_pipeline)
	if _pack_shader.is_valid():
		_device.free_rid(_pack_shader)
	_pack_pipeline = RID()
	_pack_shader = RID()
	if _pipeline.is_valid():
		_device.free_rid(_pipeline)
	if _shader.is_valid():
		_device.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()
	_device.free()
	_device = null
	_capacity = 0
	_cell_capacity_bytes = 0
	_lookup_capacity_bytes = 0
