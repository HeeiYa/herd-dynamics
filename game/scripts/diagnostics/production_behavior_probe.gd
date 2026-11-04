class_name ProductionBehaviorProbe
extends RefCounted
## Diagnostic fixture and observer owned exclusively by SimulationExecutor.
## All stimuli use ordinary stage-0 commands; trees and movement stay untouched.
const THREAT_TICK: int = 240
const INVALIDATION_START_TICK: int = 300
const DOG_TICK: int = 360
const CLEAR_THREATS_TICK: int = 600
const END_TICK: int = 1200
const GROUP_CENTERS: Array[Vector2] = [Vector2(600, 700), Vector2(1800, 700)]
const BODY_SPACING: float = 32.0

var finished: bool = false
var observer_usec: int = 0
var observed_steps: int = 0
var _world: SimulationWorld
var _sheep_count: int
var _seed: int
var _started_usec: int
var _records: Array[ProductionBehaviorTrace] = []
var _by_identity: Dictionary[String, ProductionBehaviorTrace] = {}
var _wolves: Array[AgentHandle] = []
var _dogs: Array[AgentHandle] = []
var _indexed_life_revision: int = -1
var _events: Array[Dictionary] = []
var _captures: Array[Dictionary] = []
var _retired_target: AgentHandle
var _invalidation_tick: int = -1
var _invalidation_cleared_tick: int = -1
var _replacement_handle: AgentHandle
var _hunters_at_invalidation: Array[AgentHandle] = []
var _illegal_retired_captures: int = 0
var _recovery_started: bool = false
var _quality: Array[Dictionary] = []
var _dog_diagnostics := ProductionDogDiagnostics.new()

func setup(world: SimulationWorld, sheep_count: int, seed_value: int) -> void:
	assert(sheep_count >= 8 and sheep_count <= 1000)
	assert(world.store.count == 0 and world.pending_spawns == PackedInt32Array([0, 0, 0]))
	assert(world.config.world_size == Vector2(2400, 1400))
	_world = world
	_sheep_count = sheep_count
	_seed = seed_value
	_started_usec = Time.get_ticks_usec()
	world.captured.connect(_on_capture)
	world.diagnostic_step_started = observe_step_start
	_queue_initial_flocks()

func _queue_initial_flocks() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = _seed
	for group: int in 2:
		var count: int = _sheep_count / 2 + (_sheep_count % 2 if group == 1 else 0)
		var columns: int = ceili(sqrt(float(count)))
		var rows: int = ceili(float(count) / columns)
		for index: int in count:
			var offset := Vector2(index % columns - (columns - 1) * 0.5, index / columns - (rows - 1) * 0.5) * BODY_SPACING
			var jitter := Vector2(random.randf_range(-2, 2), random.randf_range(-2, 2))
			_world.queue_place(SimTypes.Species.SHEEP, GROUP_CENTERS[group] + offset + jitter)
	_events.append({"event": "initial_two_flocks", "scheduled_tick": 0, "sheep": _sheep_count})

