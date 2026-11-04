class_name EnduranceProbe
extends RefCounted
## Owner-only long-run protocol. No live World, pose or context crosses threads.
const SAMPLE_INTERVAL_USEC: int = 1000000
const MAX_ERRORS: int = 16
var mode: String = "natural"
var target_counts := PackedInt32Array([1000, 12, 8])
var turnover_ticks: int = 1800
var turnover_counts := PackedInt32Array([50, 1, 1])
var observe_service: bool = true
var require_gpu: bool = false
var start_usec: int = 0
var end_usec: int = 0
var finished: bool = false
var status_revision: int = 0
var latest_sample: Dictionary = {}
var final_report: Dictionary = {}
var observer_usec: int = 0
var _world: SimulationWorld
var _epoch: int = 0
var _next_sample_usec: int = 0
var _next_turnover_tick: int = -1
var _sample_sequence: int = 0
var _window_samples: int = 0
var _first_window_sample: int = -1
var _last_window_sample: int = -1
var _started: bool = false
var _previous_counts := PackedInt32Array([0, 0, 0])
var _capture_delta := PackedInt32Array([0, 0, 0])
var _removal_delta := PackedInt32Array([0, 0, 0])
var _pending_removals: Dictionary[String, int] = {}
var _pending_removal_counts := PackedInt32Array([0, 0, 0])
var _turnover_cursor := PackedInt32Array([0, 0, 0])
var _observed_generations := PackedInt64Array()
var _observed_reuses: int = 0
var _generation_advance: int = 0
var _errors: Array[String] = []
var _error_count: int = 0
var _steps: int = 0
var _first_sequence: int = -1
var _last_sequence: int = -1
var _start_tick: int = -1
var _end_tick: int = -1
var _start_counts := PackedInt32Array([0, 0, 0])
var _end_counts := PackedInt32Array([0, 0, 0])
var _last_window_publication_usec: int = 0
var _last_publication_pending := PackedInt32Array([0, 0, 0])
var _last_protocol_pending := PackedInt32Array([0, 0, 0])
var _last_protocol_removals := PackedInt32Array([0, 0, 0])
var _births := PackedInt64Array([0, 0, 0])
var _captures := PackedInt64Array([0, 0, 0])
var _removals := PackedInt64Array([0, 0, 0])
var _spawn_requested := PackedInt64Array([0, 0, 0])
var _turnover_rounds: int = 0
var _population_deficit_steps: int = 0
var _maximum_population_deficit: int = 0
var _active_actor_steps: int = 0
var _missing_actor_steps: int = 0
var _grass_consumed: float = 0.0
var _service_scan_usec: int = 0
var _observer_at_start: int = 0
var _service_scan_at_start: int = 0
var _perception_age := EnduranceHistogram.new(1.0, 3600.0, "ticks")
var _decision_age := EnduranceHistogram.new(1.0, 3600.0, "ticks")
var _perception_wait := EnduranceHistogram.new(1.0, 3600.0, "ticks")
var _decision_wait := EnduranceHistogram.new(1.0, 3600.0, "ticks")

func setup(world: SimulationWorld, protocol_mode: String, targets: PackedInt32Array) -> void:
	assert(protocol_mode in ["natural", "turnover"] and targets.size() == 3)
	_world = world
	_epoch = world.store.epoch
	mode = protocol_mode
	target_counts = targets.duplicate()
	_previous_counts = world.counts()
	world.captured.connect(_on_capture)
	world.observer_event.connect(_on_observer_event)

func arm_window(first_usec: int, last_usec: int) -> bool:
	if start_usec != 0 or first_usec <= Time.get_ticks_usec() or last_usec <= first_usec:
		return false
	start_usec = first_usec
	end_usec = last_usec
	_next_sample_usec = first_usec
	status_revision += 1
	return true

