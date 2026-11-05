class_name ProductionHuntCohort
extends RefCounted
## Fixed diagnostic population and copied evidence, never an AI/spawning policy.
enum Layout { ORIGINAL, FIXED_COHORT80 }
const VERSION: String = "production-hunt-fixed-cohort-v1"
const COHORT_SIZE: int = 80
const SPACING: float = 32.0
const PREY_ORIGIN: Vector2 = Vector2(600, 700)
const FLOCK_ORIGIN: Vector2 = Vector2(1800, 700)
const PREY_CLEARANCE: float = 650.0
const FLOCK_CLEARANCE: float = 300.0
const GRID_COLUMNS: int = 74
const GRID_ROWS: int = 42

var requested_positions: Array[Vector2] = []
var cohort_handles: Array[AgentHandle] = []
var background_handles: Array[AgentHandle] = []
var initial_cohort: Array[Dictionary] = []
var initial_background: Array[Dictionary] = []
var background_samples: Array[Dictionary] = []
var hunter_preflight: Array[Dictionary] = []
var fixture_error_details: Dictionary = {}
var initial_pairs_checked: int = 0
var background_sample_usec: int = 0
var _last_positions: PackedVector2Array = PackedVector2Array()
var _last_perception_ticks: PackedInt32Array = PackedInt32Array()
var _last_decision_ticks: PackedInt32Array = PackedInt32Array()

static func from_arguments(arguments: PackedStringArray) -> Layout:
	if arguments.has("--hunt-layout=fixed-cohort80"):
		return Layout.FIXED_COHORT80
	return Layout.ORIGINAL

static func argument_error(arguments: PackedStringArray, behavior_case: String, total: int, seed_value: int) -> String:
	var found: bool = false
	for argument: String in arguments:
		if not argument.begins_with("--hunt-layout"):
			continue
		if found or argument != "--hunt-layout=fixed-cohort80":
			return "Specify --hunt-layout=fixed-cohort80 once, without an alternate value."
		found = true
	if not found:
		return ""
	if behavior_case != "hunt-cooperation":
		return "The fixed hunt cohort only belongs to hunt-cooperation."
	if total not in [80, 1000] or seed_value != 42:
		return "The fixed hunt cohort requires 80 or 1000 sheep and seed42."
	var geometry: ProductionHuntGeometry.Variant = ProductionHuntGeometry.from_arguments(arguments)
	if geometry not in [ProductionHuntGeometry.Variant.NORTH, ProductionHuntGeometry.Variant.OBLIQUE]:
		return "The fixed hunt cohort requires explicit north or oblique geometry."
	var seen_count: bool = false
	var seen_seed: bool = false
	for argument: String in arguments:
		if argument.begins_with("--sheep="):
			if seen_count or argument not in ["--sheep=80", "--sheep=1000"]:
				return "Fixed hunt population must be a single exact80/1000 option."
			seen_count = true
		elif argument.begins_with("--seed="):
			if seen_seed or argument != "--seed=42":
				return "Fixed hunt seed must be a single exact42 option."
			seen_seed = true
	return ""

static func original_positions(total: int, seed_value: int) -> Array[Vector2]:
	# Keep the original formula and random call order, including integer rows.
	var positions: Array[Vector2] = [PREY_ORIGIN]
	var random := RandomNumberGenerator.new()
	random.seed = seed_value
	var count: int = total - 1
	var columns: int = ceili(sqrt(float(count)))
	var rows: int = ceili(float(count) / columns)
	for index: int in count:
		var offset := Vector2(index % columns - (columns - 1) * 0.5, index / columns - (rows - 1) * 0.5) * SPACING
		positions.append(FLOCK_ORIGIN + offset + Vector2(random.randf_range(-2, 2), random.randf_range(-2, 2)))
	return positions

func prepare(total: int, seed_value: int) -> void:
	assert(requested_positions.is_empty() and total in [80, 1000] and seed_value == 42)
	requested_positions = original_positions(COHORT_SIZE, seed_value)
	if total == COHORT_SIZE:
		return
	# The complete order is fixed before simulation; never retry a failed runtime
	# stimulus by searching these cells or moving a background life elsewhere.
	for row_order: int in GRID_ROWS:
		var row: int = _alternating_edge_index(row_order, GRID_ROWS)
		for column_order: int in GRID_COLUMNS:
			var column: int = _alternating_edge_index(column_order, GRID_COLUMNS)
			var position := Vector2(column + 1, row + 1) * SPACING
			if position.distance_to(PREY_ORIGIN) < PREY_CLEARANCE or position.distance_to(FLOCK_ORIGIN) < FLOCK_CLEARANCE:
				continue
			requested_positions.append(position)
			if requested_positions.size() == total:
				return
	assert(false, "The declared background grid cannot supply the fixed population")

