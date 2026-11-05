class_name ProductionDogWithdrawal
extends RefCounted
## Finite owner-thread evidence for two declared wolves. This observer never
## updates knowledge/trees or assigns an intent; only the declared removal is sent.
enum Mode { INVALID = -1, ORIGINAL = 0, REMOVE_DOGS = 1, KEEP_ALL = 2 }
const VERSION: String = "production-dog-withdrawal-v1"
const INTERVENTION_TICK: int = 300
const PRE_STATE_TICK: int = 299
const FIRST_WOLF_TICK: int = 240
const END_TICK: int = 1200

class WolfRecord extends RefCounted:
	var actor: AgentHandle
	var before: Dictionary = {}
	var boundary: Dictionary = {}
	var retreat_at_boundary: bool = false
	var first_service_tick: int = -1
	var first_service_usec: int = -1
	var left_retreat_tick: int = -1
	var first_nonretreat_intent_tick: int = -1
	var motion_tick: int = -1
	var intended_progress_pixels: float = 0.0
	var active_steps: int = 0
	var post_active_steps: int = 0
	var post_service_steps: int = 0
	var post_missing_intent_steps: int = 0
	var post_unowned_intent_steps: int = 0
	var death_tick: int = -1
	var terminal: Dictionary = {}

var mode: Mode
var records: Array[WolfRecord] = []
var steps: Array[Dictionary] = []
var pre299: Array[Dictionary] = []
var dog_controls: Array[Dictionary] = []
var observer_usec: int = 0
var boundary_prepared: bool = false
var control_observed: bool = false
var boundary_elapsed_usec: int = -1
var _dogs: Array[AgentHandle] = []

static func from_arguments(arguments: PackedStringArray) -> Mode:
	for argument: String in arguments:
		if argument.begins_with("--dog-withdrawal="):
			match argument.trim_prefix("--dog-withdrawal="):
				"remove-dogs":
					return Mode.REMOVE_DOGS
				"keep-all":
					return Mode.KEEP_ALL
				_:
					return Mode.INVALID
	return Mode.ORIGINAL

static func mode_name(value: Mode) -> String:
	match value:
		Mode.ORIGINAL:
			return "original-remove-wolves"
		Mode.REMOVE_DOGS:
			return "remove-dogs"
		Mode.KEEP_ALL:
			return "keep-all"
	return "invalid"

static func argument_error(arguments: PackedStringArray, behavior_case: String, total: int, seed_value: int) -> String:
	var selections: int = 0
	for argument: String in arguments:
		if argument.begins_with("--dog-withdrawal="):
			selections += 1
	if behavior_case != "dog-withdrawal":
		return "dog-withdrawal option requires its explicit diagnostic case" if selections > 0 else ""
	if selections != 1 or from_arguments(arguments) not in [Mode.REMOVE_DOGS, Mode.KEEP_ALL]:
		return "Select exactly one dog-withdrawal mode: remove-dogs or keep-all"
	if total != 80 or seed_value not in [43, 44]:
		return "Dog withdrawal requires80 sheep and seed43/44"
	if ProductionDogProtectionGeometry.from_arguments(arguments) != ProductionDogProtectionGeometry.Variant.ANCHOR_OBLIQUE:
		return "Dog withdrawal requires explicit anchor-oblique geometry"
	return ""

func register_lives(dogs: Array[AgentHandle], wolves: Array[AgentHandle]) -> void:
	assert(records.is_empty() and dogs.size() == 4 and wolves.size() == 2)
	_dogs = dogs.duplicate()
	for actor: AgentHandle in wolves:
		var record := WolfRecord.new()
		record.actor = actor
		records.append(record)

