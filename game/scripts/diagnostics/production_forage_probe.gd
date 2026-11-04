class_name ProductionForageProbe
extends ProductionBehaviorProtocol
## Environmental depletion is an explicit experiment, never an AI instruction.
const DROUGHT_REQUEST_TICK: int = 240
const DROUGHT_EFFECTIVE_TICK: int = DROUGHT_REQUEST_TICK + 1
const END_TICK: int = 1200
const SPACING: float = 32.0
# Float32 hunger writes can differ from a double metabolic prediction by an ULP.
# Require substantially more than that noise before recording physical eating.
const HUNGER_EVIDENCE_EPSILON: float = 0.0000002
var empty_control: bool = false
var _world: SimulationWorld
var _seed: int
var _sheep_count: int
var _started_usec: int
var _records: Array[ProductionForageTrace] = []
var _dry_region: Rect2
var _depleted_cells: PackedInt32Array = PackedInt32Array()
var _depleted_food: float = 0.0
var _actual_consumed_after_drought: float = 0.0
var _quality: Array[Dictionary] = []

func setup(world: SimulationWorld, sheep_count: int, seed_value: int) -> void:
	assert(world.store.count == 0 and sheep_count >= 8 and sheep_count <= 1000)
	assert(world.config.world_size == Vector2(2400, 1400))
	assert(world.config.grass_recovery_rate == 0.0)
	_world = world
	_seed = seed_value
	_sheep_count = sheep_count
	_started_usec = Time.get_ticks_usec()
	world.diagnostic_step_started = observe_step_start
	var random := RandomNumberGenerator.new()
	random.seed = seed_value
	var columns: int = ceili(sqrt(float(sheep_count)))
	var rows: int = ceili(float(sheep_count) / columns)
	for index: int in sheep_count:
		var offset := Vector2(index % columns - (columns - 1) * 0.5, index / columns - (rows - 1) * 0.5) * SPACING
		world.queue_place(SimTypes.Species.SHEEP, Vector2(1200, 700) + offset + Vector2(random.randf_range(-2, 2), random.randf_range(-2, 2)))

func before_step(world: SimulationWorld) -> void:
	if finished or world.tick != DROUGHT_REQUEST_TICK:
		return
	var started: int = Time.get_ticks_usec()
	_deplete_declared_region()
	observer_usec += Time.get_ticks_usec() - started

func _deplete_declared_region() -> void:
	var lower: Vector2 = _world.config.world_size
	var upper := Vector2.ZERO
	for record: ProductionForageTrace in _records:
		var dense: int = _world.store.resolve(record.handle)
		assert(dense >= 0)
		lower = lower.min(_world.store.position_current[dense])
		upper = upper.max(_world.store.position_current[dense])
	var padding: float = _world.resources.cell_size * (_world.config.forage_cell_radius + 2)
	lower = ((lower - Vector2.ONE * padding) / _world.resources.cell_size).floor() * _world.resources.cell_size
	upper = ((upper + Vector2.ONE * padding) / _world.resources.cell_size).ceil() * _world.resources.cell_size
	lower = lower.max(Vector2.ZERO)
	upper = upper.min(_world.config.world_size)
	_dry_region = Rect2(lower, upper - lower)
	if empty_control:
		_dry_region = Rect2(Vector2.ZERO, _world.config.world_size)
	for cell: int in _world.resources.cell_count:
		if not _dry_region.has_point(_world.resources.cell_center(cell)):
			continue
		_depleted_cells.append(cell)
		# Safe worker boundary; ordinary consume commits this environmental change
		# at n+1. AI at n may still see the valid prior resource snapshot.
		_depleted_food += _world.resources.consume(cell, _world.resources.food_capacity(cell), _world.tick)

