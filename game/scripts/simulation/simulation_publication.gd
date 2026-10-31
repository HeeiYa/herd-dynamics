class_name SimulationPublication
extends RefCounted
## One immutable, complete publication. The bounded FIFO never overwrites a
## reader or discards intermediate capture/command/animation observations.
var sequence: int = 0
var published_usec: int = 0
var tick: int = 0
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
var tuning_values := PackedFloat64Array()
var tuning_applied_count: int = 0
var phase_usec := PackedInt64Array()
var max_perception_delay_ticks: int = 0
var max_decision_delay_ticks: int = 0
var grid_max_occupancy: int = 0
var grid_candidate_count: int = 0
var motion_backend_status: String = "initializing"
var planner_description: String = "正在生成"
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
var ai_used_usec: int = 0
var receipts: Array[SimulationCommand.Receipt] = []
var captures: Array[CaptureEvent] = []
var observer_events: Array[Dictionary] = []

static func capture(world: SimulationWorld, selected: AgentHandle) -> SimulationPublication:
	var started: int = Time.get_ticks_usec()
	var result := SimulationPublication.new()
	result.tick = world.tick
	result.store = world.store.publication_copy()
	result.intents = world.intents.publication_copy()
	result.config = world.config.duplicate() as SimulationConfig
	result.settings = world.ai.settings.duplicate() as AISettings
	result.scenario = world.scenario.duplicate(true) as ScenarioConfig
	result.resources = world.resources.publication_copy(result.config)
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
	for dense: int in world.store.count:
		if not world.store.is_active(world.store.handle_at(dense)):
			continue
		result.active_agents += 1
		if world.intents.get_intent(world.store.handle_at(dense), world.tick) == null:
			result.missing_intents += 1
	result.snapshot_usec = Time.get_ticks_usec() - started
	return result