func before_step(world: SimulationWorld, started_usec: int) -> void:
	if world.tick != INTERVENTION_TICK or boundary_prepared:
		return
	var started: int = Time.get_ticks_usec()
	boundary_prepared = true
	boundary_elapsed_usec = Time.get_ticks_usec() - started_usec
	for record: WolfRecord in records:
		record.boundary = _capture(world, record.actor, world.tick)
		record.retreat_at_boundary = record.boundary["active"] and (record.boundary["retreating"] or _owned_retreat(record.boundary))
	for dog: AgentHandle in _dogs:
		var dense: int = world.store.resolve(dog)
		var row: Dictionary = {"dog": dog.key(), "input_tick": world.tick,
			"mode": mode_name(mode), "removal_queued": mode == Mode.REMOVE_DOGS,
			"alive_before": world.store.is_alive(dog), "active_before": world.store.is_active(dog),
			"before_x": world.store.position_current[dense].x if dense >= 0 else null,
			"before_y": world.store.position_current[dense].y if dense >= 0 else null,
			"submitted_elapsed_usec": Time.get_ticks_usec() - started_usec,
			"post_stage0_observed": false, "alive_after": null, "active_after": null,
			"context_after": null, "intent_after": null, "actual_removed": false}
		dog_controls.append(row)
		if mode == Mode.REMOVE_DOGS:
			world.queue_remove(dog)
	observer_usec += Time.get_ticks_usec() - started

func observe_step_start(world: SimulationWorld) -> void:
	var started: int = Time.get_ticks_usec()
	if world.tick == INTERVENTION_TICK and boundary_prepared and not control_observed:
		control_observed = true
		for index: int in _dogs.size():
			var dog: AgentHandle = _dogs[index]
			var row: Dictionary = dog_controls[index]
			row["post_stage0_observed"] = true
			row["alive_after"] = world.store.is_alive(dog)
			row["active_after"] = world.store.is_active(dog)
			row["context_after"] = world.ai.inspect(dog) != null
			row["intent_after"] = world.intents.get_intent(dog, world.tick) != null
			row["actual_removed"] = row["removal_queued"] and row["alive_before"] and not row["alive_after"]
	for record: WolfRecord in records:
		record.before = _capture(world, record.actor, world.tick)
		if world.tick == PRE_STATE_TICK:
			pre299.append(record.before.duplicate(true))
	observer_usec += Time.get_ticks_usec() - started

func after_step(world: SimulationWorld, started_usec: int) -> void:
	var started: int = Time.get_ticks_usec()
	var tick: int = world.tick - 1
	if tick < FIRST_WOLF_TICK or tick >= END_TICK:
		return
	for record: WolfRecord in records:
		var after: Dictionary = _capture(world, record.actor, tick)
		var before: Dictionary = record.before
		assert(not before.is_empty() and before["input_tick"] == tick)
		var served: bool = (before["tree_present"] and after["tree_present"]
			and after["decision_tick"] == tick and after["decision_tick"] > before["decision_tick"])
		var elapsed: int = Time.get_ticks_usec() - started_usec
		var progress: float = _observe_response(record, before, after, tick, elapsed, served)
		var row: Dictionary = {"wolf": record.actor.key(), "input_tick": tick, "completed_tick": world.tick,
			"elapsed_usec": elapsed, "real_tree_service": served, "effective_motion_progress_pixels": progress}
		for key: String in before:
			row["before_" + key] = before[key]
		for key: String in after:
			row["after_" + key] = after[key]
		assert(steps.size() < 2 * (END_TICK - FIRST_WOLF_TICK), "The two-life diagnostic window must remain finite")
		steps.append(row)
		record.terminal = after
	observer_usec += Time.get_ticks_usec() - started