func observe_step_start(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	if _records.is_empty():
		for dense: int in world.store.count:
			var record := ProductionForageTrace.new()
			record.handle = world.store.handle_at(dense)
			record.diagnostics.detailed = _records.size() < ProductionForageDiagnostics.MAX_DETAILED_LIVES
			_records.append(record)
		assert(_records.size() == _sheep_count)
	for record: ProductionForageTrace in _records:
		var dense: int = world.store.resolve(record.handle)
		assert(dense >= 0, "No removal or predator belongs to the forage protocol")
		record.previous_position = world.store.position_current[dense]
		record.previous_hunger = world.store.hunger[dense]
		if world.tick < DROUGHT_EFFECTIVE_TICK:
			continue
		_observe_food_opportunity(record)
		record.diagnostics.begin_step(world, record)
	observer_usec += Time.get_ticks_usec() - started

func _observe_food_opportunity(record: ProductionForageTrace) -> void:
	var resources: ResourceGrid = _world.resources
	var cell: int = resources.cell_at(record.previous_position)
	var underfoot: float = resources.get_effective_amount(cell, _world.tick)
	if record.eligible_tick >= 0:
		if underfoot >= ResourceGrid.MIN_GRAZABLE_AMOUNT and record.edible_underfoot_tick < 0:
			record.edible_underfoot_tick = _world.tick
		return
	var context: AgentContext = _world.ai.inspect(record.handle)
	if record.previous_hunger < _world.ai.settings.hungry_threshold and not context.grazing_committed:
		return
	if underfoot >= ResourceGrid.MIN_GRAZABLE_AMOUNT:
		return
	if resources.best_neighbor(record.previous_position, _world.config.forage_cell_radius, _world.tick, record.handle) >= 0:
		return
	record.eligible_tick = _world.tick
	record.eligible_usec = Time.get_ticks_usec() - _started_usec
	record.eligible_position = record.previous_position

func after_step(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	var tick: int = world.tick - 1
	if tick >= DROUGHT_EFFECTIVE_TICK:
		_actual_consumed_after_drought += world.interaction.grass_consumed
	for record: ProductionForageTrace in _records:
		var context: AgentContext = world.ai.inspect(record.handle)
		var dense: int = world.store.resolve(record.handle)
		assert(dense >= 0)
		var intent: MotionIntent = world.intents.get_intent(record.handle, tick)
		var position: Vector2 = world.store.position_current[dense]
		if record.eligible_tick >= 0:
			_observe_migration(record, context, intent, position, world.store.hunger[dense], tick)
		if tick >= DROUGHT_EFFECTIVE_TICK:
			record.diagnostics.end_step(world, record, context, intent, tick)
		if world.tick == END_TICK:
			record.terminal = {"handle": record.handle.key(), "tick": tick, "position_x": position.x,
				"position_y": position.y, "hunger": world.store.hunger[dense],
				"task": str(context.task_name), "task_token": context.task_token,
				"intent_present": intent != null, "intent_owned": intent != null and intent.owner_token == context.task_token,
				"behavior": SimTypes.Behavior.keys()[intent.behavior] if intent != null else "NONE",
				"perception_tick": context.last_perception_tick, "decision_tick": context.last_decision_tick,
				"grazing_committed": context.grazing_committed, "alive": true}
	if world.tick % 60 == 0:
		_sample_quality(tick)
	observed_steps += 1
	observer_usec += Time.get_ticks_usec() - started
	finished = world.tick >= END_TICK

func _observe_migration(record: ProductionForageTrace, context: AgentContext, intent: MotionIntent, position: Vector2, hunger: float, tick: int) -> void:
	var displacement: Vector2 = position - record.previous_position
	record.path_pixels += displacement.length()
	record.maximum_net_pixels = maxf(record.maximum_net_pixels, position.distance_to(record.eligible_position))
	if not _dry_region.has_point(position) and record.exit_dry_region_tick < 0:
		record.exit_dry_region_tick = tick + 1
	if intent == null or intent.owner_token != context.task_token:
		return
	if context.task_name == &"search_area" and intent.behavior == SimTypes.Behavior.SEARCH and intent.mode == SimTypes.IntentMode.MOVE:
		if record.search_tick < 0:
			record.search_tick = tick
			record.search_usec = Time.get_ticks_usec() - _started_usec
		record.search_progress += maxf(0.0, displacement.dot((intent.destination - record.previous_position).normalized()))
		if record.search_progress >= 1.0 and record.search_motion_tick < 0:
			record.search_motion_tick = tick + 1
			record.search_motion_usec = Time.get_ticks_usec() - _started_usec
	if intent.mode != SimTypes.IntentMode.GRAZE or intent.resource_cell < 0 or not _world.resources.can_graze_at(intent.resource_cell, position):
		return
	var metabolism: float = _world.config.sheep_metabolism / _world.config.sheep_stomach_capacity * _world.config.fixed_dt
	var expected_without_food: float = clampf(record.previous_hunger + metabolism, 0.0, 1.0)
	var hunger_reduction: float = expected_without_food - hunger
	if hunger_reduction <= HUNGER_EVIDENCE_EPSILON:
		return
	record.food_eaten += hunger_reduction * _world.config.sheep_stomach_capacity
	if record.eating_tick < 0:
		record.eating_tick = tick + 1
		record.eating_usec = Time.get_ticks_usec() - _started_usec
		record.first_intake = {"handle": record.handle.key(), "input_tick": tick, "completed_tick": tick + 1,
			"hunger_before_step": record.previous_hunger, "metabolism_increment": metabolism,
			"expected_hunger_without_food": expected_without_food, "hunger_after_step": hunger,
			"derived_food": hunger_reduction * _world.config.sheep_stomach_capacity,
			"stomach_capacity": _world.config.sheep_stomach_capacity,
			"interaction_total_consumed_this_step": _world.interaction.grass_consumed,
			"resource_cell": intent.resource_cell, "position_x": position.x, "position_y": position.y,
			"task": str(context.task_name), "task_token": context.task_token, "intent_token": intent.owner_token,
			"intent_expires_tick": intent.expires_tick}
		# The final bite may empty a patch; actual intake is still arrival evidence.
		if record.edible_underfoot_tick < 0:
			record.edible_underfoot_tick = tick + 1

func _sample_quality(tick: int) -> void:
	var missing: int = 0
	var eligible: int = 0
	var moving: int = 0
	var eating: int = 0
	for record: ProductionForageTrace in _records:
		missing += int(_world.intents.get_intent(record.handle, tick) == null)
		eligible += int(record.eligible_tick >= 0)
		moving += int(record.search_motion_tick >= 0)
		eating += int(record.eating_tick >= 0)
	_quality.append({"tick": tick + 1, "elapsed_usec": Time.get_ticks_usec() - _started_usec,
		"active": _records.size(), "missing_intents": missing, "eligible": eligible,
		"search_motion_observed": moving, "real_intake_observed": eating})

func finish_report() -> Dictionary:
	assert(finished)
	var records: Array[Dictionary] = []
	var terminal: Array[Dictionary] = []
	var first_intake: Array[Dictionary] = []
	var diagnostics: Array[Dictionary] = []
	var diagnostic_samples: Array[Dictionary] = []
	var diagnostic_events: Array[Dictionary] = []
	var diagnostic_terminal: Array[Dictionary] = []
	var outcome: Dictionary = {"case": "forage_empty_control" if empty_control else "forage_migration",
		"cohort": _records.size(), "eligible": 0, "never_eligible": 0, "search_decision": 0,
		"search_motion": 0, "left_dry_region": 0, "real_intake": 0, "migration_completed": 0,
		"eligible_without_search": 0, "eligible_without_intake": 0, "goal_reachable_by_fixture": not empty_control}
	for record: ProductionForageTrace in _records:
		var row: Dictionary = record.to_dictionary(_world.config.agent_radius * 2.0)
		records.append(row)
		terminal.append(record.terminal.duplicate(true))
		diagnostics.append(record.diagnostics.summary(record.handle))
		diagnostic_samples.append_array(record.diagnostics.samples)
		diagnostic_events.append_array(record.diagnostics.event_rows())
		diagnostic_terminal.append(record.diagnostics.terminal)
		if not record.first_intake.is_empty():
			first_intake.append(record.first_intake.duplicate(true))
		if record.eligible_tick < 0:
			outcome["never_eligible"] += 1
			continue
		outcome["eligible"] += 1
		outcome["search_decision"] += int(record.search_tick >= 0)
		outcome["search_motion"] += int(record.search_motion_tick >= 0)
		outcome["left_dry_region"] += int(record.exit_dry_region_tick >= 0)
		outcome["real_intake"] += int(record.eating_tick >= 0)
		outcome["migration_completed"] += int(row["migration_completed"])
		outcome["eligible_without_search"] += int(record.search_tick < 0)
		outcome["eligible_without_intake"] += int(record.eating_tick < 0)
	var report: Dictionary = report_header(_world, "production-forage-migration-v1", _seed, _sheep_count, _started_usec)
	report.merge({"case": outcome["case"], "outcomes": [outcome], "records": records, "terminal": terminal,
		"quality": _quality.duplicate(true), "first_intake": first_intake, "empty_control": empty_control,
		"forage_diagnostics_version": "forage-resource-evidence-v1",
		"forage_diagnostics": diagnostics, "forage_samples": diagnostic_samples,
		"forage_events": diagnostic_events, "forage_terminal_context": diagnostic_terminal,
		"forage_diagnostics_scope": "Old opportunity/success columns are unchanged. Every life has exact post-drought aggregate counts and terminal context; only the first128 registered lives have <=34 periodic rows and the latest16 transition rows. Omitted events are counted. Resource amounts at n/n+1 use the existing pure snapshot API; cell food decrease includes other consumers. Transition tags are observed facts, not inferred BT exit reasons. Backoff changes expose the existing public retry deadline; no private task fields are read. Unexcluded local candidate is an independent read-only query, not reconstruction of the task's blocked-cell choice. Nonclosing ticks describe measured consecutive geometry, not the BT's internal six-pixel progress watermark. Observer cost is included and this run cannot establish unprobed capacity.",
		"drought": {"requested_tick": DROUGHT_REQUEST_TICK, "effective_tick": DROUGHT_EFFECTIVE_TICK,
			"region": [_dry_region.position.x, _dry_region.position.y, _dry_region.size.x, _dry_region.size.y],
			"cells": Array(_depleted_cells), "food_removed": _depleted_food, "recovery_per_second": _world.config.grass_recovery_rate},
		"interaction_grass_consumed_after_drought": _actual_consumed_after_drought,
		"eligibility": "At post-stage0 n>=241: real hunger>=hungry_threshold or feeding commitment; underfoot coverage below MIN_GRAZABLE_AMOUNT and ordinary local best_neighbor has no eligible grass. No forced hunger, intent or task. Never-eligible lives remain explicit.",
		"migration_evidence": "Owned SEARCH plus >=1px real forward projection; actual body center leaves the depleted region and net displacement reaches one body diameter; later owned GRAZE inside its resource cell reduces hunger below the metabolic prediction by >2e-7. The latter is derived stomach intake, independently accompanied by InteractionSystem grass consumption. SEARCH alone is not a successful migration.",
		"scope": "Normal sheep trees and 6ms worker; no predators. Resource depletion is a declared external experiment at an owner-thread safe boundary. Empty control intentionally has no reachable food: exploration is measurable, absent intake is not classified as a failed reachable goal. Limited food supply and finite horizon are retained, not compensated."})
	return report
