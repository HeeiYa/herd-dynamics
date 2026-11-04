class_name ProductionBehaviorTrace
extends RefCounted
## Worker-owned observation record. Only primitive dictionaries leave the worker.
var handle: AgentHandle
var species: int
var group: int
var birth_tick: int
var eligible_tick: int = -1
var eligible_usec: int = -1
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
var return_needed: bool = false
var return_motion_pixels: float = 0.0
var exposure_target: AgentHandle
var exposure_position: Vector2
var previous_position: Vector2
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

func to_dictionary() -> Dictionary:
	return {
		"handle": handle.key(), "species": species, "group": group, "case": case_name(),
		"birth_tick": birth_tick, "eligible_tick": eligible_tick, "eligible_usec": eligible_usec,
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
	}

static func summarize(records: Array[Dictionary], case_label: String) -> Dictionary:
	var result: Dictionary = {"case": case_label, "cohort": 0, "eligible": 0,
		"responded": 0, "responded_total": 0, "moved_along_intent": 0, "moved_total": 0, "moved_outward": 0,
		"unexposed": 0, "unresponded_alive": 0, "died_without_response": 0,
		"protocol_removed_without_response": 0, "response_before_exposure": 0,
		"recovery_eligible": 0, "recovered": 0, "return_needed": 0, "return_motion_observed": 0}
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
			result["return_needed"] += int(record["return_needed"])
			result["return_motion_observed"] += int(float(record["return_motion_pixels"]) >= 1.0)
		if int(record["eligible_tick"]) < 0:
			result["unexposed"] += 1
			continue
		result["eligible"] += 1
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
