class_name ThreatCohortBenchmark
extends RefCounted
## A sudden, central threat exercises the whole cohort. Measurements never select
## strategy or remove background agents; capture remains a competing outcome.
class ResponseRecord extends RefCounted:
	var handle: AgentHandle
	var stimulus_position: Vector2
	var stimulus_velocity: Vector2
	var stimulus_hunger: float
	var stimulus_task: StringName
	var geometric_tick: int = -1
	var exposure_steps: int = 0
	var known_tick: int = -1
	var known_source: String = "NONE"
	var direct_tick: int = -1
	var response_tick: int = -1
	var death_tick: int = -1
	var alive_at_end: bool = true

	func response_class() -> String:
		if response_tick >= 0:
			if geometric_tick >= 0 and response_tick >= geometric_tick:
				return "response_after_exposure"
			return "response_before_exposure"
		if geometric_tick >= 0:
			return "exposed_no_response"
		return "unexposed_no_response"

const RESPONSE_COLUMNS: Array[String] = [
	"slot", "generation", "epoch", "stimulus_x", "stimulus_y", "stimulus_vx", "stimulus_vy", "stimulus_hunger", "stimulus_task",
	"geometric_visible_tick", "exposure_steps", "first_known_tick", "first_known_step_end_source", "first_direct_tick", "first_valid_flee_tick",
	"death_tick", "alive_at_end", "response_class", "exposed_response_latency_ticks", "response_before_direct_discovery", "censored"
]
const QUALITY_COLUMNS: Array[String] = [
	"published_tick", "alive", "missing_or_expired_intent_count", "never_perceived_count",
	"perception_age_mean_ticks", "perception_age_max_ticks", "decision_age_mean_ticks", "decision_age_max_ticks",
	"actually_moved_count", "actual_displacement_pixels", "shared_hits", "shared_builds"
]
const FIXTURE_HALF_WIDTH: float = 40.0
const WARMUP_BUDGET_USEC: int = 100000

var _world: SimulationWorld
var _wolf: AgentHandle
var _records: Array[ResponseRecord] = []
var _record_by_slot: Dictionary[int, ResponseRecord] = {}
var _stimulus_tick: int = 0
var _quality_rows: Array[PackedStringArray] = []

func run(host: Node, options: Dictionary[String, String]) -> int:
	var sheep_count: int = int(options.get("sheep", "240"))
	var warmup_ticks: int = int(options.get("warmup", "240"))
	var sample_ticks: int = int(options.get("samples", "600"))
	var budget_usec: int = int(options.get("ai-budget-usec", "2000"))
	if sheep_count < 1 or warmup_ticks < 0 or sample_ticks < 1 or budget_usec < 1:
		push_error("Cohort benchmark requires positive sheep, samples and budget, and nonnegative warmup.")
		return 1
	_records.clear()
	_record_by_slot.clear()
	_quality_rows.clear()
	_wolf = null
	_stimulus_tick = 0
	var scenario := ScenarioConfig.new()
	scenario.random_seed = int(options.get("seed", "42"))
	scenario.sheep_count = 0
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var config := SimulationConfig.new()
	config.instrument_enabled = options.get("instrument", "1") == "1"
	config.compact_flock_knowledge = options.get("compact-flock", "1") == "1"
	config.shared_cell_candidates = options.get("shared-candidates", str(int(config.shared_cell_candidates))) == "1"
	config.crowd_motion_enabled = options.get("crowd-field", str(int(config.crowd_motion_enabled))) == "1"
	config.ai_budget_usec = WARMUP_BUDGET_USEC
	_world = SimulationWorld.new()
	host.get_tree().root.add_child(_world)
	_world.setup(config, scenario)
	_create_fixture(sheep_count, scenario.random_seed)
	await host.get_tree().process_frame
	for step: int in warmup_ticks:
		_world.ai.begin_frame()
		_world.step()
	var warmup_tasks: Dictionary[String, int] = _capture_stimulus_state()
	if not _is_calm_fixture():
		push_error("Cohort stimulus requires all created sheep alive, with no pre-existing flee state.")
		_world.queue_free()
		await host.get_tree().process_frame
		return 1
	_stimulus_tick = _world.tick
	config.ai_budget_usec = budget_usec
	var stimulus_position: Vector2 = _cohort_center()
	_wolf = _world.create_at(SimTypes.Species.WOLF, stimulus_position)
	var wolf_context: AgentContext = _world.ai.contexts[_wolf.slot]
	wolf_context.wander_destination = stimulus_position
	wolf_context.wander_until = _stimulus_tick + sample_ticks
	_world.captured.connect(_observe_capture)
	_world.probes.reset_window()
	var initial_counts: Array = Array(_world.counts())
	var started_usec: int = Time.get_ticks_usec()
	for sample: int in sample_ticks:
		var at_tick: int = _world.tick
		_observe_geometry(at_tick)
		_world.ai.begin_frame()
		_world.step()
		_observe_outcomes(at_tick)
		_quality_rows.append(_observe_quality())
	var elapsed_seconds: float = float(Time.get_ticks_usec() - started_usec) / 1000000.0
	var summary: Dictionary = _build_summary(scenario.random_seed, warmup_ticks, sample_ticks, initial_counts, warmup_tasks, stimulus_position, elapsed_seconds)
	var output: String = options.get("output", "user://threat-cohort")
	var saved: bool = _save_results(output, summary)
	_world.queue_free()
	await host.get_tree().process_frame
	return 0 if saved else 1

