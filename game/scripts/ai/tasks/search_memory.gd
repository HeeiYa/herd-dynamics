extends "res://scripts/ai/tasks/context_action.gd"
## A memory search stays near its evidence and never holds a hunt lease.
const GOLDEN_ANGLE: float = 2.399963229728653
var _search_target: AgentHandle
var _source_tick: int = -1
var _destination: Vector2 = Vector2.ZERO
var _leg_until: int = 0
var _leg: int = 0

func _enter() -> void:
	super._enter()
	_search_target = null

func _tick(_delta: float) -> Status:
	var sighting: LocalObservation = context.prey
	if sighting == null or context.observation_for(sighting.handle) == null:
		return FAILURE
	var ai: AICoordinator = context.coordinator
	var last_position: Vector2 = sighting.predicted_position(context.current_tick, ai.config.fixed_dt, ai.settings)
	if _search_target == null or not _search_target.same_life(sighting.handle) or _source_tick != sighting.observed_tick:
		_search_target = sighting.handle
		_source_tick = sighting.observed_tick
		_destination = last_position
		_leg_until = context.current_tick + ai.settings.memory_search_leg_ticks
		_leg = 0
	if context.position().distance_to(_destination) <= ai.settings.exploration_arrival_distance or context.current_tick >= _leg_until:
		_leg += 1
		var angle: float = float(context.handle.slot + _leg) * GOLDEN_ANGLE
		_destination = last_position + Vector2.from_angle(angle) * ai.settings.max_prediction_distance
		_leg_until = context.current_tick + ai.settings.memory_search_leg_ticks
	write_intent(SimTypes.IntentMode.MOVE, SimTypes.Behavior.SEARCH, _destination, ai.settings.wolf_search_speed, "Lost sight: stable local legs until original evidence expiry", sighting.handle)
	return RUNNING
