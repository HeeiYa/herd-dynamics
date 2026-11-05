class_name ProductionForageCohort
extends RefCounted
## Owner-thread evidence for one fixed-cohort experiment, not a spawning policy.
const VERSION: String = "production-forage-fixed-cohort-v1"
const COHORT_SIZE: int = 80
const BACKGROUND_PER_SIDE: int = 460
const MAX_INTRUSION_EVENTS: int = 32
const SPACING: float = 32.0
const DRY_REGION: Rect2 = Rect2(720, 240, 960, 960)
enum Layout { ORIGINAL, FIXED_COHORT80 }

var requested_positions: Array[Vector2] = []
var cohort_handles: Array[AgentHandle] = []
var background_handles: Array[AgentHandle] = []
var initial_cohort: Array[Dictionary] = []
var initial_background: Array[Dictionary] = []
var background_samples: Array[Dictionary] = []
var intrusion_events: Array[Dictionary] = []
var intrusion_observer_usec: int = 0
var background_sample_usec: int = 0
var intrusion_observed_steps: int = 0
var intrusion_life_steps: int = 0
var intrusion_peak: int = 0
var intrusion_unique_lives: int = 0
var first_intrusion_tick: int = -1
var _entered: PackedByteArray = PackedByteArray()
var _last_sample_positions: PackedVector2Array = PackedVector2Array()
var _last_perception_ticks: PackedInt32Array = PackedInt32Array()
var _last_decision_ticks: PackedInt32Array = PackedInt32Array()
var _ever_moved: PackedByteArray = PackedByteArray()
var _ever_perceived: PackedByteArray = PackedByteArray()
var _ever_decided: PackedByteArray = PackedByteArray()

static func from_arguments(arguments: PackedStringArray) -> Layout:
	return Layout.FIXED_COHORT80 if arguments.has("--forage-layout=fixed-cohort80") else Layout.ORIGINAL

static func argument_error(arguments: PackedStringArray, behavior_case: String, total: int, seed_value: int) -> String:
	var found: bool = false
	for argument: String in arguments:
		if not argument.begins_with("--forage-"):
			continue
		if not argument.begins_with("--forage-layout="):
			return "Unknown forage diagnostic option: " + argument
		if found:
			return "Duplicate forage-layout option"
		found = true
		if argument != "--forage-layout=fixed-cohort80":
			return "Unknown forage-layout value: " + argument
		if behavior_case != "forage-migration":
			return "fixed-cohort80 is only valid for forage-migration"
		if total not in [80, 1000] or seed_value != 42:
			return "fixed-cohort80 requires total 80 or 1000 and seed42"
	if found:
		var seen_count: bool = false
		var seen_seed: bool = false
		for argument: String in arguments:
			if argument.begins_with("--sheep="):
				if seen_count or argument not in ["--sheep=80", "--sheep=1000"]:
					return "Fixed-cohort sheep total must be a single exact80/1000 option"
				seen_count = true
			elif argument.begins_with("--seed="):
				if seen_seed or argument != "--seed=42":
					return "Fixed-cohort seed must be a single exact42 option"
				seen_seed = true
	return ""

func prepare(total: int, seed_value: int) -> void:
	assert(requested_positions.is_empty() and total in [80, 1000] and seed_value == 42)
	# Reproduce the original 80-life formula and RNG order before any extra life.
	var random := RandomNumberGenerator.new()
	random.seed = seed_value
	var columns: int = ceili(sqrt(float(COHORT_SIZE)))
	var rows: int = ceili(float(COHORT_SIZE) / columns)
	for index: int in COHORT_SIZE:
		var offset := Vector2(index % columns - (columns - 1) * 0.5, index / columns - (rows - 1) * 0.5) * SPACING
		requested_positions.append(Vector2(1200, 700) + offset + Vector2(random.randf_range(-2, 2), random.randf_range(-2, 2)))
	if total == COHORT_SIZE:
		return
	for origin: Vector2 in [Vector2(56, 220), Vector2(1896, 220)]:
		for index: int in BACKGROUND_PER_SIDE:
			requested_positions.append(origin + Vector2(index % 15, index / 15) * SPACING)