## Called after the ordinary publication is complete, on its owning worker.
## Its CPU cost is outside step/snapshot timers and remains inside throughput.
func observe_publication(publication: SimulationPublication) -> void:
	if finished:
		return
	var started: int = Time.get_ticks_usec()
	var in_window: bool = start_usec > 0 and publication.published_usec >= start_usec and publication.published_usec < end_usec
	if _world.store.epoch != _epoch:
		_fail("unexpected_epoch")
	if require_gpu and publication.step_usec > 0 and publication.motion_backend_status != "gpu":
		_fail("gpu_backend_unavailable")
	if publication.paused or publication.speed != 1.0:
		_fail("unexpected_playback_control")
	if publication.held_counts != PackedInt32Array([0, 0, 0]):
		_fail("unexpected_held_life")
	if in_window and not _started:
		_started = true
		_observer_at_start = observer_usec
		_service_scan_at_start = _service_scan_usec
		_start_tick = publication.tick - int(publication.step_usec > 0)
		_start_counts = _previous_counts.duplicate()
		_next_turnover_tick = publication.tick + turnover_ticks
		status_revision += 1
	if publication.step_usec > 0:
		_observe_population(publication, in_window)
	if start_usec > 0 and publication.published_usec >= end_usec:
		observer_usec += Time.get_ticks_usec() - started
		_finish()
		return
	if in_window and publication.step_usec > 0:
		_steps += 1
		if _first_sequence < 0:
			_first_sequence = publication.sequence
		_last_sequence = publication.sequence
		_end_tick = publication.tick
		_end_counts = publication.counts.duplicate()
		_last_window_publication_usec = publication.published_usec
		_last_publication_pending = _world.pending_spawns.duplicate()
		_active_actor_steps += publication.active_agents
		_missing_actor_steps += publication.missing_intents
		_grass_consumed += publication.grass_consumed
		var deficit: int = 0
		for species: int in 3:
			deficit += maxi(0, target_counts[species] - publication.counts[species])
		_maximum_population_deficit = maxi(_maximum_population_deficit, deficit)
		_population_deficit_steps += int(deficit > 0)
	if publication.step_usec > 0 and mode == "turnover":
		if in_window and publication.tick >= _next_turnover_tick:
			_queue_turnover()
			_next_turnover_tick = publication.tick + turnover_ticks
			_turnover_rounds += 1
		_replenish(publication.counts, in_window)
	if in_window and publication.step_usec > 0:
		# Scheduling follows this publication. Keep both endpoints so a last
		# queued turnover is not mistaken for births completed inside the window.
		_last_protocol_pending = _world.pending_spawns.duplicate()
		_last_protocol_removals = _pending_removal_counts.duplicate()
	var now: int = Time.get_ticks_usec()
	if now >= _next_sample_usec:
		# One real sample after a delay, never fabricated catch-up samples.
		_next_sample_usec = now + SAMPLE_INTERVAL_USEC
		latest_sample = _sample_service(publication, in_window)
		_sample_sequence += 1
		latest_sample["sample_sequence"] = _sample_sequence
		if in_window:
			if _first_window_sample < 0:
				_first_window_sample = _sample_sequence
			_last_window_sample = _sample_sequence
			_window_samples += 1
		status_revision += 1
	observer_usec += Time.get_ticks_usec() - started

func _observe_population(publication: SimulationPublication, in_window: bool) -> void:
	for species: int in 3:
		var born: int = publication.counts[species] - _previous_counts[species] + _capture_delta[species] + _removal_delta[species]
		if born < 0:
			_fail("unexplained_population_loss")
		if mode == "turnover" and publication.counts[species] > target_counts[species]:
			_fail("population_above_target")
		if in_window:
			_births[species] += born
			_captures[species] += _capture_delta[species]
			_removals[species] += _removal_delta[species]
	_previous_counts = publication.counts.duplicate()
	_capture_delta.fill(0)
	_removal_delta.fill(0)

static func replacement_count(target: int, live: int, pending_spawns: int, scheduled_removals: int) -> int:
	return maxi(0, target - live + scheduled_removals - pending_spawns)

func _replenish(counts: PackedInt32Array, in_window: bool) -> void:
	for species: int in 3:
		var amount: int = replacement_count(target_counts[species], counts[species], _world.pending_spawns[species], _pending_removal_counts[species])
		if amount > 0:
			_world.queue_spawn(species, amount)
			if in_window:
				_spawn_requested[species] += amount

