class_name PublishedPose
extends RefCounted
## Immutable visual clock for one complete life. No texture or scene resources.
var handle: AgentHandle
var species: int
var behavior: int
var action: int
var direction: int
var previous_direction: int
var direction_tick: int
var started_tick: int
var phase_direction: int

## Optional bounded diagnostic sample. Frozen after publication; timings include
## clock overhead and cover only sampled rows, never the entire pose pass.
class SampleProfile extends RefCounted:
	var rows: int = 0
	var changed: int = 0
	var lookup_usec: int = 0
	var quality_usec: int = 0
	var action_usec: int = 0
	var direction_usec: int = 0
	var pool_usec: int = 0
	var write_usec: int = 0
	var notices_buffer_usec: int = 0
	var total_usec: int = 0

	static func csv_columns() -> PackedStringArray:
		return PackedStringArray(["pose_sample_rows", "pose_sample_changed", "pose_sample_lookup_us", "pose_sample_quality_us", "pose_sample_action_us", "pose_sample_direction_us", "pose_sample_pool_us", "pose_sample_write_us", "pose_sample_notices_buffer_us", "pose_sample_total_us"])

	func csv_values() -> PackedStringArray:
		return PackedStringArray([str(rows), str(changed), str(lookup_usec), str(quality_usec), str(action_usec), str(direction_usec), str(pool_usec), str(write_usec), str(notices_buffer_usec), str(total_usec)])

## A bounded worker-only pool per slot. No manual ref/unref, and never overwrite
## a pose referenced by a cache, snapshot, notice, capture or another thread.
class History extends RefCounted:
	const RETAINED_VERSIONS: int = 8
	var versions: Array[PublishedPose] = []
	var allocations: int = 0
	var allocated_on_acquire: bool = false
	var sampled_facing: Vector2 = Vector2.ZERO

	func acquire() -> PublishedPose:
		allocated_on_acquire = false
		for index: int in versions.size():
			var candidate: PublishedPose = versions[index]
			# Exactly two owners: pool and this local. Array subscripting adds
			# a temporary reference, so test a named local, not versions[index].
			if candidate.get_reference_count() == 2:
				return candidate
		var pose := PublishedPose.new()
		allocations += 1
		allocated_on_acquire = true
		if versions.size() < RETAINED_VERSIONS:
			versions.append(pose)
		return pose

static func sample(handle: AgentHandle, species: int, intent: MotionIntent, moving: bool, facing: Vector2, tick: int, previous: PublishedPose, history: History, profile: SampleProfile = null) -> PublishedPose:
	var part_started: int = Time.get_ticks_usec() if profile != null else 0
	var behavior: int = intent.behavior if intent != null else SimTypes.Behavior.IDLE
	var pressure: bool = intent != null and intent.mode == SimTypes.IntentMode.PRESSURE
	var action: int = AnimationCatalog.action_for(species, behavior, moving, pressure)
	if profile != null:
		profile.action_usec += Time.get_ticks_usec() - part_started
		part_started = Time.get_ticks_usec()
	var continuing: bool = previous != null and previous.handle.same_life(handle)
	var direction: int = previous.direction if continuing else 0
	# An unchanged facing has already settled into the previous octant. Cache
	# the exact vector, not an approximate angle that could shift hysteresis.
	if not continuing or facing != history.sampled_facing:
		direction = AnimationCatalog.direction_for(facing, direction)
		history.sampled_facing = facing
	if profile != null:
		profile.direction_usec += Time.get_ticks_usec() - part_started
	if continuing and action == previous.action and direction == previous.direction and behavior == previous.behavior:
		return previous
	if profile != null:
		profile.changed += 1
		part_started = Time.get_ticks_usec()
	var pose: PublishedPose = history.acquire()
	if profile != null:
		profile.pool_usec += Time.get_ticks_usec() - part_started
		part_started = Time.get_ticks_usec()
	pose.handle = handle
	pose.species = species
	pose.behavior = behavior
	pose.action = action
	pose.direction = direction
	pose.direction_tick = tick
	if not continuing:
		pose.previous_direction = direction
		pose.phase_direction = direction
		pose.started_tick = maxi(0, tick - 1)
	else:
		pose.previous_direction = previous.direction
		pose.started_tick = previous.started_tick if action == previous.action else maxi(0, tick - 1)
		pose.phase_direction = previous.phase_direction if action == previous.action else previous.direction
		if direction == previous.direction:
			pose.previous_direction = previous.previous_direction
			pose.direction_tick = previous.direction_tick
	if profile != null:
		profile.write_usec += Time.get_ticks_usec() - part_started
	return pose