func _create_fixture(sheep_count: int, random_seed: int) -> void:
	var fixture_random := RandomNumberGenerator.new()
	fixture_random.seed = random_seed
	var center: Vector2 = _world.config.world_size * Vector2(0.4375, 0.5)
	for index: int in sheep_count:
		var offset := Vector2(fixture_random.randf_range(-FIXTURE_HALF_WIDTH, FIXTURE_HALF_WIDTH), fixture_random.randf_range(-FIXTURE_HALF_WIDTH, FIXTURE_HALF_WIDTH))
		var record := ResponseRecord.new()
		record.handle = _world.create_at(SimTypes.Species.SHEEP, center + offset)
		_world.store.hunger[_world.store.resolve(record.handle)] = 0.9
		_records.append(record)
		_record_by_slot[record.handle.slot] = record

func _capture_stimulus_state() -> Dictionary[String, int]:
	var tasks: Dictionary[String, int] = {}
	for record: ResponseRecord in _records:
		var dense: int = _world.store.resolve(record.handle)
		var context: AgentContext = _world.ai.contexts.get(record.handle.slot)
		if dense < 0 or context == null or not context.handle.same_life(record.handle):
			continue
		record.stimulus_position = _world.store.position_current[dense]
		record.stimulus_velocity = _world.store.velocity_current[dense]
		record.stimulus_hunger = _world.store.hunger[dense]
		record.stimulus_task = context.task_name
		var task: String = String(record.stimulus_task)
		tasks[task] = tasks.get(task, 0) + 1
	return tasks

func _is_calm_fixture() -> bool:
	for record: ResponseRecord in _records:
		if not _world.store.is_alive(record.handle):
			return false
		var intent: MotionIntent = _world.intents.get_intent(record.handle, _world.tick)
		if record.stimulus_task == &"flee_threat":
			return false
		if intent != null and intent.behavior == SimTypes.Behavior.FLEE:
			return false
	return true

func _cohort_center() -> Vector2:
	var position_sum := Vector2.ZERO
	for record: ResponseRecord in _records:
		position_sum += record.stimulus_position
	return position_sum / float(_records.size())

func _observe_geometry(at_tick: int) -> void:
	var wolf_dense: int = _world.store.resolve(_wolf)
	if wolf_dense < 0:
		return
	var wolf_position: Vector2 = _world.store.position_current[wolf_dense]
	var radius_squared: float = _world.config.perception_radius * _world.config.perception_radius
	for record: ResponseRecord in _records:
		var dense: int = _world.store.resolve(record.handle)
		if dense < 0:
			continue
		if _world.store.position_current[dense].distance_squared_to(wolf_position) <= radius_squared:
			record.exposure_steps += 1
			if record.geometric_tick < 0:
				record.geometric_tick = at_tick

func _observe_outcomes(at_tick: int) -> void:
	for record: ResponseRecord in _records:
		record.alive_at_end = _world.store.is_alive(record.handle)
		if not record.alive_at_end:
			if record.death_tick < 0:
				record.death_tick = at_tick + 1
			continue
		_observe_knowledge_and_response(record, at_tick)

func _observe_knowledge_and_response(record: ResponseRecord, at_tick: int) -> void:
	var context: AgentContext = _world.ai.contexts.get(record.handle.slot)
	if context == null or not context.handle.same_life(record.handle):
		return
	var observation: LocalObservation = context.observations.get(_wolf.slot)
	if observation != null and observation.handle.same_life(_wolf):
		if record.direct_tick < 0 and observation.last_direct_tick >= _stimulus_tick:
			record.direct_tick = observation.last_direct_tick
		if record.known_tick < 0 and at_tick < observation.expires_tick:
			record.known_tick = at_tick
			record.known_source = "DIRECT" if observation.source == LocalObservation.Source.DIRECT else "SHARED"
	if record.response_tick >= 0:
		return
	var intent: MotionIntent = _world.intents.get_intent(record.handle, at_tick)
	if intent == null or intent.owner_token != context.task_token:
		return
	if intent.behavior == SimTypes.Behavior.FLEE and intent.mode == SimTypes.IntentMode.FLEE:
		record.response_tick = at_tick

