class_name GpuMotionKernel
extends RefCounted
## Synchronous numerical backend: CPU owns identities, field build and commit.
## The local device is used and destroyed on its creating thread. No SceneTree
## access occurs in a shader; no GPU result survives this fixed-step boundary.

const ACTOR_FLOATS: int = 20
const RESULT_FLOATS: int = 12
const BYTES_PER_FLOAT: int = 4
enum LifeState { DEAD, HELD, ACTIVE }
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
var _actors := PackedFloat32Array()
var _parameters := PackedFloat32Array()
var _intent_records := PackedVector4Array()
var _phase_flags := PackedVector4Array()
var _identity_directions := PackedVector2Array()
var _cached_life_revision: int = -1
var _cached_epoch: int = -1

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

func _ensure_capacity(count: int, cell_bytes: int) -> void:
	if count <= _capacity:
		return
	_release_buffers()
	_capacity = maxi(128, maxi(count, _capacity * 2))
	_actors.resize(_capacity * ACTOR_FLOATS)
	_buffers = [
		_device.storage_buffer_create(_capacity * ACTOR_FLOATS * BYTES_PER_FLOAT),
		_device.storage_buffer_create(cell_bytes),
		_device.storage_buffer_create(_capacity * RESULT_FLOATS * BYTES_PER_FLOAT),
		_device.storage_buffer_create(_capacity * ACTOR_FLOATS * BYTES_PER_FLOAT),
		_device.storage_buffer_create(cell_bytes),
	]
	var uniforms: Array[RDUniform] = []
	var pack_uniforms: Array[RDUniform] = []
	for binding: int in _buffers.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(_buffers[binding])
		if binding < 3:
			uniforms.append(uniform)
		if binding != 2:
			pack_uniforms.append(uniform)
	_uniform_set = _device.uniform_set_create(uniforms, _shader, 0)
	_pack_uniform_set = _device.uniform_set_create(pack_uniforms, _pack_shader, 0)

func run(store: AgentStore, intents: IntentBuffer, field: CrowdMotionField, config: SimulationConfig, tick: int, dt: float) -> void:
	# Float-encoded phase-local indices must remain exact. Full generations and
	# epoch stay on CPU; they are never truncated into the shader buffer.
	assert(store.capacity < 16777216)
	var revision: int = store.life_revision
	var started: int = Time.get_ticks_usec()
	_ensure_capacity(store.capacity, field.columns * field.rows * CrowdMotionField.GPU_CELL_FLOATS * BYTES_PER_FLOAT)
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
	])
	var parameter_bytes: PackedByteArray = _parameters.to_byte_array()
	pack_usec += Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	_device.buffer_update(_buffers[3 if _bulk_upload else 0], 0, actor_upload_size, actor_bytes)
	_device.buffer_update(_buffers[4 if _bulk_upload else 1], 0, cell_bytes.size(), cell_bytes)
	uploaded_bytes += actor_upload_size + cell_bytes.size()
	upload_usec += Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	_device.capture_timestamp("motion_begin")
	var compute_list: int = _device.compute_list_begin()
	if _bulk_upload:
		_device.compute_list_bind_compute_pipeline(compute_list, _pack_pipeline)
		_device.compute_list_bind_uniform_set(compute_list, _pack_uniform_set, 0)
		_device.compute_list_set_push_constant(compute_list, parameter_bytes, parameter_bytes.size())
		var pack_items: int = maxi(store.count, field.columns * field.rows)
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
	_intent_records.resize(store.capacity)
	_phase_flags.resize(store.capacity)
	field_agent_count = 0
	exact_agent_count = 0
	for dense: int in store.count:
		var life_state: LifeState = LifeState.DEAD
		if store.alive[dense] != 0:
			life_state = LifeState.HELD if store.held[dense] != 0 else LifeState.ACTIVE
		var intent: MotionIntent = intents.get_intent(store.handle_at(dense), tick) if life_state == LifeState.ACTIVE else null
		var use_field: bool = false
		if intent != null and intent.mode != SimTypes.IntentMode.STOP:
			use_field = field.uses_dense_sample(dense, config.neighbor_radius, config.crowd_enter_count, config.crowd_exit_count)
			field_agent_count += int(use_field)
			exact_agent_count += int(not use_field)
		if intent == null:
			_intent_records[dense] = Vector4(0.0, 0.0, 0.0, -1.0)
		else:
			_intent_records[dense] = Vector4(intent.destination.x, intent.destination.y, intent.speed, intent.mode)
		var retreat: bool = intent != null and intent.behavior == SimTypes.Behavior.RETREAT
		_phase_flags[dense] = Vector4(life_state, float(use_field), float(retreat), 0.0)
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
	return bytes

func _refresh_identity_directions(store: AgentStore) -> void:
	# Dense projection is valid only for this store's complete lifecycle revision.
	# Swap deletion, slot reuse, reset and held changes all invalidate it.
	if _cached_life_revision == store.life_revision and _cached_epoch == store.epoch:
		return
	_identity_directions.resize(store.capacity)
	for dense: int in store.count:
		_identity_directions[dense] = CrowdMotionField.identity_direction(store.handle_at(dense))
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
	_cached_life_revision = -1
	_cached_epoch = -1
