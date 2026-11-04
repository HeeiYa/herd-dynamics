class_name SimulationPublication
extends SimulationTelemetry
## Immutable display state. The mailbox may replace an unread version; facts
## and receipts travel separately through SimulationDelivery.
var previous_completed_usec: int = 0
var pose_buffer: PoseBuffer

var store: AgentStore
var intents: IntentBuffer
var resources: ResourceGrid
var config: SimulationConfig
var settings: AISettings
var scenario: ScenarioConfig
var inspection: AgentInspection
var counts := PackedInt32Array([0, 0, 0])
var held_counts := PackedInt32Array([0, 0, 0])
var capture_count: int = 0
var grid_max_occupancy: int = 0
var grid_candidate_count: int = 0
var motion_backend_status: String = "initializing"
var planner_description: String = "正在生成"

func pose_at(dense: int) -> PublishedPose:
	return pose_buffer.at(dense)

static func capture(world: SimulationWorld, selected: AgentHandle) -> SimulationPublication:
	var started: int = Time.get_ticks_usec()
	var result := SimulationPublication.new()
	result.tick = world.tick
	result.epoch = world.store.epoch
	var part_started: int = Time.get_ticks_usec()
	result.store = world.store.publication_copy()
	result.store_copy_usec = Time.get_ticks_usec() - part_started
	part_started = Time.get_ticks_usec()
	result.intents = world.intents.publication_copy()
	result.intent_copy_usec = Time.get_ticks_usec() - part_started
	result.config = world.config.duplicate() as SimulationConfig
	result.settings = world.ai.settings.duplicate() as AISettings
	result.scenario = world.scenario.duplicate(true) as ScenarioConfig
	part_started = Time.get_ticks_usec()
	result.resources = world.resources.publication_copy(result.config)
	result.resource_copy_usec = Time.get_ticks_usec() - part_started
	result.inspection = AgentInspection.capture(world, selected)
	result.counts = world.counts()
	result.held_counts = world.held_counts()
	result.capture_count = world.capture_count
	for parameter: TuningCatalog.Parameter in world.tuning.parameters:
		result.tuning_values.append(parameter.value)
	result.tuning_applied_count = world.tuning.applied_count
	result.phase_usec = world.phase_usec.duplicate()
	result.max_perception_delay_ticks = world.ai.max_perception_delay_ticks
	result.max_decision_delay_ticks = world.ai.max_decision_delay_ticks
	result.grid_max_occupancy = world.grid.max_occupancy
	result.grid_candidate_count = world.grid.candidate_count
	result.motion_backend_status = world.motion.backend_status
	result.planner_description = world.spawn_planner.describe() if world.spawn_planner != null else "V1 固定算法"
	result.grass_consumed = world.interaction.grass_consumed
	result.perception_cells = world.grid.cell_map.storage_count
	result.motion_cells = world.motion._crowd_field.cell_map.storage_count
	result.ai_used_usec = world.ai.frame_used_usec
	result.snapshot_usec = Time.get_ticks_usec() - started
	result.metadata_copy_usec = result.snapshot_usec - result.store_copy_usec - result.intent_copy_usec - result.resource_copy_usec - result.quality_usec
	return result

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