static func _alternating_edge_index(order: int, size: int) -> int:
	if order % 2 == 0:
		return order / 2
	return size - 1 - order / 2

func placement_error(world: SimulationWorld) -> String:
	if requested_positions.size() not in [80, 1000]:
		return "Fixed hunt cohort has an invalid population."
	var radius: float = world.config.agent_radius
	for index: int in requested_positions.size():
		var position: Vector2 = requested_positions[index]
		if not ProductionHuntGeometry.body_inside_world(position, radius, world.config.world_size):
			fixture_error_details = {"phase": "initial", "index": index, "position": [position.x, position.y], "radius": radius}
			return "An initial fixed-cohort body crosses the world boundary."
		for previous: int in index:
			initial_pairs_checked += 1
			var distance: float = position.distance_to(requested_positions[previous])
			if distance < radius * 2.0:
				fixture_error_details = {"phase": "initial", "index": index, "other_index": previous,
					"position": [position.x, position.y], "other_position": [requested_positions[previous].x, requested_positions[previous].y],
					"radius": radius, "distance": distance, "required_distance": radius * 2.0}
				return "Initial fixed-cohort bodies overlap."
	return ""

func register_lives(world: SimulationWorld) -> String:
	if world.store.count != requested_positions.size():
		return "Fixed hunt cohort registration count differs from its request."
	for dense: int in world.store.count:
		var actor: AgentHandle = world.store.handle_at(dense)
		if not world.store.is_active(actor) or world.store.species[dense] != SimTypes.Species.SHEEP:
			return "A fixed hunt cohort registration is not an active sheep."
		if world.store.position_current[dense] != requested_positions[dense]:
			fixture_error_details = {"phase": "registration", "index": dense, "handle": actor.key(),
				"requested": [requested_positions[dense].x, requested_positions[dense].y],
				"actual": [world.store.position_current[dense].x, world.store.position_current[dense].y]}
			return "Fixed hunt cohort registration changed a requested coordinate."
		var context: AgentContext = world.ai.inspect(actor)
		if context == null:
			return "A fixed hunt cohort life has no production AI context."
		if dense < COHORT_SIZE:
			cohort_handles.append(actor)
			initial_cohort.append(_life_record(world, actor, dense))
		else:
			background_handles.append(actor)
			initial_background.append(_life_record(world, actor, dense))
			_last_positions.append(world.store.position_current[dense])
			_last_perception_ticks.append(context.last_perception_tick)
			_last_decision_ticks.append(context.last_decision_tick)
	return ""

func hunter_placement_error(world: SimulationWorld, positions: Array[Vector2]) -> String:
	var error: String = ""
	# Record each candidate's nearest real active body even on failure. Validation
	# is one atomic preflight of all three; no candidate is queued here.
	for index: int in positions.size():
		var position: Vector2 = positions[index]
		var nearest: Dictionary = {}
		var minimum_clearance: float = INF
		var active_checked: int = 0
		for dense: int in world.store.count:
			var blocker: AgentHandle = world.store.handle_at(dense)
			if not world.store.is_active(blocker):
				continue
			active_checked += 1
			var blocker_position: Vector2 = world.store.position_current[dense]
			var distance: float = position.distance_to(blocker_position)
			var required_distance: float = world.config.agent_radius + world.store.radius[dense]
			var clearance: float = distance - required_distance
			if clearance < minimum_clearance:
				minimum_clearance = clearance
				nearest = {"blocker": blocker.key(), "blocker_x": blocker_position.x, "blocker_y": blocker_position.y,
					"blocker_radius": world.store.radius[dense], "distance": distance, "required_distance": required_distance}
		var row: Dictionary = {"input_tick": world.tick, "hunter_index": index, "hunter_x": position.x, "hunter_y": position.y,
			"hunter_radius": world.config.agent_radius, "active_bodies_checked": active_checked,
			"minimum_body_clearance": minimum_clearance, "body_clear": minimum_clearance >= 0.0}
		row.merge(nearest)
		hunter_preflight.append(row)
		if minimum_clearance < 0.0 and error.is_empty():
			error = "A declared hunter would overlap an actual active body."
			fixture_error_details = row.duplicate(true)
	return error