func _observe_response(record: WolfRecord, before: Dictionary, after: Dictionary, tick: int, elapsed: int, served: bool) -> float:
	if not before["active"] or not after["active"]:
		if not after["alive"] and record.death_tick < 0:
			record.death_tick = tick + 1
		return 0.0
	record.active_steps += 1
	if tick < INTERVENTION_TICK:
		return 0.0
	record.post_active_steps += 1
	record.post_service_steps += int(served)
	record.post_missing_intent_steps += int(not after["intent_present"])
	record.post_unowned_intent_steps += int(after["intent_present"] and not after["intent_owned"])
	if served and record.first_service_tick < 0:
		record.first_service_tick = tick
		record.first_service_usec = elapsed
	if served and not after["retreating"] and record.left_retreat_tick < 0:
		record.left_retreat_tick = tick
	if record.first_service_tick < 0 or record.left_retreat_tick < 0:
		return 0.0
	if not after["intent_owned"] or after["behavior"] == "RETREAT" or after["retreating"]:
		return 0.0
	if record.first_nonretreat_intent_tick < 0:
		record.first_nonretreat_intent_tick = tick
	if after["intent_mode"] != "MOVE":
		return 0.0
	var origin := Vector2(before["x"], before["y"])
	var displacement: Vector2 = Vector2(after["x"], after["y"]) - origin
	var direction: Vector2 = (Vector2(after["destination_x"], after["destination_y"]) - origin).normalized()
	var progress: float = maxf(0.0, displacement.dot(direction))
	record.intended_progress_pixels += progress
	if record.intended_progress_pixels >= 1.0 and record.motion_tick < 0:
		record.motion_tick = tick + 1
	return progress

static func _owned_retreat(snapshot: Dictionary) -> bool:
	return snapshot["intent_owned"] and snapshot["behavior"] == "RETREAT"

func _capture(world: SimulationWorld, actor: AgentHandle, tick: int) -> Dictionary:
	var dense: int = world.store.resolve(actor)
	var context: AgentContext = world.ai.inspect(actor)
	var intent: MotionIntent = world.intents.get_intent(actor, tick)
	var active: bool = world.store.is_active(actor)
	var sighting: LocalObservation
	if context != null and context.threat != null:
		sighting = context.observation_for(context.threat.handle, tick)
	var result: Dictionary = {"wolf": actor.key(), "input_tick": tick, "alive": dense >= 0, "active": active,
		"x": world.store.position_current[dense].x if dense >= 0 else null,
		"y": world.store.position_current[dense].y if dense >= 0 else null,
		"context_present": context != null, "tree_present": context != null and context.detached_tree != null,
		"task": str(context.task_name) if context != null else "NONE",
		"task_token": context.task_token if context != null else -1,
		"retreating": context.retreating if context != null else false,
		"perception_tick": context.last_perception_tick if context != null else -1,
		"decision_tick": context.last_decision_tick if context != null else -1,
		"safe_after_tick": context.safe_after_tick if context != null else -1,
		"threat_reference": context.threat.handle.key() if context != null and context.threat != null else "",
		"threat_valid": sighting != null, "threat_observed_tick": sighting.observed_tick if sighting != null else -1,
		"threat_expires_tick": sighting.expires_tick if sighting != null else -1,
		"threat_source": LocalObservation.Source.keys()[sighting.source] if sighting != null else "NONE",
		"intent_present": intent != null,
		"intent_owned": active and intent != null and context != null and intent.owner_token == context.task_token,
		"intent_token": intent.owner_token if intent != null else -1,
		"intent_expires_tick": intent.expires_tick if intent != null else -1,
		"intent_mode": SimTypes.IntentMode.keys()[intent.mode] if intent != null else "NONE",
		"behavior": SimTypes.Behavior.keys()[intent.behavior] if intent != null else "NONE",
		"intent_target": intent.target.key() if intent != null and intent.target != null else "",
		"destination_x": intent.destination.x if intent != null else null,
		"destination_y": intent.destination.y if intent != null else null}
	result.merge(_risk_geometry(world, actor))
	return result

func _risk_geometry(world: SimulationWorld, actor: AgentHandle) -> Dictionary:
	var dense: int = world.store.resolve(actor)
	var active_dogs: int = 0
	var nearest: AgentHandle
	var nearest_distance: float = INF
	for dog: AgentHandle in _dogs:
		if not world.store.is_active(dog):
			continue
		active_dogs += 1
		if dense < 0:
			continue
		var dog_dense: int = world.store.resolve(dog)
		var distance: float = world.store.position_current[dense].distance_to(world.store.position_current[dog_dense])
		if distance < nearest_distance:
			nearest = dog
			nearest_distance = distance
	return {"active_declared_dogs": active_dogs,
		"nearest_active_dog": nearest.key() if nearest != null else "",
		"nearest_active_dog_distance": nearest_distance if nearest != null else null,
		"risk_geometry": nearest != null and nearest_distance < world.ai.settings.dog_risk_radius}

