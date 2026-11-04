class_name ProductionBehaviorTrace
extends RefCounted
## Worker-owned observation record. Only primitive dictionaries leave the worker.
const MAX_EXPOSURE_EPISODES: int = 8
var handle: AgentHandle
var species: int
var group: int
var birth_tick: int
var eligible_tick: int = -1
var eligible_usec: int = -1
var exposure_ticks: int = 0
var exposure_episode_count: int = 0
var exposure_longest_ticks: int = 0
var exposure_last_visible_tick: int = -1
var exposure_last_start_tick: int = -1
var exposure_last_end_tick: int = -1
var exposure_last_end_reason: String = "NEVER_EXPOSED"
var exposure_episodes: Array[Dictionary] = []
var _exposure_open: bool = false
var _exposure_first_target: String = ""
var _exposure_last_target: String = ""
var known_tick: int = -1
var known_usec: int = -1
var known_source: String = "NONE"
var direct_tick: int = -1
var direct_usec: int = -1
var decision_tick: int = -1
var decision_usec: int = -1
var motion_tick: int = -1
var motion_usec: int = -1
var away_tick: int = -1
var death_tick: int = -1
var removed_by_protocol: bool = false
var response_distance: float = 0.0
var intended_progress: float = 0.0
var outward_progress: float = 0.0
var peak_response_speed: float = 0.0
var recovery_eligible_tick: int = -1
var recovery_tick: int = -1
var recovery_usec: int = -1
# The original columns remain the v1 definition, so old evidence stays comparable.
var recovery_v2_tick: int = -1
var recovery_v2_usec: int = -1
var recovery_v2_kind: String = "NONE"
var sheep_terminal: Dictionary = {}
var sheep_recovery_v2: Dictionary = {}
var return_needed: bool = false
var return_motion_pixels: float = 0.0
var exposure_target: AgentHandle
var exposure_position: Vector2
var previous_position: Vector2
var previous_state_tick: int = -1
var previous_hunger: float = NAN
var alive: bool = true

func response_behavior() -> int:
	match species:
		SimTypes.Species.SHEEP: return SimTypes.Behavior.FLEE
		SimTypes.Species.WOLF: return SimTypes.Behavior.RETREAT
		_: return SimTypes.Behavior.INTERCEPT

func case_name() -> String:
	match species:
		SimTypes.Species.SHEEP: return "sheep_flee"
		SimTypes.Species.WOLF: return "wolf_retreat_from_dog"
		_: return "dog_intercept"

## Episodes represent the union of geometric stimuli, not a claim of perception.
## First N segments are retained; all segments still contribute exact totals.
func observe_exposure_tick(tick: int, target: AgentHandle) -> void:
	assert(target != null)
	if not _exposure_open:
		_exposure_open = true
		exposure_episode_count += 1
		exposure_last_start_tick = tick
		_exposure_first_target = target.key()
	_exposure_last_target = target.key()
	exposure_ticks += 1
	exposure_last_visible_tick = tick
	exposure_longest_ticks = maxi(exposure_longest_ticks, tick - exposure_last_start_tick + 1)

func close_exposure(tick: int, reason: String) -> void:
	if not _exposure_open:
		return
	assert(tick == exposure_last_visible_tick + 1)
	_exposure_open = false
	exposure_last_end_tick = tick
	exposure_last_end_reason = reason
	if exposure_episodes.size() < MAX_EXPOSURE_EPISODES:
		exposure_episodes.append({"start_tick": exposure_last_start_tick, "end_tick_exclusive": tick,
			"duration_ticks": tick - exposure_last_start_tick, "end_reason": reason,
			"first_nearest_target": _exposure_first_target, "last_nearest_target": _exposure_last_target})

func to_dictionary() -> Dictionary:
	return {
		"handle": handle.key(), "species": species, "group": group, "case": case_name(),
		"birth_tick": birth_tick, "eligible_tick": eligible_tick, "eligible_usec": eligible_usec,
		"exposure_ticks": exposure_ticks, "exposure_episode_count": exposure_episode_count,
		"exposure_longest_ticks": exposure_longest_ticks, "exposure_last_visible_tick": exposure_last_visible_tick,
		"exposure_last_start_tick": exposure_last_start_tick, "exposure_last_end_tick_exclusive": exposure_last_end_tick,
		"exposure_last_end_reason": exposure_last_end_reason,
		"exposure_episodes_omitted": maxi(0, exposure_episode_count - exposure_episodes.size()),
		"response_right_censored": decision_tick < 0 and exposure_last_end_reason in ["THREATS_REMOVED", "OBSERVATION_WINDOW_ENDED"],
		"known_tick": known_tick, "known_usec": known_usec, "known_source": known_source,
		"direct_tick": direct_tick, "direct_usec": direct_usec, "decision_tick": decision_tick, "decision_usec": decision_usec,
		"motion_tick": motion_tick, "motion_usec": motion_usec, "away_tick": away_tick,
		"death_tick": death_tick, "alive_at_end": alive, "removed_by_protocol": removed_by_protocol,
		"response_before_exposure": decision_tick >= 0 and (eligible_tick < 0 or decision_tick < eligible_tick),
		"exposed_without_decision": eligible_tick >= 0 and decision_tick < 0,
		"exposed_without_motion": eligible_tick >= 0 and motion_tick < 0,
		"response_distance_pixels": response_distance, "intended_progress_pixels": intended_progress,
		"outward_progress_pixels": outward_progress, "peak_response_speed_px_per_second": peak_response_speed,
		"recovery_eligible_tick": recovery_eligible_tick, "recovery_tick": recovery_tick,
		"recovery_usec": recovery_usec, "return_needed": return_needed,
		"return_motion_pixels": return_motion_pixels,
		"recovery_v2_tick": recovery_v2_tick, "recovery_v2_usec": recovery_v2_usec,
		"recovery_v2_kind": recovery_v2_kind,
	}

