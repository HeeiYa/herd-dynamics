class_name AnimationCatalog
extends RefCounted
## JSON is a build boundary. Runtime uses the action enum and immutable typed clips.

enum Action {
	SHEEP_IDLE, SHEEP_WALK, SHEEP_GRAZE, SHEEP_ALERT, SHEEP_STARTLE,
	SHEEP_FLEE, SHEEP_RECOVER, SHEEP_CAPTURED,
	WOLF_OBSERVE, WOLF_SEARCH, WOLF_STALK, WOLF_CHASE, WOLF_POUNCE,
	WOLF_BITE, WOLF_RETREAT, WOLF_FEED,
	DOG_GUARD_IDLE, DOG_PATROL, DOG_INTERCEPT, DOG_DETECT, DOG_BARK,
	DOG_PRESSURE, DOG_RELAX,
}
const ACTION_NAMES: Array[String] = [
	"sheep/idle", "sheep/walk", "sheep/graze", "sheep/alert", "sheep/startle",
	"sheep/flee", "sheep/recover", "sheep/captured",
	"wolf/observe", "wolf/search", "wolf/stalk", "wolf/chase", "wolf/pounce",
	"wolf/bite", "wolf/retreat", "wolf/feed",
	"shepherd_dog/guard_idle", "shepherd_dog/patrol", "shepherd_dog/intercept",
	"shepherd_dog/detect", "shepherd_dog/bark", "shepherd_dog/pressure", "shepherd_dog/relax",
]
const DIRECTIONS: Array[String] = ["e", "se", "s", "sw", "w", "nw", "n", "ne"]

class Clip extends RefCounted:
	var rectangles: Array[Rect2] = []
	var cumulative_ms: PackedInt32Array = PackedInt32Array()
	var duration_ms: int = 0
	var loop: bool = false
	var random_phase: bool = false
	var pivot: Vector2 = Vector2.ZERO
	var uniform_frame_size: bool = true

	func frame_at(elapsed_ms: float) -> Rect2:
		var local_ms: float = maxf(elapsed_ms, 0.0)
		if loop:
			local_ms = fmod(local_ms, duration_ms)
		else:
			local_ms = minf(local_ms, duration_ms - 0.001)
		for index: int in cumulative_ms.size():
			if local_ms < cumulative_ms[index]:
				return rectangles[index]
		return rectangles.back()

## Reused main-thread scratch. Resolving a cue never allocates per body/frame.
class VisualSample extends RefCounted:
	var action: int
	var elapsed_ms: float

var texture: Texture2D
var clips: Array[Clip] = []

func load_assets() -> void:
	var source: String = FileAccess.get_file_as_string("res://assets/animals.json")
	var parsed: Variant = JSON.parse_string(source)
	assert(parsed is Dictionary, "Runtime atlas metadata is missing or invalid; run tools/build_runtime_atlas.py")
	var metadata: Dictionary = parsed
	assert(int(metadata["schema_version"]) == 1)
	assert(metadata["actions"] == ACTION_NAMES, "Runtime action order differs from AnimationCatalog")
	assert(metadata["directions"] == DIRECTIONS)
	texture = load(String(metadata["atlas"])) as Texture2D
	assert(texture != null)
	clips.clear()
	for raw: Dictionary in metadata["clips"]:
		var clip := Clip.new()
		clip.loop = bool(raw["loop"])
		clip.random_phase = bool(raw["phase_randomization"])
		clip.pivot = Vector2(float(raw["pivot"][0]), float(raw["pivot"][1]))
		for duration: int in raw["durations_ms"]:
			clip.duration_ms += duration
			clip.cumulative_ms.append(clip.duration_ms)
		for rectangle: Array in raw["rectangles"]:
			clip.rectangles.append(Rect2(float(rectangle[0]), float(rectangle[1]), float(rectangle[2]), float(rectangle[3])))
		assert(clip.rectangles.size() == clip.cumulative_ms.size())
		for rectangle: Rect2 in clip.rectangles:
			clip.uniform_frame_size = clip.uniform_frame_size and rectangle.size == clip.rectangles[0].size
		clips.append(clip)
	assert(clips.size() == ACTION_NAMES.size() * DIRECTIONS.size())

