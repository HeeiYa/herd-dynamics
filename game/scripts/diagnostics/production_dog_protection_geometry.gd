class_name ProductionDogProtectionGeometry
extends RefCounted
## Declared external stimuli only. Never searches for a passing placement or
## supplies any live position, target, reservation or result to an animal's AI.
const VERSION: String = "production-dog-protection-v1"
const ANCHOR_VERSION: String = "production-dog-protection-v2"
const COHORT_SIZE: int = 80
const DOG_COUNT: int = 4
const GROUP_CENTERS: Array[Vector2] = [Vector2(600, 700), Vector2(1800, 700)]
const SPACING: float = 32.0
const WOLF_OFFSET: float = 140.0
const OBLIQUE_ANGLE: float = PI / 9.0
const BACKGROUND_EXCLUSION_RADIUS: float = 440.0
enum Variant { NORMAL, OBLIQUE, INVALID, ANCHOR_NORMAL, ANCHOR_OBLIQUE }

var positions: Array[Vector2] = []
var species: PackedInt32Array = PackedInt32Array()

static func from_arguments(arguments: PackedStringArray) -> Variant:
	for argument: String in arguments:
		if argument.begins_with("--dog-geometry="):
			match argument.trim_prefix("--dog-geometry="):
				"normal":
					return Variant.NORMAL
				"oblique":
					return Variant.OBLIQUE
				"anchor-normal":
					return Variant.ANCHOR_NORMAL
				"anchor-oblique":
					return Variant.ANCHOR_OBLIQUE
				_:
					return Variant.INVALID
	return Variant.NORMAL

static func variant_name(variant: Variant) -> String:
	match variant:
		Variant.NORMAL:
			return "normal"
		Variant.OBLIQUE:
			return "oblique"
		Variant.ANCHOR_NORMAL:
			return "anchor-normal"
		Variant.ANCHOR_OBLIQUE:
			return "anchor-oblique"
		_:
			return "invalid"

static func is_anchor_variant(variant: Variant) -> bool:
	return variant in [Variant.ANCHOR_NORMAL, Variant.ANCHOR_OBLIQUE]

static func protocol_version(variant: Variant) -> String:
	return ANCHOR_VERSION if is_anchor_variant(variant) else VERSION

static func first_runs() -> Array[Dictionary]:
	return [
		{"sheep": 80, "seed": 42, "geometry": "normal"},
		{"sheep": 80, "seed": 42, "geometry": "oblique"},
		{"sheep": 80, "seed": 43, "geometry": "oblique"},
		{"sheep": 80, "seed": 44, "geometry": "oblique"},
		{"sheep": 1000, "seed": 42, "geometry": "oblique"},
	]

static func anchor_runs() -> Array[Dictionary]:
	return [
		{"sheep": 80, "seed": 42, "geometry": "anchor-normal"},
		{"sheep": 80, "seed": 42, "geometry": "anchor-oblique"},
		{"sheep": 80, "seed": 43, "geometry": "anchor-oblique"},
		{"sheep": 80, "seed": 44, "geometry": "anchor-oblique"},
		{"sheep": 1000, "seed": 42, "geometry": "anchor-oblique"},
	]

static func argument_error(arguments: PackedStringArray, behavior_case: String, total: int, seed_value: int) -> String:
	var has_geometry: bool = false
	for argument: String in arguments:
		if not argument.begins_with("--dog-"):
			continue
		if not argument.begins_with("--dog-geometry=") or has_geometry:
			return "Unknown or duplicate dog diagnostic option: " + argument
		has_geometry = true
		if behavior_case != "dog-protection":
			return "dog-geometry is only valid for dog-protection"
	if behavior_case != "dog-protection":
		return ""
	var variant: Variant = from_arguments(arguments)
	var allowed: bool = false
	var declared_runs: Array[Dictionary] = first_runs()
	declared_runs.append_array(anchor_runs())
	for run: Dictionary in declared_runs:
		if total == run["sheep"] and seed_value == run["seed"] and variant_name(variant) == run["geometry"]:
			allowed = true
	if not allowed:
		return "Dog protection accepts only the two declared five-run population/seed/geometry matrices"
	var has_count: bool = false
	var has_seed: bool = false
	for argument: String in arguments:
		if argument.begins_with("--sheep="):
			if has_count or argument != "--sheep=" + str(total):
				return "Dog protection requires a single exact sheep count"
			has_count = true
		elif argument.begins_with("--seed="):
			if has_seed or argument != "--seed=" + str(seed_value):
				return "Dog protection requires a single exact seed"
			has_seed = true
	return ""

