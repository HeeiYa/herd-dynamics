extends "res://scripts/ai/tasks/context_action.gd"
## Finite local escape choices, scored against private sightings only.
var _escape_direction: Vector2 = Vector2.ZERO
var _direction_until_tick: int = 0
var _known_threat_positions: PackedVector2Array = PackedVector2Array()
var _known_threat_count: int = 0

func _enter() -> void:
	super._enter()
	_escape_direction = Vector2.ZERO
	_direction_until_tick = 0
	if context.species == SimTypes.Species.WOLF:
		context.retreating = true

func _exit() -> void:
	if context.species == SimTypes.Species.WOLF:
		context.retreating = false
	super._exit()

func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	var origin: Vector2 = context.position()
	_collect_known_threats()
	var destination: Vector2 = _choose_destination(origin)
	_escape_direction = (destination - origin).normalized()
	if context.current_tick >= _direction_until_tick:
		_direction_until_tick = context.current_tick + ai.settings.escape_commit_ticks
	var retreat: bool = context.species == SimTypes.Species.WOLF
	var behavior: int = SimTypes.Behavior.RETREAT if retreat else SimTypes.Behavior.FLEE
	var speed: float = ai.settings.wolf_speed if retreat else ai.settings.sheep_flee_speed
	# threat is the actor's danger for both sheep and wolves; dog_threat belongs
	# to the dog's protection policy and denotes a wolf threatening its flock.
	var primary: LocalObservation = context.threat
	var target: AgentHandle = primary.handle if primary != null else null
	write_intent(SimTypes.IntentMode.FLEE, behavior, destination, speed, "Feasible multi-threat escape; short direction commitment", target)
	return RUNNING

func _collect_known_threats() -> void:
	_known_threat_count = 0
	for sighting: LocalObservation in context.threat_observations:
		if context.observation_for(sighting.handle) != null:
			_append_threat_position(sighting.position)
	if _known_threat_count == 0:
		# Safety hold continues from the last observation; it is not fresh sight.
		_append_threat_position(context.last_threat_position)

func _append_threat_position(position: Vector2) -> void:
	if _known_threat_count == _known_threat_positions.size():
		_known_threat_positions.resize(maxi(4, _known_threat_positions.size() * 2))
	_known_threat_positions[_known_threat_count] = position
	_known_threat_count += 1

func _choose_destination(origin: Vector2) -> Vector2:
	var ai: AICoordinator = context.coordinator
	var dense: int = ai.store.resolve(context.handle)
	assert(dense >= 0, "An active escape task must own a live agent")
	var inset: Vector2 = Vector2.ONE * ai.store.radius[dense]
	var upper: Vector2 = ai.config.world_size - inset
	var best_destination: Vector2 = origin
	var best_score: float = -INF
	var direction_count: int = maxi(4, ai.settings.escape_direction_count)
	# Axis directions include wall tangents. The two extra choices preserve a
	# previous heading and the direct retreat, independent of angular resolution.
	for candidate: int in range(direction_count + 2):
		var direction: Vector2
		if candidate == direction_count:
			direction = _escape_direction
		elif candidate == direction_count + 1:
			direction = (origin - context.last_threat_position).normalized()
		else:
			direction = Vector2.from_angle(TAU * float(candidate) / direction_count)
		var destination: Vector2 = (origin + direction * ai.settings.escape_lookahead_distance).clamp(inset, upper)
		var offset: Vector2 = destination - origin
		if offset.length_squared() < 1.0:
			continue
		var score: float = _minimum_threat_distance(destination)
		if context.current_tick < _direction_until_tick:
			score += offset.normalized().dot(_escape_direction) * ai.settings.escape_direction_bias
		if score > best_score:
			best_score = score
			best_destination = destination
	return best_destination

func _minimum_threat_distance(destination: Vector2) -> float:
	var minimum_squared: float = INF
	for index: int in range(_known_threat_count):
		minimum_squared = minf(minimum_squared, destination.distance_squared_to(_known_threat_positions[index]))
	return sqrt(minimum_squared)