func sample_background(world: SimulationWorld, started_usec: int) -> void:
	var started: int = Time.get_ticks_usec()
	var active: int = 0
	var alive: int = 0
	var valid_intents: int = 0
	var owned_intents: int = 0
	var moved: int = 0
	var perceived: int = 0
	var decided: int = 0
	var contexts_missing: int = 0
	var prey_region: int = 0
	var flock_region: int = 0
	for index: int in background_handles.size():
		var actor: AgentHandle = background_handles[index]
		var dense: int = world.store.resolve(actor)
		alive += int(dense >= 0)
		if dense < 0 or not world.store.is_active(actor):
			continue
		active += 1
		var position: Vector2 = world.store.position_current[dense]
		moved += int(position.distance_to(_last_positions[index]) >= 1.0)
		_last_positions[index] = position
		prey_region += int(position.distance_to(PREY_ORIGIN) < PREY_CLEARANCE)
		flock_region += int(position.distance_to(FLOCK_ORIGIN) < FLOCK_CLEARANCE)
		var intent: MotionIntent = world.intents.get_intent(actor, world.tick - 1)
		valid_intents += int(intent != null)
		var context: AgentContext = world.ai.inspect(actor)
		if context == null:
			contexts_missing += 1
			continue
		owned_intents += int(intent != null and intent.owner_token == context.task_token)
		perceived += int(context.last_perception_tick > _last_perception_ticks[index])
		decided += int(context.last_decision_tick > _last_decision_ticks[index])
		_last_perception_ticks[index] = context.last_perception_tick
		_last_decision_ticks[index] = context.last_decision_tick
	background_samples.append({"completed_tick": world.tick, "intent_tick": world.tick - 1,
		"elapsed_usec": Time.get_ticks_usec() - started_usec, "registered_background": background_handles.size(),
		"alive": alive, "active": active, "removed_or_dead": background_handles.size() - alive,
		"valid_intents": valid_intents, "missing_intents": active - valid_intents, "owned_intents": owned_intents,
		"contexts_missing": contexts_missing, "moved_net_ge_1px_since_sample": moved,
		"perception_advanced_since_sample": perceived, "decision_advanced_since_sample": decided,
		"inside_initial_prey_region": prey_region, "inside_initial_flock_region": flock_region})
	background_sample_usec += Time.get_ticks_usec() - started

func _life_record(world: SimulationWorld, actor: AgentHandle, registration_index: int) -> Dictionary:
	var dense: int = world.store.resolve(actor)
	var row: Dictionary = {"handle": actor.key(), "registration_index": registration_index, "tick": world.tick,
		"alive": dense >= 0, "active": world.store.is_active(actor), "position_x": null, "position_y": null,
		"velocity_x": null, "velocity_y": null, "facing_x": null, "facing_y": null,
		"hunger": null, "radius": null, "species": null}
	if dense >= 0:
		row["position_x"] = world.store.position_current[dense].x
		row["position_y"] = world.store.position_current[dense].y
		row["velocity_x"] = world.store.velocity_current[dense].x
		row["velocity_y"] = world.store.velocity_current[dense].y
		row["facing_x"] = world.store.facing[dense].x
		row["facing_y"] = world.store.facing[dense].y
		row["hunger"] = world.store.hunger[dense]
		row["radius"] = world.store.radius[dense]
		row["species"] = world.store.species[dense]
	return row

func report(world: SimulationWorld) -> Dictionary:
	var terminal: Array[Dictionary] = []
	for index: int in cohort_handles.size():
		terminal.append(_life_record(world, cohort_handles[index], index))
	for index: int in background_handles.size():
		terminal.append(_life_record(world, background_handles[index], COHORT_SIZE + index))
	var requested: Array[Array] = []
	for position: Vector2 in requested_positions:
		requested.append([position.x, position.y])
	return {"layout": "fixed-cohort80", "layout_version": VERSION, "cohort_size": COHORT_SIZE,
		"registered_cohort": cohort_handles.size(), "background_size": background_handles.size(),
		"requested_initial_positions": requested, "initial_pairs_checked": initial_pairs_checked,
		"initial_cohort": initial_cohort.duplicate(true), "initial_background": initial_background.duplicate(true),
		"sheep_terminal": terminal, "hunter_body_preflight": hunter_preflight.duplicate(true),
		"fixture_error_details": fixture_error_details.duplicate(true), "background_quality": background_samples.duplicate(true),
		"background_sample_usec": background_sample_usec,
		"background_scope": "Fixed registered lives, sampled every60 completed ticks. Full-identity deaths/held lives remain in their denominator; replacements cannot inherit it. Activity clocks and valid/owned intents are separate. Region counts are sampled body centers inside the initial650/300px circles, not continuous absence or causal interference. Net displacement is not distance travelled. Background is ordinary production AI/resource/motion, outside the three-hunter role denominator.",
		"observer_cost_scope": "Background sampling and cohort_setup_usec are subsets of observer_usec, not additional costs. cohort_report_usec is report construction after the fixed-step window, recorded separately. No observer timing is a capacity benchmark."}