func placement_error(world: SimulationWorld) -> String:
	if requested_positions.size() not in [80, 1000]:
		return "Fixed cohort has an invalid requested population"
	var radius: float = world.config.agent_radius
	var diameter_squared: float = radius * radius * 4.0
	for index: int in requested_positions.size():
		var position: Vector2 = requested_positions[index]
		if not _body_inside_world(position, radius, world.config.world_size):
			return "Fixed-cohort body is outside the declared world"
		if index >= COHORT_SIZE and DRY_REGION.grow(radius).has_point(position):
			return "Background body overlaps the fixed dry region"
		if world.resources.get_effective_amount(world.resources.cell_at(position), world.tick) < ResourceGrid.MIN_GRAZABLE_AMOUNT:
			return "Fixed-cohort placement requires initial edible grass"
		for previous: int in index:
			if position.distance_squared_to(requested_positions[previous]) < diameter_squared:
				return "Fixed-cohort bodies overlap at initialization"
	return ""

static func _body_inside_world(position: Vector2, radius: float, world_size: Vector2) -> bool:
	return (position.is_finite() and is_finite(radius) and radius > 0.0
		and position.x >= radius and position.y >= radius
		and position.x <= world_size.x - radius and position.y <= world_size.y - radius)

func register_lives(world: SimulationWorld) -> String:
	if world.store.count != requested_positions.size():
		return "Fixed-cohort registered population differs from its request"
	for dense: int in world.store.count:
		var actor: AgentHandle = world.store.handle_at(dense)
		if not world.store.is_active(actor) or world.store.species[dense] != SimTypes.Species.SHEEP:
			return "Fixed-cohort registration is not an active sheep"
		if world.store.position_current[dense] != requested_positions[dense]:
			return "Fixed-cohort registration changed a requested coordinate"
		if dense < COHORT_SIZE:
			cohort_handles.append(actor)
			initial_cohort.append(_initial_record(world, actor, dense))
		else:
			background_handles.append(actor)
			initial_background.append(_initial_record(world, actor, dense))
			_last_sample_positions.append(world.store.position_current[dense])
	var count: int = background_handles.size()
	_entered.resize(count)
	_last_perception_ticks.resize(count)
	_last_decision_ticks.resize(count)
	for index: int in count:
		var context: AgentContext = world.ai.inspect(background_handles[index])
		if context == null:
			return "Registered background life has no production AI context"
		_last_perception_ticks[index] = context.last_perception_tick
		_last_decision_ticks[index] = context.last_decision_tick
	_ever_moved.resize(count)
	_ever_perceived.resize(count)
	_ever_decided.resize(count)
	return ""

func _initial_record(world: SimulationWorld, actor: AgentHandle, dense: int) -> Dictionary:
	var position: Vector2 = world.store.position_current[dense]
	return {"handle": actor.key(), "registration_index": dense, "tick": world.tick,
		"position_x": position.x, "position_y": position.y, "hunger": world.store.hunger[dense],
		"velocity_x": world.store.velocity_current[dense].x, "velocity_y": world.store.velocity_current[dense].y,
		"radius": world.store.radius[dense], "species": world.store.species[dense]}

## Observe every input endpoint, including before drought. This is exact for
## these discrete endpoints, not substep contact detection or causal attribution.
func observe_intrusions(world: SimulationWorld, started_usec: int) -> String:
	var started: int = Time.get_ticks_usec()
	var inside: int = 0
	var error: String = ""
	for index: int in background_handles.size():
		var actor: AgentHandle = background_handles[index]
		var dense: int = world.store.resolve(actor)
		if dense < 0 or not world.store.is_active(actor):
			error = "A declared background life became inactive or invalid"
			break
		var position: Vector2 = world.store.position_current[dense]
		if not DRY_REGION.has_point(position):
			continue
		inside += 1
		if _entered[index] != 0:
			continue
		_entered[index] = 1
		intrusion_unique_lives += 1
		if first_intrusion_tick < 0:
			first_intrusion_tick = world.tick
		if intrusion_events.size() < MAX_INTRUSION_EVENTS:
			intrusion_events.append({"handle": actor.key(), "input_tick": world.tick,
				"elapsed_usec": Time.get_ticks_usec() - started_usec, "x": position.x, "y": position.y})
	intrusion_observed_steps += 1
	intrusion_life_steps += inside
	intrusion_peak = maxi(intrusion_peak, inside)
	intrusion_observer_usec += Time.get_ticks_usec() - started
	return error