func report() -> Dictionary:
	var rows: Array[Dictionary] = []
	var boundary_rows: Array[Dictionary] = []
	var alive_boundary: int = 0
	var retreat_boundary: int = 0
	var served: int = 0
	var exited: int = 0
	var effective: int = 0
	var moving: int = 0
	for record: WolfRecord in records:
		var boundary_active: bool = not record.boundary.is_empty() and record.boundary["active"]
		alive_boundary += int(boundary_active)
		retreat_boundary += int(record.retreat_at_boundary)
		served += int(record.first_service_tick >= 0)
		exited += int(record.retreat_at_boundary and record.left_retreat_tick >= 0)
		effective += int(record.first_nonretreat_intent_tick >= 0)
		moving += int(record.motion_tick >= 0)
		if not record.boundary.is_empty():
			boundary_rows.append(record.boundary.duplicate(true))
		rows.append({"wolf": record.actor.key(), "active_at_boundary": boundary_active,
			"retreat_at_boundary": record.retreat_at_boundary,
			"owned_retreat_at_boundary": not record.boundary.is_empty() and _owned_retreat(record.boundary),
			"first_post_service_tick": record.first_service_tick, "first_post_service_usec": record.first_service_usec,
			"first_nonretreat_tree_tick": record.left_retreat_tick,
			"first_effective_nonretreat_intent_tick": record.first_nonretreat_intent_tick,
			"effective_motion_completed_tick": record.motion_tick, "intended_progress_pixels": record.intended_progress_pixels,
			"active_observed_steps": record.active_steps, "post_active_steps": record.post_active_steps,
			"post_service_steps": record.post_service_steps, "post_missing_intent_steps": record.post_missing_intent_steps,
			"post_unowned_intent_steps": record.post_unowned_intent_steps, "death_tick": record.death_tick,
			"terminal_alive": record.terminal.get("alive", false), "terminal_active": record.terminal.get("active", false),
			"terminal_task": record.terminal.get("task", "NONE"), "terminal_behavior": record.terminal.get("behavior", "NONE")})
	return {"withdrawal_mode": mode_name(mode), "withdrawal_intervention_tick": INTERVENTION_TICK,
		"boundary_prepared": boundary_prepared, "boundary_elapsed_usec": boundary_elapsed_usec,
		"control_submitted": boundary_prepared and mode == Mode.REMOVE_DOGS, "control_observed": control_observed,
		"withdrawal_pre299": pre299.duplicate(true), "withdrawal_boundary": boundary_rows,
		"withdrawal_dog_controls": dog_controls.duplicate(true), "withdrawal_records": rows,
		"wolf_steps": steps.duplicate(true), "withdrawal_observer_usec": observer_usec,
		"withdrawal_outcomes": {"declared_wolves": 2, "registered_wolves": records.size(),
			"active_at_boundary": alive_boundary, "retreat_at_boundary": retreat_boundary,
			"already_nonretreat_at_boundary": alive_boundary - retreat_boundary,
			"served_after_boundary": served, "unserved_registered": records.size() - served,
			"retreat_eligible_exited": exited, "retreat_eligible_not_exited": retreat_boundary - exited,
			"effective_nonretreat_intent": effective, "effective_motion_ge_1px": moving,
			"registered_without_effective_motion": records.size() - moving},
		"withdrawal_scope": "Two original full wolf lives, every input240..1199. Input299 pre-AI and completed299 remain; input300 boundary is before intervention, control result is post-stage0. Real BT service requires a present detached tree and a last_decision_tick advance in that step. Boundary retreat denominator includes retreating task state or owned RETREAT, retaining missing intents. Already nonretreat lives are separate. Service, tree exit, valid owned nonRETREAT intent and actual MOVE positive projection>=1px are separate gates; SEARCH can qualify. No90tick UNSAFE hold is imposed on the wolf's THREAT branch. Old dog recovery-after-wolf-removal is inapplicable here. Observer subcost is already included in observer_usec; no performance claim."}
