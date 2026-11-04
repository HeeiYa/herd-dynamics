class_name ProductionHuntTrace
extends RefCounted
## Three role metrics belong to one declared target life, never mixed targets.
var handle: AgentHandle
var previous_position: Vector2
var previous_velocity: Vector2
var previous_task: StringName
var previous_token: int
var previous_hunger: float
var eligible_tick: int = -1
var eligible_usec: int = -1
var exposure_ticks: int = 0
var cooperation_eligible_tick: int = -1
var known_tick: int = -1
var known_usec: int = -1
var hunt_tick: int = -1
var hunt_usec: int = -1
var capture_tick: int = -1
var capture_usec: int = -1
var capture_count: int = 0
var feed_tick: int = -1
var feed_usec: int = -1
var feed_stopped_tick: int = -1
var feed_stopped_usec: int = -1
var role_first_lease := PackedInt64Array([-1, -1, -1])
var role_intent_ticks := PackedInt64Array([0, 0, 0])
var role_intended_progress := PackedFloat64Array([0, 0, 0])
var role_direction_progress := PackedFloat64Array([0, 0, 0])
var role_motion_tick := PackedInt64Array([-1, -1, -1])
var role_motion_usec := PackedInt64Array([-1, -1, -1])
var terminal: Dictionary = {}

func to_dictionary() -> Dictionary:
	return {"handle": handle.key(), "eligible_tick": eligible_tick, "eligible_usec": eligible_usec,
		"exposure_ticks": exposure_ticks, "cooperation_eligible_tick": cooperation_eligible_tick,
		"known_tick": known_tick, "known_usec": known_usec, "hunt_tick": hunt_tick, "hunt_usec": hunt_usec,
		"first_capture_tick": capture_tick, "first_capture_usec": capture_usec, "capture_count": capture_count,
		"feed_tick": feed_tick, "feed_usec": feed_usec,
		"feed_stopped_tick": feed_stopped_tick, "feed_stopped_usec": feed_stopped_usec}

func role_rows(target: AgentHandle) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for role: int in 3:
		rows.append({"actor": handle.key(), "target": target.key(), "role": CoordinationSystem.Role.keys()[role],
			"first_lease_tick": role_first_lease[role], "matching_intent_ticks": role_intent_ticks[role],
			"intended_progress_pixels": role_intended_progress[role],
			"role_direction_progress_pixels": role_direction_progress[role],
			"physical_role_tick": role_motion_tick[role], "physical_role_usec": role_motion_usec[role]})
	return rows