## This recognizes the real rest leaf's contract, never arbitrary IDLE output.
## Reads at the simulation tick supplied by the worker; no fact/latch is mutated.
static func satiated_rest_evidence(context: AgentContext, intent: MotionIntent, tick: int, hunger: float) -> String:
	if context.suspended or context.awaiting_resume_perception:
		return "INACTIVE_OR_AWAITING_SCAN"
	if intent == null:
		return "MISSING_OR_EXPIRED_INTENT"
	if intent.actor == null or not intent.actor.same_life(context.handle):
		return "WRONG_LIFE"
	if tick >= intent.expires_tick:
		return "MISSING_OR_EXPIRED_INTENT"
	if context.task_token <= 0 or intent.owner_token != context.task_token:
		return "UNOWNED_INTENT"
	if context.task_name != &"rest_satiated":
		return "OTHER_LEAF"
	if intent.mode != SimTypes.IntentMode.STOP or intent.behavior != SimTypes.Behavior.IDLE or intent.speed != 0.0:
		return "NOT_REST_OUTPUT"
	if context.grazing_committed:
		return "FEEDING_COMMITTED"
	if not is_finite(hunger) or hunger >= context.coordinator.settings.hungry_threshold:
		return "NOT_SATIATED"
	if tick < context.safe_after_tick or (context.threat != null and context.observation_for(context.threat.handle, tick) != null):
		return "UNSAFE_OR_SAFETY_HOLD"
	return "VERIFIED_SATIATED_REST"

static func summarize(records: Array[Dictionary], case_label: String) -> Dictionary:
	var result: Dictionary = {"case": case_label, "cohort": 0, "eligible": 0,
		"responded": 0, "responded_total": 0, "moved_along_intent": 0, "moved_total": 0, "moved_outward": 0,
		"unexposed": 0, "unresponded_alive": 0, "died_without_response": 0, "right_censored_unresponded": 0,
		"protocol_removed_without_response": 0, "response_before_exposure": 0,
		"recovery_eligible": 0, "recovered": 0, "recovered_v2": 0,
		"recovered_satiated_rest_v2": 0, "unrecovered_alive_v2": 0, "died_before_recovery_v2": 0,
		"return_needed": 0, "return_motion_observed": 0}
	var decision_msec: Array[float] = []
	var movement_msec: Array[float] = []
	var decision_ticks: Array[float] = []
	var known_msec: Array[float] = []
	for record: Dictionary in records:
		if record["case"] != case_label:
			continue
		result["cohort"] += 1
		result["responded_total"] += int(int(record["decision_tick"]) >= 0)
		result["moved_total"] += int(int(record["motion_tick"]) >= 0)
		if record["response_before_exposure"]:
			result["response_before_exposure"] += 1
		if int(record["recovery_eligible_tick"]) >= 0:
			result["recovery_eligible"] += 1
			result["recovered"] += int(int(record["recovery_tick"]) >= 0)
			var recovered_v2: bool = int(record["recovery_v2_tick"]) >= 0
			result["recovered_v2"] += int(recovered_v2)
			result["recovered_satiated_rest_v2"] += int(record["recovery_v2_kind"] == "VERIFIED_SATIATED_REST")
			result["unrecovered_alive_v2"] += int(not recovered_v2 and record["alive_at_end"])
			result["died_before_recovery_v2"] += int(not recovered_v2 and not record["alive_at_end"])
			result["return_needed"] += int(record["return_needed"])
			result["return_motion_observed"] += int(float(record["return_motion_pixels"]) >= 1.0)
		if int(record["eligible_tick"]) < 0:
			result["unexposed"] += 1
			continue
		result["eligible"] += 1
		result["right_censored_unresponded"] += int(record["response_right_censored"])
		if int(record["known_tick"]) >= int(record["eligible_tick"]):
			known_msec.append(float(int(record["known_usec"]) - int(record["eligible_usec"])) / 1000.0)
		if int(record["decision_tick"]) >= 0:
			result["responded"] += 1
			if int(record["decision_tick"]) >= int(record["eligible_tick"]):
				decision_ticks.append(float(int(record["decision_tick"]) - int(record["eligible_tick"])))
				decision_msec.append(float(int(record["decision_usec"]) - int(record["eligible_usec"])) / 1000.0)
		elif record["removed_by_protocol"]:
			result["protocol_removed_without_response"] += 1
		elif record["alive_at_end"]:
			result["unresponded_alive"] += 1
		else:
			result["died_without_response"] += 1
		if int(record["motion_tick"]) >= 0:
			result["moved_along_intent"] += 1
			if int(record["motion_usec"]) >= int(record["eligible_usec"]):
				movement_msec.append(float(int(record["motion_usec"]) - int(record["eligible_usec"])) / 1000.0)
		result["moved_outward"] += int(int(record["away_tick"]) >= 0)
	result["decision_latency_ticks_p95"] = percentile(decision_ticks, 0.95)
	result["known_latency_wall_ms_p95"] = percentile(known_msec, 0.95)
	result["decision_latency_wall_ms_p95"] = percentile(decision_msec, 0.95)
	result["decision_latency_wall_ms_p99"] = percentile(decision_msec, 0.99)
	result["motion_latency_wall_ms_p95"] = percentile(movement_msec, 0.95)
	result["decision_latency_samples"] = decision_msec.size()
	result["latency_scope"] = "Successful nonnegative responses only; eligible nonresponders and deaths remain separate counts. No whole-cohort percentile is claimed."
	return result

static func percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return -1.0
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	return sorted[floori((sorted.size() - 1) * fraction)]