func _queue_turnover() -> void:
	for species: int in 3:
		var remaining: int = mini(turnover_counts[species], target_counts[species])
		var next_cursor: int = _turnover_cursor[species]
		for offset: int in _world.store.capacity:
			if remaining == 0:
				break
			var slot: int = (next_cursor + offset) % _world.store.capacity
			var dense: int = _world.store.slot_to_dense[slot]
			if dense < 0 or dense >= _world.store.count:
				continue
			var handle: AgentHandle = _world.store.handle_at(dense)
			if handle.slot != slot or _world.store.species[dense] != species or not _world.store.is_active(handle):
				continue
			var key: String = handle.key()
			if _pending_removals.has(key):
				continue
			_pending_removals[key] = species
			_pending_removal_counts[species] += 1
			_world.queue_remove(handle)
			_turnover_cursor[species] = (slot + 1) % _world.store.capacity
			remaining -= 1

func _on_capture(event: CaptureEvent) -> void:
	# Production interaction captures sheep only; no dead dense lookup is legal.
	_capture_delta[SimTypes.Species.SHEEP] += 1
	var key: String = event.target.key()
	if _pending_removals.has(key):
		_pending_removal_counts[_pending_removals[key]] -= 1
		_pending_removals.erase(key)

func _on_observer_event(record: Dictionary) -> void:
	var event: String = record.get("event", "")
	if event == "remove":
		var key: String = record["handle"]
		if not _pending_removals.has(key):
			_fail("unrequested_removal")
			return
		var species: int = _pending_removals[key]
		_removal_delta[species] += 1
		_pending_removal_counts[species] -= 1
		_pending_removals.erase(key)
	elif event not in ["time_scale"]:
		_fail("unexpected_observer_event:" + event)

func _sample_service(publication: SimulationPublication, in_window: bool) -> Dictionary:
	var started: int = Time.get_ticks_usec()
	# Window membership follows the completed publication, even when this scan
	# starts after T1. sample_usec measures observation work, not its denominator.
	var row: Dictionary = {"sample_usec": started, "publication_usec": publication.published_usec,
		"tick": publication.tick,
		"epoch": publication.epoch, "population": _world.store.count,
		"capacity": _world.store.capacity, "sheep": publication.counts[0],
		"wolves": publication.counts[1], "dogs": publication.counts[2],
		"pending_sheep": _world.pending_spawns[0], "pending_wolves": _world.pending_spawns[1],
		"pending_dogs": _world.pending_spawns[2], "active": 0, "moving": 0,
		"missing_intents": 0, "moving_missing_intents": 0, "grazing_intents": 0,
		"alert": 0, "never_perceived": 0, "task_uninitialized": 0,
		"perception_queued": 0, "decision_queued": 0,
		"perception_age_max_ticks": 0, "decision_age_max_ticks": 0,
		"perception_wait_max_ticks": 0, "decision_wait_max_ticks": 0,
		"in_window": in_window, "service_observed": observe_service}
	if not observe_service:
		return row
	_observed_generations.resize(_world.store.capacity)
	for dense: int in _world.store.count:
		var handle: AgentHandle = _world.store.handle_at(dense)
		var old_generation: int = _observed_generations[handle.slot]
		if old_generation > 0 and handle.generation > old_generation and in_window:
			_observed_reuses += 1
			_generation_advance += handle.generation - old_generation
		_observed_generations[handle.slot] = handle.generation
		if not _world.store.is_active(handle):
			continue
		row["active"] += 1
		var moving: bool = _world.store.velocity_current[dense].length_squared() > 9.0
		row["moving"] += int(moving)
		var context: AgentContext = _world.ai.inspect(handle)
		var intent: MotionIntent = _world.intents.get_intent(handle, publication.tick)
		var valid_intent: bool = intent != null and intent.owner_token == context.task_token
		row["missing_intents"] += int(not valid_intent)
		row["moving_missing_intents"] += int(moving and not valid_intent)
		row["grazing_intents"] += int(valid_intent and intent.behavior == SimTypes.Behavior.GRAZE)
		var alert: bool = publication.tick < context.safe_after_tick
		for observation: LocalObservation in [context.threat, context.dog_threat, context.prey]:
			alert = alert or (observation != null and context.observation_for(observation.handle, publication.tick) != null)
		row["alert"] += int(alert)
		row["never_perceived"] += int(context.last_perception_tick < 0)
		row["task_uninitialized"] += int(context.task_name == &"Uninitialized")
		var decision_age: int = maxi(0, publication.tick - context.last_decision_tick)
		row["decision_age_max_ticks"] = maxi(row["decision_age_max_ticks"], decision_age)
		if in_window:
			_decision_age.add(decision_age)
		if context.last_perception_tick >= 0:
			var age: int = publication.tick - context.last_perception_tick
			row["perception_age_max_ticks"] = maxi(row["perception_age_max_ticks"], age)
			if in_window:
				_perception_age.add(age)
		if context.perception_queued:
			var wait: int = maxi(0, publication.tick - context.next_perception_tick)
			row["perception_queued"] += 1
			row["perception_wait_max_ticks"] = maxi(row["perception_wait_max_ticks"], wait)
			if in_window:
				_perception_wait.add(wait)
		if context.decision_queued:
			var wait: int = maxi(0, publication.tick - context.next_decision_tick)
			row["decision_queued"] += 1
			row["decision_wait_max_ticks"] = maxi(row["decision_wait_max_ticks"], wait)
			if in_window:
				_decision_wait.add(wait)
	_service_scan_usec += Time.get_ticks_usec() - started
	return row

