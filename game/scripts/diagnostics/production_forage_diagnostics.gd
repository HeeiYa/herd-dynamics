class_name ProductionForageDiagnostics
extends RefCounted
## Optional worker-owned evidence. Published intent and public context facts are
## observed; no private BT task, selection routine, or steering policy is changed.
const FIRST_TICK: int = 241
const LAST_TICK: int = 1199
const SAMPLE_PERIOD: int = 30
const MAX_DETAILED_LIVES: int = 128
const MAX_EVENTS: int = 16
const MAX_SAMPLES: int = 34
const CLOSING_EPSILON: float = 0.0001
var detailed: bool = false
var samples: Array[Dictionary] = []
var events: Array[Dictionary] = []
var terminal: Dictionary = {}
var observed_steps: int = 0
var missing_or_unowned_steps: int = 0
var owned_grass_steps: int = 0
var approach_steps: int = 0
var resource_member_steps: int = 0
var member_while_moving_steps: int = 0
var first_resource_entry_tick: int = -1
var grazing_member_steps: int = 0
var grazing_member_without_intake_steps: int = 0
var approach_path_pixels: float = 0.0
var approach_closing_pixels: float = 0.0
var minimum_destination_distance: float = INF
var longest_nonclosing_approach_ticks: int = 0
var backoff_entries: int = 0
var resource_output_changes: int = 0
var leaf_changes: int = 0
var left_depleted_resource_count: int = 0
var event_count: int = 0
var _event_cursor: int = 0
var _nonclosing_ticks: int = 0
var _before_tick: int = -1
var _before_leaf: StringName
var _before_cell: int = -1
var _before_retry_tick: int = 0
var _before_owned: bool = false
var _before_mode: int = -1
var _before_velocity: Vector2
var _before_food_eaten: float = 0.0

func begin_step(world: SimulationWorld, record: ProductionForageTrace) -> void:
	_before_tick = world.tick
	var context: AgentContext = world.ai.inspect(record.handle)
	var intent: MotionIntent = world.intents.get_intent(record.handle, world.tick)
	_before_owned = _owned(context, intent)
	_before_leaf = context.task_name
	_before_cell = intent.resource_cell if _before_owned else -1
	_before_mode = intent.mode if _before_owned else -1
	_before_retry_tick = context.grazing_retry_after_tick
	_before_velocity = world.store.velocity_current[world.store.resolve(record.handle)]
	_before_food_eaten = record.food_eaten

func end_step(world: SimulationWorld, record: ProductionForageTrace, context: AgentContext, intent: MotionIntent, tick: int) -> void:
	assert(_before_tick == tick and tick >= FIRST_TICK and tick <= LAST_TICK)
	observed_steps += 1
	var owned: bool = _owned(context, intent)
	var cell: int = intent.resource_cell if owned else -1
	var position: Vector2 = world.store.position_current[world.store.resolve(record.handle)]
	var intake: float = maxf(0.0, record.food_eaten - _before_food_eaten)
	missing_or_unowned_steps += int(not owned)
	if cell != _before_cell:
		_nonclosing_ticks = 0
	_accumulate_approach(world, record, context, intent, position, owned, cell, intake)
	var facts: PackedStringArray = _transition_facts(world, record, context, owned, cell, tick)
	var periodic: bool = (tick - FIRST_TICK) % SAMPLE_PERIOD == 0 or tick == LAST_TICK
	if not detailed and tick != LAST_TICK:
		return
	if facts.is_empty() and not periodic:
		return
	var row: Dictionary = _make_row(world, record, context, intent, tick, intake)
	row["transition_facts"] = "|".join(facts)
	if detailed and not facts.is_empty():
		_retain_event(row)
	if detailed and periodic:
		assert(samples.size() < MAX_SAMPLES)
		samples.append(row)
	if tick == LAST_TICK:
		terminal = row

