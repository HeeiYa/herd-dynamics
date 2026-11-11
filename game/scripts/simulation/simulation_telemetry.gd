class_name SimulationTelemetry
extends RefCounted
## Reliable per-publication counters and control status, with no world snapshot.
var sequence: int = 0
var epoch: int = 0
var completed_usec: int = 0
var published_usec: int = 0
var tick: int = 0
var tuning_values := PackedFloat64Array()
var tuning_applied_count: int = 0
var phase_usec := PackedInt64Array()
var max_perception_delay_ticks: int = 0
var max_decision_delay_ticks: int = 0
var missing_intents: int = 0
var active_agents: int = 0
var grass_consumed: float = 0.0
var perception_cells: int = 0
var motion_cells: int = 0
var paused: bool = false
var speed: float = 1.0
var backlog_seconds: float = 0.0
var step_usec: int = 0
var snapshot_usec: int = 0
var pose_usec: int = 0
var ai_used_usec: int = 0

var store_copy_usec: int = 0
var intent_copy_usec: int = 0
var resource_copy_usec: int = 0
var metadata_copy_usec: int = 0
var quality_usec: int = 0
var pose_changed: int = 0
var pose_allocations: int = 0
var pose_buffer_allocations: int = 0
var pose_profile: PublishedPose.SampleProfile

## Reliable delivery copies only telemetry fields, even when called on a
## SimulationPublication. Packed columns and the optional profile are already
## frozen by the producer and remain shared read-only with that publication.
func telemetry_copy() -> SimulationTelemetry:
	var result := SimulationTelemetry.new()
	result.sequence = sequence
	result.epoch = epoch
	result.tick = tick
	result.published_usec = published_usec
	result.completed_usec = completed_usec
	result.paused = paused
	result.speed = speed
	result.backlog_seconds = backlog_seconds
	result.step_usec = step_usec
	result.snapshot_usec = snapshot_usec
	result.pose_usec = pose_usec
	result.store_copy_usec = store_copy_usec
	result.intent_copy_usec = intent_copy_usec
	result.resource_copy_usec = resource_copy_usec
	result.metadata_copy_usec = metadata_copy_usec
	result.quality_usec = quality_usec
	result.pose_changed = pose_changed
	result.pose_allocations = pose_allocations
	result.pose_buffer_allocations = pose_buffer_allocations
	result.pose_profile = pose_profile
	result.ai_used_usec = ai_used_usec
	result.phase_usec = phase_usec
	result.active_agents = active_agents
	result.missing_intents = missing_intents
	result.max_perception_delay_ticks = max_perception_delay_ticks
	result.max_decision_delay_ticks = max_decision_delay_ticks
	result.grass_consumed = grass_consumed
	result.perception_cells = perception_cells
	result.motion_cells = motion_cells
	result.tuning_values = tuning_values
	result.tuning_applied_count = tuning_applied_count
	return result