func _observe_capture(event: CaptureEvent) -> void:
	var record: ResponseRecord = _record_by_slot.get(event.target.slot)
	if record == null or not record.handle.same_life(event.target):
		return
	# This signal occurs before lifecycle cleanup. Preserve a response issued on
	# the same step as capture; querying only after the step would lose its intent.
	_observe_knowledge_and_response(record, _world.tick)
	record.death_tick = event.tick
	record.alive_at_end = false

func _observe_quality() -> PackedStringArray:
	# Ages refer to the just-published state. All live species, including the wolf,
	# are counted. Missing intent includes never-issued and expired intent alike.
	var published_tick: int = _world.tick
	var alive: int = 0
	var missing_intents: int = 0
	var never_perceived: int = 0
	var perception_age_sum: int = 0
	var perception_age_max: int = -1
	var decision_age_sum: int = 0
	var decision_age_max: int = -1
	var actually_moved: int = 0
	var displacement: float = 0.0
	for dense: int in _world.store.count:
		var handle: AgentHandle = _world.store.handle_at(dense)
		var context: AgentContext = _world.ai.contexts.get(handle.slot)
		if context == null or not context.handle.same_life(handle) or not _world.store.is_alive(handle):
			continue
		alive += 1
		var distance: float = _world.store.position_current[dense].distance_to(_world.store.position_previous[dense])
		displacement += distance
		if distance > 0.01:
			actually_moved += 1
		if _world.intents.get_intent(handle, published_tick) == null:
			missing_intents += 1
		if context.last_perception_tick < 0:
			never_perceived += 1
		else:
			var perception_age: int = published_tick - context.last_perception_tick
			perception_age_sum += perception_age
			perception_age_max = maxi(perception_age_max, perception_age)
		var decision_age: int = published_tick - context.last_decision_tick
		decision_age_sum += decision_age
		decision_age_max = maxi(decision_age_max, decision_age)
	var perceived_count: int = alive - never_perceived
	var perception_age_mean: float = float(perception_age_sum) / perceived_count if perceived_count > 0 else -1.0
	var decision_age_mean: float = float(decision_age_sum) / alive if alive > 0 else -1.0
	return PackedStringArray([
		str(published_tick), str(alive), str(missing_intents), str(never_perceived),
		str(perception_age_mean), str(perception_age_max), str(decision_age_mean), str(decision_age_max),
		str(actually_moved), str(displacement), str(_world.grid.shared_hits), str(_world.grid.shared_builds)
	])