func get_clip(action: int, direction: int) -> Clip:
	return clips[action * DIRECTIONS.size() + direction]

## A cue temporarily covers a continuing base clock. Even a looping authored
## clip gets only one duration here; skipped windows are never replayed.
func resolve_visual(sample: VisualSample, action: int, direction: int, elapsed_ms: float, cue_action: int, cue_elapsed_ms: float) -> void:
	sample.action = action
	sample.elapsed_ms = elapsed_ms
	if cue_action >= 0 and cue_elapsed_ms >= 0.0 and cue_elapsed_ms < get_clip(cue_action, direction).duration_ms:
		sample.action = cue_action
		sample.elapsed_ms = cue_elapsed_ms

## Only published, still-valid intent edges are visual evidence. The caller
## supplies an existing life; birth, missing intent and token renewal are not edges.
static func cue_for(species: int, previous_behavior: int, behavior: int, previous_action: int, action: int, moving: bool) -> int:
	match species:
		SimTypes.Species.SHEEP:
			if behavior == SimTypes.Behavior.FLEE and previous_behavior != SimTypes.Behavior.FLEE:
				return Action.SHEEP_STARTLE
			if previous_behavior == SimTypes.Behavior.FLEE and behavior in [SimTypes.Behavior.IDLE, SimTypes.Behavior.GRAZE] and not moving:
				return Action.SHEEP_RECOVER
		SimTypes.Species.DOG:
			var was_intercepting: bool = previous_behavior == SimTypes.Behavior.INTERCEPT or previous_action == Action.DOG_PRESSURE
			var intercepting: bool = behavior == SimTypes.Behavior.INTERCEPT or action == Action.DOG_PRESSURE
			if intercepting and not was_intercepting:
				return Action.DOG_BARK if action == Action.DOG_PRESSURE and not moving else Action.DOG_DETECT
			if previous_behavior in [SimTypes.Behavior.INTERCEPT, SimTypes.Behavior.RETURN] and behavior == SimTypes.Behavior.GUARD and not moving:
				return Action.DOG_RELAX
	return -1

static func direction_for(facing: Vector2, previous: int) -> int:
	if facing.length_squared() < 0.01:
		return previous
	# Reuse the angle for hysteresis and quantization. A scalar cone-table
	# prototype was slower in GDScript; unchanged worker facings skip this call.
	var angle: float = facing.angle()
	if absf(wrapf(angle - previous * PI / 4.0, -PI, PI)) < PI / 8.0 + 0.06:
		return previous
	return posmod(roundi(angle / (PI / 4.0)), 8)

static func action_for(species: int, behavior: int, moving: bool, pressure: bool) -> int:
	match species:
		SimTypes.Species.SHEEP:
			match behavior:
				SimTypes.Behavior.FLEE:
					return Action.SHEEP_FLEE
				SimTypes.Behavior.GRAZE:
					return Action.SHEEP_WALK if moving else Action.SHEEP_GRAZE
				_:
					return Action.SHEEP_WALK if moving else Action.SHEEP_IDLE
		SimTypes.Species.WOLF:
			match behavior:
				SimTypes.Behavior.STALK:
					return Action.WOLF_STALK
				SimTypes.Behavior.CHASE, SimTypes.Behavior.FLANK:
					return Action.WOLF_CHASE
				SimTypes.Behavior.ATTACK:
					return Action.WOLF_POUNCE
				SimTypes.Behavior.FEED:
					return Action.WOLF_FEED
				SimTypes.Behavior.RETREAT:
					return Action.WOLF_RETREAT
				_:
					return Action.WOLF_SEARCH if moving else Action.WOLF_OBSERVE
		SimTypes.Species.DOG:
			if pressure:
				return Action.DOG_PRESSURE
			if behavior == SimTypes.Behavior.INTERCEPT:
				return Action.DOG_INTERCEPT
			return Action.DOG_PATROL if moving else Action.DOG_GUARD_IDLE
	assert(false, "Unknown species in presentation")
	return Action.SHEEP_IDLE
