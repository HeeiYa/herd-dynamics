class_name ProductionForageTrace
extends RefCounted
## One complete sheep life; all positions and hunger samples are copied scalars.
var handle: AgentHandle
var previous_position: Vector2
var previous_hunger: float
var eligible_tick: int = -1
var eligible_usec: int = -1
var eligible_position: Vector2
var search_tick: int = -1
var search_usec: int = -1
var search_motion_tick: int = -1
var search_motion_usec: int = -1
var search_progress: float = 0.0
var path_pixels: float = 0.0
var maximum_net_pixels: float = 0.0
var exit_dry_region_tick: int = -1
var edible_underfoot_tick: int = -1
var eating_tick: int = -1
var eating_usec: int = -1
var food_eaten: float = 0.0
var first_intake: Dictionary = {}
var terminal: Dictionary = {}
var diagnostics := ProductionForageDiagnostics.new()

func to_dictionary(minimum_net_pixels: float) -> Dictionary:
	return {"handle": handle.key(), "eligible_tick": eligible_tick, "eligible_usec": eligible_usec,
		"eligible_x": eligible_position.x, "eligible_y": eligible_position.y,
		"search_tick": search_tick, "search_usec": search_usec,
		"search_motion_tick": search_motion_tick, "search_motion_usec": search_motion_usec,
		"search_progress_pixels": search_progress, "path_pixels": path_pixels,
		"maximum_net_pixels": maximum_net_pixels, "exit_dry_region_tick": exit_dry_region_tick,
		"edible_underfoot_tick": edible_underfoot_tick, "eating_tick": eating_tick,
		"eating_usec": eating_usec, "derived_food_eaten": food_eaten,
		"migration_completed": eligible_tick >= 0 and search_motion_tick >= 0 and exit_dry_region_tick >= 0 and maximum_net_pixels >= minimum_net_pixels and eating_tick >= 0}