func sample_background(world: SimulationWorld, started_usec: int) -> String:
	var started: int = Time.get_ticks_usec()
	var owned: int = 0
	var moved: int = 0
	var perceived: int = 0
	var decided: int = 0
	var error: String = ""
	for index: int in background_handles.size():
		var actor: AgentHandle = background_handles[index]
		var dense: int = world.store.resolve(actor)
		if dense < 0 or not world.store.is_active(actor):
			error = "Background quality sample lost a declared active life"
			break
		var context: AgentContext = world.ai.inspect(actor)
		if context == null:
			error = "Background quality sample lost its production AI context"
			break
		var intent: MotionIntent = world.intents.get_intent(actor, world.tick - 1)
		owned += int(intent != null and intent.owner_token == context.task_token)
		var position: Vector2 = world.store.position_current[dense]
		if position.distance_to(_last_sample_positions[index]) >= 1.0:
			moved += 1
			_ever_moved[index] = 1
		if context.last_perception_tick > _last_perception_ticks[index]:
			perceived += 1
			_ever_perceived[index] = 1
		if context.last_decision_tick > _last_decision_ticks[index]:
			decided += 1
			_ever_decided[index] = 1
		_last_sample_positions[index] = position
		_last_perception_ticks[index] = context.last_perception_tick
		_last_decision_ticks[index] = context.last_decision_tick
	background_samples.append({"completed_tick": world.tick, "elapsed_usec": Time.get_ticks_usec() - started_usec,
		"cohort_size": COHORT_SIZE, "background_size": background_handles.size(), "active": background_handles.size() if error.is_empty() else -1,
		"owned_intents": owned, "missing_or_unowned": background_handles.size() - owned,
		"moved_net_ge_1px_since_sample": moved, "perception_advanced_since_sample": perceived,
		"decision_advanced_since_sample": decided})
	background_sample_usec += Time.get_ticks_usec() - started
	return error

func report() -> Dictionary:
	return {"layout": "fixed-cohort80", "cohort_size": COHORT_SIZE, "background_size": background_handles.size(),
		"initial_cohort": initial_cohort.duplicate(true), "initial_background": initial_background.duplicate(true),
		"background_quality": background_samples.duplicate(true),
		"background_intrusions": intrusion_events.duplicate(true),
		"background_activity": {"ever_moved_net_ge_1px": _ever_moved.count(1),
			"ever_perception_advanced": _ever_perceived.count(1), "ever_decision_advanced": _ever_decided.count(1)},
		"background_intrusion": {"observed_steps": intrusion_observed_steps, "first_input_tick": first_intrusion_tick,
			"unique_lives": intrusion_unique_lives, "life_steps": intrusion_life_steps, "peak": intrusion_peak,
			"events_retained": intrusion_events.size(), "events_omitted": intrusion_unique_lives - intrusion_events.size(),
			"scope": "Every post-stage0 input endpoint 0..1199; body centers in the fixed dry rectangle. Not continuous contact or proof of causal interference; cohort outside the rectangle can also meet background sheep."},
		"intrusion_observer_usec": intrusion_observer_usec, "background_sample_usec": background_sample_usec,
		"observer_cost_scope": "Intrusion and background sample times are subsets of total observer_usec; do not add them to it. Sampling is every60 simulation ticks, not every wall-clock second.",
		"background_activity_scope": "Every60 completed ticks, all declared background lives: real net displacement and production AI clocks/owned intents. Zero net movement can be legal grazing. No background life enters the migration denominator."}