## Called on the owning worker immediately before the next World.step.
func before_step(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	if world.tick == THREAT_TICK:
		_queue_two_sided_threats()
	if world.tick >= INVALIDATION_START_TICK and world.tick < DOG_TICK and _retired_target == null:
		_queue_target_invalidation()
	if world.tick == DOG_TICK:
		_queue_intervening_dogs()
	if world.tick == CLEAR_THREATS_TICK:
		for handle: AgentHandle in _wolves:
			if world.store.is_alive(handle):
				world.queue_remove(handle)
				_by_identity[handle.key()].removed_by_protocol = true
		_events.append({"event": "remove_all_stimulus_wolves", "scheduled_tick": world.tick})
	observer_usec += Time.get_ticks_usec() - started

func _queue_two_sided_threats() -> void:
	for group: int in 2:
		for side: int in [-1, 1]:
			var selected: ProductionBehaviorTrace
			var extreme: float = -INF
			for record: ProductionBehaviorTrace in _records:
				if record.species != SimTypes.Species.SHEEP or record.group != group or not _world.store.is_alive(record.handle):
					continue
				var position: Vector2 = _world.store.position_current[_world.store.resolve(record.handle)]
				if position.x * side > extreme:
					extreme = position.x * side
					selected = record
			if selected == null:
				continue
			var anchor: Vector2 = _world.store.position_current[_world.store.resolve(selected.handle)]
			var position: Vector2 = anchor + Vector2(90 * side, 0)
			_world.queue_place(SimTypes.Species.WOLF, position)
			_events.append({"event": "registered_wolf_appears", "scheduled_tick": _world.tick, "group": group, "side": side, "position": [position.x, position.y]})

func _queue_target_invalidation() -> void:
	for wolf: AgentHandle in _wolves:
		var intent: MotionIntent = _world.intents.get_intent(wolf, _world.tick)
		if intent == null or intent.target == null or not _world.store.is_alive(intent.target):
			continue
		if intent.behavior not in [SimTypes.Behavior.STALK, SimTypes.Behavior.CHASE, SimTypes.Behavior.FLANK, SimTypes.Behavior.ATTACK]:
			continue
		_retired_target = intent.target
		_invalidation_tick = _world.tick
		var position: Vector2 = _world.store.position_current[_world.store.resolve(_retired_target)]
		_world.queue_remove(_retired_target)
		_world.queue_place(SimTypes.Species.SHEEP, position)
		_by_identity[_retired_target.key()].removed_by_protocol = true
		for candidate: AgentHandle in _wolves:
			var other: MotionIntent = _world.intents.get_intent(candidate, _world.tick)
			if other != null and other.target != null and other.target.same_life(_retired_target):
				_hunters_at_invalidation.append(candidate)
		_events.append({"event": "remove_pursued_sheep_and_replace", "scheduled_tick": _world.tick, "retired": _retired_target.key()})
		return

func _queue_intervening_dogs() -> void:
	for wolf: AgentHandle in _wolves:
		if not _world.store.is_alive(wolf):
			continue
		var position: Vector2 = _world.store.position_current[_world.store.resolve(wolf)]
		var group: int = _by_identity[wolf.key()].group
		var toward_flock: Vector2 = (GROUP_CENTERS[group] - position).normalized()
		var dog_position: Vector2 = position + toward_flock * 65.0
		_world.queue_place(SimTypes.Species.DOG, dog_position)
		_events.append({"event": "registered_dog_intervenes", "scheduled_tick": _world.tick, "group": group, "position": [dog_position.x, dog_position.y]})

## Stage 0 has finished, and neither AI nor movement has run for this tick.
func observe_step_start(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	_register_new_lives()
	for record: ProductionBehaviorTrace in _records:
		var dense: int = world.store.resolve(record.handle)
		if dense < 0:
			if record.alive:
				record.alive = false
				record.death_tick = world.tick
			continue
		record.previous_position = world.store.position_current[dense]
		if world.tick >= THREAT_TICK and world.tick < CLEAR_THREATS_TICK:
			_observe_exposure(record)
	if world.tick == CLEAR_THREATS_TICK:
		_begin_recovery()
	observer_usec += Time.get_ticks_usec() - started

func _register_new_lives() -> void:
	if _indexed_life_revision == _world.store.life_revision:
		return
	for dense: int in _world.store.count:
		var handle: AgentHandle = _world.store.handle_at(dense)
		if _by_identity.has(handle.key()):
			continue
		var record := ProductionBehaviorTrace.new()
		record.handle = handle
		record.species = _world.store.species[dense]
		record.birth_tick = _world.tick
		var position: Vector2 = _world.store.position_current[dense]
		record.group = int(position.distance_squared_to(GROUP_CENTERS[1]) < position.distance_squared_to(GROUP_CENTERS[0]))
		_records.append(record)
		_by_identity[handle.key()] = record
		if record.species == SimTypes.Species.WOLF:
			_wolves.append(handle)
		elif record.species == SimTypes.Species.DOG:
			_dogs.append(handle)
		# Preserve the immediate replacement life even if it later dies and the
		# same slot is reused again by another species during this protocol.
		if _replacement_handle == null and _retired_target != null and handle.slot == _retired_target.slot and not handle.same_life(_retired_target):
			_replacement_handle = handle
	_indexed_life_revision = _world.store.life_revision

func _observe_exposure(record: ProductionBehaviorTrace) -> void:
	var targets: Array[AgentHandle] = _dogs if record.species == SimTypes.Species.WOLF else _wolves
	var radius: float = _world.ai.settings.dog_risk_radius if record.species == SimTypes.Species.WOLF else _world.config.perception_radius
	var nearest_squared: float = radius * radius
	var target: AgentHandle
	for candidate: AgentHandle in targets:
		var dense: int = _world.store.resolve(candidate)
		if dense < 0:
			continue
		var position: Vector2 = _world.store.position_current[dense]
		var distance_squared: float = record.previous_position.distance_squared_to(position)
		if distance_squared <= nearest_squared:
			nearest_squared = distance_squared
			target = candidate
			record.exposure_position = position
	if target == null:
		return
	# Keep the currently closest geometric stimulus for radial motion. The first
	# eligibility timestamp remains fixed; shared knowledge may precede exposure.
	record.exposure_target = target
	if record.eligible_tick < 0:
		record.eligible_tick = _world.tick
		record.eligible_usec = Time.get_ticks_usec() - _started_usec

func _begin_recovery() -> void:
	_recovery_started = true
	for record: ProductionBehaviorTrace in _records:
		if not record.alive or record.decision_tick < 0 or record.species == SimTypes.Species.WOLF:
			continue
		record.recovery_eligible_tick = _world.tick
		if record.species == SimTypes.Species.DOG:
			var context: AgentContext = _world.ai.inspect(record.handle)
			record.return_needed = record.previous_position.distance_to(context.protection_anchor) > _world.ai.settings.guard_arrival_distance

func after_step(world: SimulationWorld) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	var decision_tick: int = world.tick - 1
	for record: ProductionBehaviorTrace in _records:
		var dense: int = world.store.resolve(record.handle)
		if dense >= 0:
			_observe_response(record, decision_tick, world.store.position_current[dense])
	_observe_invalidated_target()
	if world.tick % 60 == 0:
		_sample_quality()
	observed_steps += 1
	observer_usec += Time.get_ticks_usec() - started
	finished = world.tick >= END_TICK

func _observe_response(record: ProductionBehaviorTrace, tick: int, position: Vector2) -> void:
	var context: AgentContext = _world.ai.inspect(record.handle)
	if context == null:
		return
	var targets: Array[AgentHandle] = _dogs if record.species == SimTypes.Species.WOLF else _wolves
	for target: AgentHandle in targets:
		if not _world.store.is_active(target):
			continue
		var observation: LocalObservation = context.observations.get(target.slot)
		if observation == null or not observation.handle.same_life(target) or tick >= observation.expires_tick:
			continue
		if record.known_tick < 0:
			record.known_tick = tick
			record.known_usec = Time.get_ticks_usec() - _started_usec
			record.known_source = LocalObservation.Source.keys()[observation.source]
		if record.direct_tick < 0 and observation.last_direct_tick >= THREAT_TICK:
			record.direct_tick = observation.last_direct_tick
			record.direct_usec = Time.get_ticks_usec() - _started_usec
	var intent: MotionIntent = _world.intents.get_intent(record.handle, tick)
	if record.species == SimTypes.Species.DOG and (tick % ProductionDogDiagnostics.SAMPLE_PERIOD_TICKS == 0 or tick == END_TICK - 1):
		_dog_diagnostics.sample(_world, record, context, intent, position, tick, Time.get_ticks_usec() - _started_usec, _wolves)
	if intent == null or intent.owner_token != context.task_token:
		return
	if intent.behavior == record.response_behavior():
		if record.decision_tick < 0:
			record.decision_tick = tick
			record.decision_usec = Time.get_ticks_usec() - _started_usec
		var displacement: Vector2 = position - record.previous_position
		var desired: Vector2 = (intent.destination - record.previous_position).normalized()
		record.response_distance += displacement.length()
		record.intended_progress += maxf(0.0, displacement.dot(desired))
		record.peak_response_speed = maxf(record.peak_response_speed, displacement.length() / _world.config.fixed_dt)
		if record.intended_progress >= 1.0 and record.motion_tick < 0:
			record.motion_tick = tick + 1
			record.motion_usec = Time.get_ticks_usec() - _started_usec
		if record.exposure_target != null and record.species != SimTypes.Species.DOG:
			var outward: Vector2 = (record.previous_position - record.exposure_position).normalized()
			record.outward_progress += maxf(0.0, displacement.dot(outward))
			if record.outward_progress >= 1.0 and record.away_tick < 0:
				record.away_tick = tick + 1
	if _recovery_started and record.recovery_eligible_tick >= 0:
		_observe_recovery(record, context, intent, position, tick)

func _observe_recovery(record: ProductionBehaviorTrace, context: AgentContext, intent: MotionIntent, position: Vector2, tick: int) -> void:
	var recovered: bool = false
	if record.species == SimTypes.Species.SHEEP:
		recovered = intent.behavior in [SimTypes.Behavior.GRAZE, SimTypes.Behavior.REGROUP, SimTypes.Behavior.SEARCH]
	elif record.species == SimTypes.Species.DOG:
		var anchor: Vector2 = context.protection_anchor
		if intent.behavior == SimTypes.Behavior.RETURN:
			record.return_motion_pixels += maxf(0.0, (position - record.previous_position).dot((anchor - record.previous_position).normalized()))
		recovered = intent.behavior == SimTypes.Behavior.GUARD and context.flock_count > 0 and position.distance_to(anchor) <= _world.ai.settings.guard_arrival_distance
	if recovered and record.recovery_tick < 0:
		record.recovery_tick = tick + 1
		record.recovery_usec = Time.get_ticks_usec() - _started_usec

func _observe_invalidated_target() -> void:
	if _retired_target == null or _invalidation_cleared_tick >= 0:
		return
	for hunter: AgentHandle in _hunters_at_invalidation:
		var intent: MotionIntent = _world.intents.get_intent(hunter, _world.tick)
		if intent != null and intent.target != null and intent.target.same_life(_retired_target):
			return
	_invalidation_cleared_tick = _world.tick

func _on_capture(event: CaptureEvent) -> void:
	var started: int = Time.get_ticks_usec()
	var record: ProductionBehaviorTrace = _by_identity.get(event.target.key())
	if record != null:
		# Capture is emitted before removal: retain same-step issued intent and
		# movement instead of silently dropping a dead nonresponder from the cohort.
		_observe_response(record, event.tick - 1, event.position)
		record.alive = false
		record.death_tick = event.tick
	if _retired_target != null and event.target.same_life(_retired_target) and event.tick > _invalidation_tick:
		_illegal_retired_captures += 1
	_captures.append({"actor": event.actor.key(), "target": event.target.key(), "tick": event.tick})
	observer_usec += Time.get_ticks_usec() - started

func _sample_quality() -> void:
	var active: int = 0
	var missing: int = 0
	var never_perceived: int = 0
	var perception_ages: Array[float] = []
	var decision_ages: Array[float] = []
	for record: ProductionBehaviorTrace in _records:
		if not _world.store.is_active(record.handle):
			continue
		var context: AgentContext = _world.ai.inspect(record.handle)
		active += 1
		missing += int(_world.intents.get_intent(record.handle, _world.tick) == null)
		if context.last_perception_tick < 0:
			never_perceived += 1
		else:
			perception_ages.append(float(_world.tick - context.last_perception_tick))
		decision_ages.append(float(_world.tick - context.last_decision_tick))
	_quality.append({"tick": _world.tick, "elapsed_usec": Time.get_ticks_usec() - _started_usec,
		"active": active, "missing_intents": missing, "never_perceived": never_perceived,
		"perception_age_p95_ticks": ProductionBehaviorTrace.percentile(perception_ages, 0.95),
		"decision_age_p95_ticks": ProductionBehaviorTrace.percentile(decision_ages, 0.95)})

## Call once after finished. This graph contains only copied scalar/array data.
func finish_report() -> Dictionary:
	assert(finished)
	var records: Array[Dictionary] = []
	for record: ProductionBehaviorTrace in _records:
		records.append(record.to_dictionary())
	var outcomes: Array[Dictionary] = []
	var group_outcomes: Array[Dictionary] = []
	for label: String in ["sheep_flee", "wolf_retreat_from_dog", "dog_intercept"]:
		outcomes.append(ProductionBehaviorTrace.summarize(records, label))
		for group: int in 2:
			var group_records: Array[Dictionary] = []
			for record: Dictionary in records:
				if int(record["group"]) == group:
					group_records.append(record)
			var group_result: Dictionary = ProductionBehaviorTrace.summarize(group_records, label)
			group_result["group"] = group
			group_outcomes.append(group_result)
	return {
		"protocol": "production-two-flocks-v1", "seed": _seed, "requested_sheep": _sheep_count,
		"world_size": [2400, 1400], "body_spacing": BODY_SPACING,
		"warmup_ticks": THREAT_TICK, "dog_tick": DOG_TICK, "threat_clear_tick": CLEAR_THREATS_TICK,
		"end_tick": _world.tick, "fixed_dt": _world.config.fixed_dt,
		"ai_budget_usec": _world.config.ai_budget_usec, "motion_backend": _world.motion.backend_status,
		"detached_ai": _world.config.detached_ai, "wall_seconds": float(Time.get_ticks_usec() - _started_usec) / 1000000.0,
		"observer_usec": observer_usec, "observed_steps": observed_steps,
		"outcomes": outcomes, "group_outcomes": group_outcomes, "records": records, "quality": _quality.duplicate(true),
		"events": _events.duplicate(true), "captures": _captures.duplicate(true),
		"dog_contexts": _dog_diagnostics.contexts.duplicate(true), "dog_threats": _dog_diagnostics.threats.duplicate(true),
		"dog_diagnostic_period_ticks": ProductionDogDiagnostics.SAMPLE_PERIOD_TICKS,
		"target_invalidation": {"exercised": _retired_target != null,
			"retired": _retired_target.key() if _retired_target != null else "",
			"replacement": _replacement_handle.key() if _replacement_handle != null else "",
			"same_slot_new_life": _replacement_handle != null and _retired_target != null and _replacement_handle.slot == _retired_target.slot and not _replacement_handle.same_life(_retired_target),
			"requested_tick": _invalidation_tick, "cleared_tick": _invalidation_cleared_tick,
			"hunters": _hunters_at_invalidation.size(), "illegal_retired_captures": _illegal_retired_captures},
		"scope": "Normal registered autonomous trees, normal 6ms worker allowance from first tick, ordinary queued placement/removal interventions. No forced strategy, no stationary unregistered stimulus, no high-budget warmup. Fixed body spacing and two-group geometry form a behavior protocol, not the natural-layout capacity benchmark.",
		"repeatability": "Seed controls initial jitter; stimuli use declared simulation ticks and current cohort edges. Wall-budget scheduling may change trajectories and adaptive target selection. Repeat seeds and retain all outcomes rather than asserting identical whole-world replay.",
		"clock_semantics": "Exposure at post-stage0/pre-AI state n; knowledge and owned decision inspected at end of n; physical movement completes at n+1. Wall timestamps are observer detection times, not precise intra-step BT timestamps. Same-step captures retain outcomes before lifecycle removal. Direct tick is original sighting tick; known source is end-of-step source, not intra-step ordering.",
		"eligibility": "Sheep/dog: any registered wolf geometrically inside perception radius. Wolf: registered dog inside risk radius. No-observation/no-response/death/protocol-removal remain explicit; geometric dog exposure alone does not guarantee a protected flock was known. Replacement life is a distinct cohort record.",
		"motion_semantics": "Intended motion requires accumulated positive projection >=1px while response intent is valid and owned; outward escape is a separate radial projection. Peak speed and actual path length are retained. These prove executed motion, not successful escape. Grazing/stopping outside a response is never a motion failure.",
		"acceptance": "Metrics, not automatic acceptance. An unexercised branch is not a pass. Successful-only latency quantiles must be read together with eligible/censored/dead counts. Recovery includes only surviving responders when threats are removed; dog endpoint at current anchor and actual return displacement are separate.",
		"instrumentation": "Full-cohort read-only observer cost is included in wall time, outside the AI allowance. Pre-AI/capture hooks are inside World.step; after_step is outside its timer. observer_usec includes pre/post hooks and capture callback. Do not compare this run's throughput directly to unprobed capacity.",
	}
