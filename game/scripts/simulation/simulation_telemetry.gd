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