func _accumulate_approach(world: SimulationWorld, record: ProductionForageTrace, context: AgentContext, intent: MotionIntent, position: Vector2, owned: bool, cell: int, intake: float) -> void:
	if not owned or context.task_name != &"graze_grass" or intent.behavior != SimTypes.Behavior.GRAZE or cell < 0:
		_nonclosing_ticks = 0
		return
	assert(cell < world.resources.cell_count)
	owned_grass_steps += 1
	var distance_before: float = record.previous_position.distance_to(intent.destination)
	var distance_after: float = position.distance_to(intent.destination)
	minimum_destination_distance = minf(minimum_destination_distance, distance_after)
	if world.resources.can_graze_at(cell, position):
		resource_member_steps += 1
		member_while_moving_steps += int(intent.mode == SimTypes.IntentMode.MOVE)
		if first_resource_entry_tick < 0:
			first_resource_entry_tick = world.tick
	if intent.mode == SimTypes.IntentMode.MOVE:
		approach_steps += 1
		approach_path_pixels += position.distance_to(record.previous_position)
		approach_closing_pixels += maxf(0.0, distance_before - distance_after)
		_nonclosing_ticks = _nonclosing_ticks + 1 if distance_after >= distance_before - CLOSING_EPSILON else 0
		longest_nonclosing_approach_ticks = maxi(longest_nonclosing_approach_ticks, _nonclosing_ticks)
	else:
		_nonclosing_ticks = 0
	if intent.mode == SimTypes.IntentMode.GRAZE and world.resources.can_graze_at(cell, position):
		grazing_member_steps += 1
		grazing_member_without_intake_steps += int(intake <= 0.0)

func _transition_facts(world: SimulationWorld, record: ProductionForageTrace, context: AgentContext, owned: bool, cell: int, tick: int) -> PackedStringArray:
	var facts := PackedStringArray()
	if context.task_name != _before_leaf:
		leaf_changes += 1
		facts.append("LEAF_CHANGED")
	if cell != _before_cell:
		resource_output_changes += 1
		facts.append("RESOURCE_OUTPUT_CHANGED")
	if owned != _before_owned:
		facts.append("INPUT_OWNERSHIP_CHANGED")
	var current_intent: MotionIntent = world.intents.get_intent(record.handle, tick)
	var mode: int = current_intent.mode if owned else -1
	if mode != _before_mode:
		facts.append("INTENT_MODE_CHANGED")
	if context.grazing_retry_after_tick > _before_retry_tick:
		backoff_entries += 1
		facts.append("GRAZE_BACKOFF_ENTERED")
	if _before_cell >= 0 and (cell != _before_cell or context.task_name != _before_leaf):
		if world.resources.get_effective_amount(_before_cell, tick) < ResourceGrid.MIN_GRAZABLE_AMOUNT:
			left_depleted_resource_count += 1
			facts.append("PREVIOUS_RESOURCE_BELOW_MIN")
	if record.eating_tick == tick + 1:
		facts.append("FIRST_REAL_INTAKE")
	if first_resource_entry_tick == tick + 1:
		facts.append("FIRST_RESOURCE_ENTRY")
	if not facts.is_empty():
		event_count += 1
	return facts