func status() -> Dictionary:
	return {"mode": mode, "start_usec": start_usec, "end_usec": end_usec,
		"finished": finished, "sample": latest_sample.duplicate(true),
		"observer_usec": observer_usec, "error_count": _error_count,
		"steps": _steps, "status_revision": status_revision}

func _fail(reason: String) -> void:
	_error_count += 1
	if _errors.size() < MAX_ERRORS and not _errors.has(reason):
		_errors.append(reason)

func _finish() -> void:
	if not _started or _steps == 0:
		_fail("no_completed_steps_in_window")
	finished = true
	status_revision += 1
	final_report = {"mode": mode, "start_usec": start_usec, "end_usec": end_usec,
		"valid_window": _started and _steps > 0,
		"wall_seconds": float(end_usec - start_usec) / 1000000.0,
		"steps": _steps, "first_step_sequence": _first_sequence, "last_step_sequence": _last_sequence,
		"start_tick": _start_tick, "end_tick": _end_tick, "start_counts": Array(_start_counts),
		"end_counts": Array(_end_counts), "target_counts": Array(target_counts),
		"births": Array(_births), "captures": Array(_captures), "protocol_removals": Array(_removals),
		"spawn_requested": Array(_spawn_requested), "pending_spawns_at_finish": Array(_world.pending_spawns),
		"turnover_rounds_scheduled": _turnover_rounds, "turnover_ticks": turnover_ticks,
		"last_window_publication_usec": _last_window_publication_usec,
		"pending_spawns_at_last_window_publication": Array(_last_publication_pending),
		"pending_spawns_after_last_window_protocol": Array(_last_protocol_pending),
		"pending_removals_after_last_window_protocol": Array(_last_protocol_removals),
		"turnover_counts": Array(turnover_counts), "population_deficit_steps": _population_deficit_steps,
		"maximum_population_deficit": _maximum_population_deficit,
		"active_actor_steps": _active_actor_steps, "missing_actor_steps": _missing_actor_steps,
		"grass_consumed": _grass_consumed, "observer_usec": observer_usec - _observer_at_start,
		"service_scan_usec": _service_scan_usec - _service_scan_at_start, "sample_sequence": _sample_sequence,
		"window_sample_count": _window_samples, "first_window_sample_sequence": _first_window_sample,
		"last_window_sample_sequence": _last_window_sample,
		"service_observed": observe_service, "motion_backend": _world.motion.backend_status,
		"detached_ai": _world.config.detached_ai, "ai_budget_usec": _world.config.ai_budget_usec,
		"observed_reused_lives": _observed_reuses, "observed_generation_advance": _generation_advance,
		"perception_age": _perception_age.summary(true), "decision_age": _decision_age.summary(true),
		"perception_wait": _perception_wait.summary(true), "decision_wait": _decision_wait.summary(true),
		"error_count": _error_count, "errors": _errors.duplicate(),
		"scope": "Fixed histograms; service is sampled actor-observations, not threat latency. Births use population balance; generation reuse is sampled. GRAZE is intent; grass_consumed is actual food. Observer cost remains inside throughput."}