func prepare(total: int, seed_value: int) -> void:
	assert(positions.is_empty() and total in [80, 1000])
	var random := RandomNumberGenerator.new()
	random.seed = seed_value
	# The first 80 sheep and four dogs retain identical creation order and RNG
	# prefixes when 920 real, freely moving sheep are added afterwards.
	for center: Vector2 in GROUP_CENTERS:
		for index: int in 40:
			var offset := Vector2(index % 7 - 3.0, index / 7 - 2.5) * SPACING
			var jitter := Vector2(random.randf_range(-2.0, 2.0), random.randf_range(-2.0, 2.0))
			_append(SimTypes.Species.SHEEP, center + offset + jitter)
	for center: Vector2 in GROUP_CENTERS:
		_append(SimTypes.Species.DOG, center + Vector2(-30, -140))
		_append(SimTypes.Species.DOG, center + Vector2(30, -140))
	var remaining: int = total - COHORT_SIZE
	# Alternate top/bottom rows, then left/right columns. This deterministic
	# layout is not dependent on whether a later stimulus will pass preflight.
	for row: int in 42:
		var actual_row: int = row / 2 if row % 2 == 0 else 41 - row / 2
		for column: int in 74:
			if remaining == 0:
				return
			var actual_column: int = column / 2 if column % 2 == 0 else 73 - column / 2
			var position := Vector2(32 + actual_column * SPACING, 32 + actual_row * SPACING)
			if inside_foreground_region(position):
				continue
			_append(SimTypes.Species.SHEEP, position)
			remaining -= 1
	assert(remaining == 0, "Declared background layout has insufficient capacity")

func _append(kind: int, position: Vector2) -> void:
	species.append(kind)
	positions.append(position)

static func inside_foreground_region(position: Vector2) -> bool:
	for center: Vector2 in GROUP_CENTERS:
		if position.distance_to(center) < BACKGROUND_EXCLUSION_RADIUS:
			return true
	return false

func initial_error(radius: float, world_size: Vector2) -> String:
	if positions.size() not in [84, 1004] or species.size() != positions.size():
		return "Initial roster does not contain the declared sheep and four dogs"
	for index: int in positions.size():
		if not ProductionHuntGeometry.body_inside_world(positions[index], radius, world_size):
			return "An initial body crosses the world boundary"
		for previous: int in index:
			if positions[index].distance_to(positions[previous]) < radius * 2.0:
				return "Initial bodies overlap"
	return ""

static func wolf_position(first_dog: Vector2, second_dog: Vector2, variant: Variant) -> Vector2:
	var axis: Vector2 = second_dog - first_dog
	if axis.length_squared() == 0.0:
		axis = Vector2.RIGHT
	var normal := Vector2(axis.y, -axis.x).normalized()
	if variant == Variant.OBLIQUE:
		normal = normal.rotated(OBLIQUE_ANGLE)
	return (first_dog + second_dog) * 0.5 + normal * WOLF_OFFSET

static func anchor_wolf_position(subject_position: Vector2, observed_anchor: Vector2, variant: Variant) -> Vector2:
	assert(is_anchor_variant(variant))
	var direction: Vector2 = observed_anchor - subject_position
	if direction.length_squared() == 0.0:
		direction = Vector2.UP
	else:
		direction = direction.normalized()
	if variant == Variant.ANCHOR_OBLIQUE:
		direction = direction.rotated(OBLIQUE_ANGLE)
	return subject_position + direction * WOLF_OFFSET

static func opportunity_error(wolf: Vector2, dogs: Array[Vector2], anchors: Array[Vector2], radius: float, world_size: Vector2, risk_radius: float, perception_radius: float, protection_radius: float) -> String:
	if dogs.size() != 2 or anchors.size() != 2:
		return "Each stimulus requires exactly two registered dogs and their valid anchors"
	if not ProductionHuntGeometry.body_inside_world(wolf, radius, world_size):
		return "A requested wolf body crosses the world boundary"
	for index: int in dogs.size():
		var error: String = _reference_opportunity_error(wolf, dogs[index], anchors[index], risk_radius, perception_radius, protection_radius)
		if not error.is_empty():
			return error
	return ""

static func subject_opportunity_error(wolf: Vector2, subject_position: Vector2, observed_anchor: Vector2, radius: float, world_size: Vector2, risk_radius: float, perception_radius: float, protection_radius: float) -> String:
	if not ProductionHuntGeometry.body_inside_world(wolf, radius, world_size):
		return "A requested wolf body crosses the world boundary"
	return _reference_opportunity_error(wolf, subject_position, observed_anchor, risk_radius, perception_radius, protection_radius)

static func _reference_opportunity_error(wolf: Vector2, dog: Vector2, anchor: Vector2, risk_radius: float, perception_radius: float, protection_radius: float) -> String:
	if not dog.is_finite() or not anchor.is_finite():
		return "A stimulus reference is nonfinite"
	var distance: float = dog.distance_to(wolf)
	if distance <= risk_radius or distance > perception_radius:
		return "A requested wolf is already inside dog-risk range or outside dog perception"
	if anchor.distance_to(wolf) >= protection_radius:
		return "A requested wolf is outside a dog's observed protection radius"
	return ""