func _make_row(world: SimulationWorld, record: ProductionForageTrace, context: AgentContext, intent: MotionIntent, tick: int, intake: float) -> Dictionary:
	var dense: int = world.store.resolve(record.handle)
	assert(dense >= 0, "The forage protocol has no predator or removal")
	var position: Vector2 = world.store.position_current[dense]
	var velocity: Vector2 = world.store.velocity_current[dense]
	var resources: ResourceGrid = world.resources
	var owned: bool = _owned(context, intent)
	var cell: int = intent.resource_cell if owned else -1
	var underfoot_before: int = resources.cell_at(record.previous_position)
	var underfoot_after: int = resources.cell_at(position)
	var row: Dictionary = {"handle": record.handle.key(), "input_tick": tick, "completed_tick": tick + 1,
		"eligible_tick": record.eligible_tick, "task_before": str(_before_leaf), "task_after": str(context.task_name),
		"task_token": context.task_token, "intent_present": intent != null, "intent_owned": owned,
		"intent_token": intent.owner_token if intent != null else -1,
		"intent_expires_tick": intent.expires_tick if intent != null else -1,
		"intent_mode": SimTypes.IntentMode.keys()[intent.mode] if intent != null else "NONE",
		"intent_behavior": SimTypes.Behavior.keys()[intent.behavior] if intent != null else "NONE",
		"position_before_x": record.previous_position.x, "position_before_y": record.previous_position.y,
		"position_after_x": position.x, "position_after_y": position.y,
		"speed_before": _before_velocity.length(), "speed_after": velocity.length(),
		"hunger_before": record.previous_hunger, "hunger_after": world.store.hunger[dense], "derived_food_this_step": intake,
		"grazing_committed": context.grazing_committed, "retry_before_tick": _before_retry_tick,
		"retry_after_tick": context.grazing_retry_after_tick,
		"perception_tick": context.last_perception_tick, "decision_tick": context.last_decision_tick,
		"perception_queued": context.perception_queued, "decision_queued": context.decision_queued,
		"underfoot_before_cell": underfoot_before, "underfoot_before_coverage": resources.get_effective_amount(underfoot_before, tick),
		"underfoot_after_cell": underfoot_after, "underfoot_after_coverage": resources.get_effective_amount(underfoot_after, tick + 1),
		"previous_resource_cell": _before_cell,
		"previous_resource_coverage_at_input": resources.get_effective_amount(_before_cell, tick) if _before_cell >= 0 else null,
		"resource_cell": cell, "destination_x": intent.destination.x if owned else null,
		"destination_y": intent.destination.y if owned else null,
		"distance_before": record.previous_position.distance_to(intent.destination) if owned else null,
		"distance_after": position.distance_to(intent.destination) if owned else null,
		"resource_member_before": resources.can_graze_at(cell, record.previous_position),
		"resource_member_after": resources.can_graze_at(cell, position),
		"resource_coverage_at_input": null, "resource_coverage_at_end": null, "resource_food_decrease": null,
		# This is an independent local query with no blocked-cell exclusion. It
		# reports available evidence, never claims to reconstruct the BT choice.
		"unexcluded_local_candidate": resources.best_neighbor(record.previous_position, world.config.forage_cell_radius, tick, record.handle)}
	if cell >= 0:
		assert(cell < resources.cell_count)
		var before: float = resources.get_effective_amount(cell, tick)
		var after: float = resources.get_effective_amount(cell, tick + 1)
		row["resource_coverage_at_input"] = before
		row["resource_coverage_at_end"] = after
		row["resource_food_decrease"] = maxf(0.0, before - after) * resources.food_capacity(cell)
	return row

func _owned(context: AgentContext, intent: MotionIntent) -> bool:
	return intent != null and context.task_token > 0 and intent.owner_token == context.task_token and intent.actor != null and intent.actor.same_life(context.handle)

func _retain_event(row: Dictionary) -> void:
	if events.size() < MAX_EVENTS:
		events.append(row)
	else:
		events[_event_cursor] = row
		_event_cursor = (_event_cursor + 1) % MAX_EVENTS

func event_rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = events.duplicate()
	result.sort_custom(_earlier_event)
	return result

func _earlier_event(left: Dictionary, right: Dictionary) -> bool:
	return int(left["input_tick"]) < int(right["input_tick"])

func summary(handle: AgentHandle) -> Dictionary:
	return {"handle": handle.key(), "detailed": detailed, "observed_steps": observed_steps,
		"missing_or_unowned_steps": missing_or_unowned_steps, "owned_grass_steps": owned_grass_steps,
		"approach_steps": approach_steps, "grazing_member_steps": grazing_member_steps,
		"resource_member_steps": resource_member_steps, "member_while_moving_steps": member_while_moving_steps,
		"first_resource_entry_tick": first_resource_entry_tick,
		"grazing_member_without_intake_steps": grazing_member_without_intake_steps,
		"approach_path_pixels": approach_path_pixels, "approach_closing_pixels": approach_closing_pixels,
		"minimum_destination_distance": minimum_destination_distance if is_finite(minimum_destination_distance) else null,
		"longest_nonclosing_approach_ticks": longest_nonclosing_approach_ticks,
		"backoff_entries": backoff_entries, "resource_output_changes": resource_output_changes,
		"leaf_changes": leaf_changes, "left_depleted_resource_count": left_depleted_resource_count,
		"event_count": event_count, "events_retained": events.size(), "events_omitted": event_count - events.size(),
		"periodic_samples": samples.size()}
