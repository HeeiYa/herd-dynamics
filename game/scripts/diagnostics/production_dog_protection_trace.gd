class_name ProductionDogProtectionTrace
extends ProductionBehaviorTrace
## One complete life, with broad geometry and narrower lease evidence kept
## separate. A peer that correctly guards need not chase an already leased wolf.
var guard_before_threat_tick: int = -1
var protected_geometry_ticks: int = 0
var first_lease_tick: int = -1
var lease_ticks: int = 0
var qualified_intercept_ticks: int = 0
var lease_progress_pixels: float = 0.0
var lease_motion_tick: int = -1
var active_observed_steps: int = 0
var missing_intent_steps: int = 0
var unowned_intent_steps: int = 0
var guard_without_lease_ticks: int = 0
var anchor_changes: int = 0
var largest_anchor_change_pixels: float = 0.0
var start_active: bool = false
var start_velocity: Vector2
var start_anchor: Vector2
var start_flock_count: int = 0
var start_flock_tick: int = -1
var start_current_flock: bool = false
var start_protected_geometry: bool = false
var start_nearest_distance: float = -1.0
var start_nearest_position: Vector2
var start_nearest_target: AgentHandle
var recovery_started: bool = false
var _last_anchor: Vector2
var _has_anchor: bool = false

func record_motion(intent: MotionIntent, position: Vector2, tick: int, elapsed_usec: int, qualified_lease: bool) -> void:
	if intent.behavior != response_behavior():
		return
	if decision_tick < 0:
		decision_tick = tick
		decision_usec = elapsed_usec
	var displacement: Vector2 = position - previous_position
	var direction: Vector2 = (intent.destination - previous_position).normalized()
	var progress: float = maxf(0.0, displacement.dot(direction))
	response_distance += displacement.length()
	intended_progress += progress
	if motion_tick < 0 and intended_progress >= 1.0:
		motion_tick = tick + 1
		motion_usec = elapsed_usec
	if qualified_lease:
		qualified_intercept_ticks += 1
		lease_progress_pixels += progress
		if lease_motion_tick < 0 and lease_progress_pixels >= 1.0:
			lease_motion_tick = tick + 1
	if species == SimTypes.Species.WOLF and start_nearest_target != null:
		var away: Vector2 = (previous_position - start_nearest_position).normalized()
		outward_progress += maxf(0.0, displacement.dot(away))
		if away_tick < 0 and outward_progress >= 1.0:
			away_tick = tick + 1

func observe_anchor(anchor: Vector2, has_current_flock: bool) -> bool:
	if not has_current_flock:
		return false
	var changed: bool = _has_anchor and anchor != _last_anchor
	if changed:
		anchor_changes += 1
		largest_anchor_change_pixels = maxf(largest_anchor_change_pixels, anchor.distance_to(_last_anchor))
	_last_anchor = anchor
	_has_anchor = true
	return changed

func to_dictionary() -> Dictionary:
	var result: Dictionary = super.to_dictionary()
	result.merge({
		"guard_before_threat_tick": guard_before_threat_tick,
		"protected_geometry_ticks": protected_geometry_ticks,
		"first_lease_tick": first_lease_tick, "lease_ticks": lease_ticks,
		"qualified_intercept_ticks": qualified_intercept_ticks,
		"lease_progress_pixels": lease_progress_pixels, "lease_motion_tick": lease_motion_tick,
		"active_observed_steps": active_observed_steps, "missing_intent_steps": missing_intent_steps,
		"unowned_intent_steps": unowned_intent_steps, "guard_without_lease_ticks": guard_without_lease_ticks,
		"anchor_changes": anchor_changes, "largest_anchor_change_pixels": largest_anchor_change_pixels,
	})
	return result