func _build_summary(seed_value: int, warmup_ticks: int, sample_ticks: int, initial_counts: Array, warmup_tasks: Dictionary[String, int], stimulus_position: Vector2, elapsed_seconds: float) -> Dictionary:
	var outcomes: Dictionary[String, int] = {
		"response_after_exposure": 0, "response_before_exposure": 0,
		"exposed_no_response": 0, "unexposed_no_response": 0,
		"never_geometrically_exposed": 0, "never_directly_discovered": 0, "never_knew_threat": 0,
		"exposed_unresponded_alive": 0, "exposed_died_without_response": 0,
		"dead_with_response": 0, "dead_without_response": 0, "response_before_direct_discovery": 0
	}
	for record: ResponseRecord in _records:
		outcomes[record.response_class()] += 1
		if record.geometric_tick < 0:
			outcomes["never_geometrically_exposed"] += 1
		if record.direct_tick < 0:
			outcomes["never_directly_discovered"] += 1
		if record.known_tick < 0:
			outcomes["never_knew_threat"] += 1
		if _responded_before_direct_discovery(record):
			outcomes["response_before_direct_discovery"] += 1
		if not record.alive_at_end:
			outcomes["dead_with_response" if record.response_tick >= 0 else "dead_without_response"] += 1
		if record.geometric_tick >= 0 and record.response_tick < 0:
			outcomes["exposed_unresponded_alive" if record.alive_at_end else "exposed_died_without_response"] += 1
	return {
		"mode": "headless whole-cohort sudden threat; not rendered FPS",
		"compact_flock_knowledge": _world.config.compact_flock_knowledge,
		"shared_cell_candidates": _world.config.shared_cell_candidates,
		"crowd_motion_enabled": _world.config.crowd_motion_enabled,
		"retained_observations_by_species": Array(_world.ai.knowledge_observation_counts()),
		"engine": Engine.get_version_info(), "debug_build": OS.is_debug_build(),
		"processor": OS.get_processor_name(), "logical_processors": OS.get_processor_count(),
		"os": OS.get_name(), "os_version": OS.get_version(), "seed": seed_value,
		"initial": initial_counts, "final": Array(_world.counts()), "cohort_size": _records.size(),
		"world_size": [_world.config.world_size.x, _world.config.world_size.y],
		"fixture_half_width": FIXTURE_HALF_WIDTH, "warmup_ticks": warmup_ticks,
		"warmup_ai_budget_usec": WARMUP_BUDGET_USEC, "warmup_task_counts": warmup_tasks,
		"stimulus_tick": _stimulus_tick, "stimulus_position": [stimulus_position.x, stimulus_position.y],
		"stimulus": "One wolf appears at current cohort centroid after wolf-free warmup; every sheep remains in the simulation.",
		"sample_ticks": sample_ticks, "end_tick": _world.tick, "fixed_dt": _world.config.fixed_dt,
		"perception_radius": _world.config.perception_radius, "grid_cell_size": _world.config.cell_size,
		"ai_budget_usec_per_step_frame": _world.config.ai_budget_usec,
		"wall_seconds": elapsed_seconds, "captures": _world.capture_count,
		"outcomes": outcomes, "instrumentation": _world.probes.summary(),
		"observer": "Read-only geometry before each step, knowledge and valid owned FLEE intent after each step. Capture signal preserves same-step response before lifecycle cleanup. Decision timestamps use step-start tick; death uses published boundary tick. Each fixed step receives one headless frame budget. Entire fixed window is sampled, including nonresponders and deaths. Full-cohort scans and capture callback cost are included in wall time. GPU time is not measured. FLEE onset is a decision response, not proof of physical escape.",
		"quality": "quality.csv scans every live species after each publication, including the stimulus wolf. Missing/expired intents also include never-issued intents. Perception mean excludes never-perceived agents, reported separately. Decision age starts at birth until first update. Quality scans and in-memory rows are included in wall time, outside the AI job budget.",
		"latency": "Per-agent flee minus geometric visibility only when both exist; negative values are preserved as response-before-exposure. Censored denotes exposed with no response, including death as a separately counted competing outcome. First-known tick is the first step where the observer finds knowledge, not the report's original observed tick. Its source is the end-of-step value; shared delivery followed by direct scanning within that same step is recorded as DIRECT, without claiming intra-step arrival order. Undefined latency uses -1; response_class disambiguates it from a real negative latency."
	}

func _responded_before_direct_discovery(record: ResponseRecord) -> bool:
	return record.response_tick >= 0 and (record.direct_tick < 0 or record.response_tick < record.direct_tick)

func _save_results(output: String, summary: Dictionary) -> bool:
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(output)
	if directory_error != OK:
		push_error("Cannot create cohort benchmark output: " + output)
		return false
	var csv: FileAccess = FileAccess.open(output.path_join("responses.csv"), FileAccess.WRITE)
	if csv == null:
		push_error("Cannot write cohort responses: " + output)
		return false
	csv.store_csv_line(PackedStringArray(RESPONSE_COLUMNS))
	for record: ResponseRecord in _records:
		csv.store_csv_line(_response_row(record))
	csv.close()
	var quality_csv: FileAccess = FileAccess.open(output.path_join("quality.csv"), FileAccess.WRITE)
	if quality_csv == null:
		push_error("Cannot write cohort quality samples: " + output)
		return false
	quality_csv.store_csv_line(PackedStringArray(QUALITY_COLUMNS))
	for row: PackedStringArray in _quality_rows:
		quality_csv.store_csv_line(row)
	quality_csv.close()
	var json: FileAccess = FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	if json == null:
		push_error("Cannot write cohort summary: " + output)
		return false
	json.store_string(JSON.stringify(summary, "  "))
	json.close()
	_world.probes.export_jobs(output)
	_world.probes.export_queues(output)
	print("THREAT_COHORT samples=%d agents=%d outcomes=%s" % [summary["sample_ticks"], _records.size(), JSON.stringify(summary["outcomes"])])
	return true

func _response_row(record: ResponseRecord) -> PackedStringArray:
	var latency_ticks: int = -1
	if record.geometric_tick >= 0 and record.response_tick >= 0:
		latency_ticks = record.response_tick - record.geometric_tick
	var censored: bool = record.geometric_tick >= 0 and record.response_tick < 0
	return PackedStringArray([
		str(record.handle.slot), str(record.handle.generation), str(record.handle.world_epoch),
		str(record.stimulus_position.x), str(record.stimulus_position.y), str(record.stimulus_velocity.x), str(record.stimulus_velocity.y), str(record.stimulus_hunger), String(record.stimulus_task),
		str(record.geometric_tick), str(record.exposure_steps), str(record.known_tick), record.known_source, str(record.direct_tick), str(record.response_tick),
		str(record.death_tick), str(record.alive_at_end), record.response_class(), str(latency_ticks), str(_responded_before_direct_discovery(record)), str(censored)
	])
