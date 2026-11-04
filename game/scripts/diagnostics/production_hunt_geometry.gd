class_name ProductionHuntGeometry
extends RefCounted
## Fixed external stimuli for the hunt protocol, never instructions to an AI.
enum Variant { INVALID = -1, BASELINE = 0, NORTH = 1, OBLIQUE = 2 }
const BASELINE_OFFSETS: Array[Vector2] = [Vector2(-110, 0), Vector2(-100, -50), Vector2(-100, 50)]
const OBLIQUE_OFFSETS: Array[Vector2] = [Vector2(-110, 0), Vector2(-95, -70), Vector2(-100, 45)]
const VERSION: String = "production-hunt-geometry-v1"

static func parse_variant(label: String) -> Variant:
	match label:
		"baseline":
			return Variant.BASELINE
		"north":
			return Variant.NORTH
		"oblique":
			return Variant.OBLIQUE
	return Variant.INVALID

static func variant_name(variant: Variant) -> String:
	match variant:
		Variant.BASELINE:
			return "baseline"
		Variant.NORTH:
			return "north"
		Variant.OBLIQUE:
			return "oblique"
	return "invalid"

static func from_arguments(arguments: PackedStringArray) -> Variant:
	for argument: String in arguments:
		if argument.begins_with("--hunt-geometry="):
			return parse_variant(argument.trim_prefix("--hunt-geometry="))
	return Variant.BASELINE

static func argument_error(arguments: PackedStringArray, behavior_case: String, sheep_count: int) -> String:
	var selections: int = 0
	var variant: Variant = Variant.BASELINE
	for argument: String in arguments:
		if not argument.begins_with("--hunt-"):
			continue
		if not argument.begins_with("--hunt-geometry="):
			return "Unknown hunt option: " + argument
		selections += 1
		variant = parse_variant(argument.trim_prefix("--hunt-geometry="))
	if selections == 0:
		return ""
	if selections != 1:
		return "Specify --hunt-geometry exactly once."
	if behavior_case != "hunt-cooperation":
		return "--hunt-geometry only belongs to hunt-cooperation."
	if variant == Variant.INVALID:
		return "Unknown hunt geometry; expected baseline, north or oblique."
	if variant != Variant.BASELINE and sheep_count != 80:
		return "Changed hunt geometries require exactly 80 sheep."
	return ""

static func offsets(variant: Variant) -> Array[Vector2]:
	var result: Array[Vector2] = []
	match variant:
		Variant.BASELINE:
			# Preserve the exact old constants; a zero-angle rotation is unnecessary.
			result.assign(BASELINE_OFFSETS)
		Variant.NORTH:
			for offset: Vector2 in BASELINE_OFFSETS:
				result.append(Vector2(-offset.y, offset.x))
		Variant.OBLIQUE:
			for offset: Vector2 in OBLIQUE_OFFSETS:
				result.append(offset.rotated(PI * 0.25))
	return result

static func body_inside_world(position: Vector2, radius: float, world_size: Vector2) -> bool:
	return position.is_finite() and world_size.is_finite() and is_finite(radius) and radius > 0.0 \
		and position.x >= radius and position.y >= radius \
		and position.x <= world_size.x - radius and position.y <= world_size.y - radius

static func placement_error(target: Vector2, hunters: Array[Vector2], radius: float, world_size: Vector2, perception_radius: float, cooperation_radius: float) -> String:
	if hunters.size() != 3:
		return "The hunt stimulus requires exactly three positions."
	if not body_inside_world(target, radius, world_size):
		return "The declared prey body is outside the world."
	for index: int in hunters.size():
		var actor: Vector2 = hunters[index]
		if not body_inside_world(actor, radius, world_size):
			return "A hunter body would cross the world boundary."
		if actor.distance_to(target) > perception_radius:
			return "A hunter lacks the declared initial perception opportunity."
		if actor.distance_to(target) < radius * 2.0:
			return "A hunter would overlap the declared prey at registration."
		var has_cooperative_neighbor: bool = false
		for other_index: int in hunters.size():
			if index == other_index:
				continue
			var distance: float = actor.distance_to(hunters[other_index])
			if distance < radius * 2.0:
				return "Two hunters would overlap at registration."
			has_cooperative_neighbor = has_cooperative_neighbor or distance <= cooperation_radius
		if not has_cooperative_neighbor:
			return "A hunter lacks a cooperative neighbor at registration."
	return ""
