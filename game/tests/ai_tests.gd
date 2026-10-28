extends SceneTree
## Durable fixtures for next-step communication, ownership, reuse, and AI debt.
class CountingPerception extends PerceptionSystem:
	var refreshes: Dictionary[int, int] = {}

	func _refresh_local_facts(context: AgentContext, tick: int) -> void:
		refreshes[context.handle.slot] = refreshes.get(context.handle.slot, 0) + 1
		super._refresh_local_facts(context, tick)

class CountingCoordinator extends AICoordinator:
	var wakeups: Dictionary[int, int] = {}

	func wake_for_observation(context: AgentContext, tick: int) -> void:
		wakeups[context.handle.slot] = wakeups.get(context.handle.slot, 0) + 1
		super.wake_for_observation(context, tick)
class SingleJobBudgetCoordinator extends AICoordinator:
	# Controlled substitute for the wall-clock boundary: one real job consumes the
	# whole allowance. The production queues, trees and sensor jobs remain intact.
	func _budget_available(_started: int) -> bool:
		return last_perception_jobs + last_decision_jobs < 1

var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _run() -> void:
	_test_probes()
	_test_coordination()
	await _test_local_knowledge()
	await _test_shared_batch()
	await _test_visible_to_memory_transition()
	await _test_scheduler_and_reuse()
	await _test_cross_step_stage_fairness()
	await _test_cross_step_urgent_fairness()
	print("AI_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_coordination() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	var settings := AISettings.new()
	var coordination := CoordinationSystem.new()
	coordination.setup(store, config, settings)
	var prey: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	var wolves: Array[AgentHandle] = []
	for index: int in range(4):
		wolves.append(store.create_agent(SimTypes.Species.WOLF, Vector2(80 + index, 100)))
	coordination.request(wolves[0], prey, CoordinationSystem.Kind.HUNT, 100, Vector2(80, 100), 10)
	coordination.begin_step(10)
	_check(coordination.get_lease(wolves[0], 10) == null, "Same-tick request cannot grant a lease")
	coordination.begin_step(11)
	var first: CoordinationSystem.Lease = coordination.get_lease(wolves[0], 11)
	_check(first != null, "Same-tick check retains request for the next step")
	coordination.release(wolves[0], 99)
	_check(coordination.get_lease(wolves[0], 11) == first, "Old task token cannot release current lease")
	coordination.request(wolves[0], prey, CoordinationSystem.Kind.HUNT, 100, Vector2(80, 100), 11)
	coordination.begin_step(12)
	_check(first.expires_tick == 12 + config.lease_ticks, "Same owner renews lease without changing its role")
	for index: int in range(1, 4):
		coordination.request(wolves[index], prey, CoordinationSystem.Kind.HUNT, 100 + index, Vector2(80 + index, 100), 12)
	coordination.begin_step(13)
	var roles: Dictionary[int, bool] = {}
	for wolf: AgentHandle in wolves:
		var lease: CoordinationSystem.Lease = coordination.get_lease(wolf, 13)
		if lease != null:
			roles[lease.role] = true
	_check(roles.size() == 3 and coordination.leases.size() == 3, "One prey receives distinct main, left and right roles, capped at three")
	var dog_a: AgentHandle = store.create_agent(SimTypes.Species.DOG, Vector2(90, 110))
	var dog_b: AgentHandle = store.create_agent(SimTypes.Species.DOG, Vector2(95, 110))
	coordination.request(dog_a, wolves[0], CoordinationSystem.Kind.DEFEND, 200, Vector2(90, 110), 13)
	coordination.request(dog_b, wolves[0], CoordinationSystem.Kind.DEFEND, 201, Vector2(95, 110), 13)
	coordination.begin_step(14)
	var defender_count: int = int(coordination.get_lease(dog_a, 14) != null) + int(coordination.get_lease(dog_b, 14) != null)
	_check(defender_count == 1, "Two dogs cannot both reserve the same threat")
	coordination.request(wolves[3], prey, CoordinationSystem.Kind.HUNT, 400, Vector2(80, 100), 14)
	coordination.remove(prey)
	store.remove_agent(prey)
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(101, 100))
	coordination.begin_step(15)
	_check(coordination.get_lease(wolves[3], 15) == null, "Removing target also removes pending requests")
	_check(prey.slot == replacement.slot and not prey.same_life(replacement), "Fixture reuses prey slot with a different generation")
	var old_actor: AgentHandle = wolves[3]
	store.remove_agent(old_actor)
	var fresh_actor: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(80, 100))
	coordination.request(fresh_actor, replacement, CoordinationSystem.Kind.HUNT, 500, Vector2(80, 100), 15)
	coordination.remove(old_actor)
	coordination.begin_step(16)
	_check(coordination.get_lease(fresh_actor, 16) != null, "Delayed old-actor cleanup does not remove replacement's pending request")
	coordination.remove(old_actor)
	_check(coordination.get_lease(fresh_actor, 16) != null, "Delayed old-actor cleanup does not remove replacement's lease")
	coordination.begin_step(16 + config.lease_ticks)
	_check(coordination.get_lease(fresh_actor, 16 + config.lease_ticks) == null, "Lease expires exactly on its deadline")

func _new_ai(store: AgentStore, config: SimulationConfig) -> AICoordinator:
	var ai := AICoordinator.new()
	root.add_child(ai)
	ai.setup(store, SpatialGrid.new(config.world_size, config.cell_size), ResourceGrid.new(config), IntentBuffer.new(), config)
	return ai

func _test_local_knowledge() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	var ai: AICoordinator = _new_ai(store, config)
	var observer: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	var ally: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(240, 100))
	var far_ally: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(600, 100))
	var prey: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(30, 100))
	for handle: AgentHandle in [observer, ally, far_ally, prey]:
		ai.register_agent(handle, 10)
	await process_frame
	ai.grid.rebuild(store)
	var sender: AgentContext = ai.contexts[observer.slot]
	var recipient: AgentContext = ai.contexts[ally.slot]
	ai.perception.update(sender, 10)
	ai.knowledge.publish(sender)
	ai.knowledge.deliver(ai, 10)
	_check(not recipient.observations.has(prey.slot), "Report is not delivered in its creation step")
	ai.knowledge.deliver(ai, 11)
	var report: LocalObservation = recipient.observations.get(prey.slot)
	_check(report != null and report.source == LocalObservation.Source.SHARED, "Nearby ally receives a shared local report")
	_check(report.observed_tick == 10 and report.expires_tick == 10 + config.memory_ticks, "Sharing preserves original evidence age and expiry")
	_check(not ai.contexts[far_ally.slot].observations.has(prey.slot), "A distant ally gains no global knowledge")
	var dense: int = store.resolve(prey)
	store.position_current[dense] = Vector2(900, 900)
	_check(report.position == Vector2(30, 100), "Target's later live movement cannot mutate a cached report")
	report.velocity = Vector2(1000, 0)
	var predicted: Vector2 = report.predicted_position(100, config.fixed_dt, ai.settings)
	_check(predicted.distance_to(report.position) <= ai.settings.max_prediction_distance + 0.001, "Stale observation prediction is spatially bounded")
	ai.grid.rebuild(store)
	recipient.current_tick = 11
	ai.perception.update(recipient, 11)
	ai.knowledge.publish(recipient)
	_check(ai.knowledge.pending.is_empty(), "Shared reports cannot be rebroadcast as fresh direct evidence")
	recipient.current_tick = 10 + config.memory_ticks
	ai.perception.update(recipient, recipient.current_tick)
	_check(recipient.observation_for(prey) == null, "Observation expires at the original deadline")
	ai.perception.merge_shared(recipient, report, recipient.current_tick)
	_check(not recipient.observations.has(prey.slot), "Late delivery cannot revive expired evidence")
	var copy: LocalObservation = sender.observations[prey.slot]
	store.remove_agent(prey)
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(30, 100))
	sender.current_tick = 11
	_check(sender.observation_for(copy.handle) == null and replacement.slot == prey.slot, "A remembered old handle never resolves a reused prey slot")
	ai.queue_free()
	await process_frame

func _test_scheduler_and_reuse() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	config.ai_budget_usec = 0
	var ai: AICoordinator = _new_ai(store, config)
	var old: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(300, 300))
	ai.register_agent(old, 0)
	await process_frame
	ai.grid.rebuild(store)
	ai.begin_frame()
	ai.begin_step(0)
	ai.step(0)
	_check(ai.last_perception_jobs == 0 and ai.last_decision_jobs == 0, "Exhausted frame budget defers AI jobs")
	config.ai_budget_usec = 100000
	ai.begin_frame()
	ai.begin_step(1)
	ai.step(1)
	_check(ai.last_perception_jobs > 0 and ai.last_decision_jobs > 0, "Deferred jobs survive to the next frame")
	_check(ai.max_decision_delay_ticks >= 1, "Scheduler records deferred decision age")
	var previous: AgentContext = ai.contexts[old.slot]
	previous.feeding_until = 900
	previous.safe_after_tick = 900
	previous.committed_target = old
	ai.unregister_agent(old)
	store.remove_agent(old)
	var replacement: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(350, 350))
	ai.register_agent(replacement, 37)
	var reused: AgentContext = ai.contexts[replacement.slot]
	_check(previous == reused, "The per-species context and BTPlayer pool is reused")
	_check(reused.observations.is_empty() and reused.committed_target == null and reused.feeding_until == 0 and reused.safe_after_tick == 0, "Pool reuse clears knowledge and strategy state")
	_check(reused.next_perception_tick >= 37 and reused.next_decision_tick >= 37, "Explicit birth tick never queues work into the previous step")
	ai.grid.rebuild(store)
	ai.begin_frame()
	ai.begin_step(37)
	ai.step(37)
	_check(reused.last_perception_tick == 37 and reused.last_decision_tick == 37, "Reused slot executes its first scheduled jobs at birth")
	_check(ai.intents.get_intent(old, 37) == null, "Old-life intents cannot cross the context pool boundary")
	ai.queue_free()
	await process_frame
func _test_visible_to_memory_transition() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	config.ai_budget_usec = 100000
	var ai: AICoordinator = _new_ai(store, config)
	var wolf: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
	var prey: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(150, 100))
	ai.register_agent(wolf, 0)
	ai.register_agent(prey, 0)
	await process_frame
	for tick: int in range(4):
		ai.begin_frame()
		ai.begin_step(tick)
		ai.grid.rebuild(store)
		ai.step(tick)
	var context: AgentContext = ai.contexts[wolf.slot]
	_check(context.task_name == &"hunt_prey" and ai.coordination.get_lease(wolf, 3) != null, "Visible prey enters the lease-backed hunt branch")
	var original_lease: CoordinationSystem.Lease = ai.coordination.get_lease(wolf, 3)
	var peer_report: LocalObservation = context.observations[prey.slot].copy_sighting()
	peer_report.observed_tick = 3
	peer_report.expires_tick = 3 + config.memory_ticks
	ai.perception.merge_shared(context, peer_report, 4)
	ai.perception.refresh_shared_facts(context, 4)
	ai.wake_for_observation(context, 4)
	ai.begin_frame()
	ai.begin_step(4)
	ai.grid.rebuild(store)
	ai.step(4)
	_check(peer_report.source == LocalObservation.Source.SHARED and peer_report.last_direct_tick == 0, "Newer shared evidence retains only this receiver's own direct-scan marker")
	_check(context.task_name == &"hunt_prey" and ai.coordination.get_lease(wolf, 4) == original_lease, "A newer peer report does not falsely lose sight or release the current hunt")
	var relayed: LocalObservation = peer_report.copy_sighting()
	_check(relayed.last_direct_tick == -1, "Copying a report never copies another agent's direct visibility")
	_check(not peer_report.was_visible_at_scan(0, config.memory_ticks, config.memory_ticks), "Fresh shared evidence cannot keep an expired direct-scan marker visible forever")
	store.position_current[store.resolve(prey)] = Vector2(900, 900)
	for tick: int in range(5, 8):
		ai.begin_frame()
		ai.begin_step(tick)
		ai.grid.rebuild(store)
		ai.step(tick)
	var memory_intent: MotionIntent = ai.intents.get_intent(wolf, 7)
	_check(context.task_name == &"search_memory" and memory_intent != null and memory_intent.behavior == SimTypes.Behavior.SEARCH, "Lost sight switches to the explicit memory-search branch")
	_check(ai.coordination.get_lease(wolf, 7) == null, "Memory search releases the previous hunt lease")
	_check(memory_intent != null and memory_intent.destination.distance_to(Vector2(150, 100)) <= ai.settings.max_prediction_distance, "Search uses the last sighting instead of the target's unseen current position")
	store.position_current[store.resolve(prey)] = Vector2(150, 100)
	for tick: int in range(8, 14):
		ai.begin_frame()
		ai.begin_step(tick)
		ai.grid.rebuild(store)
		ai.step(tick)
	_check(context.task_name == &"hunt_prey" and ai.coordination.get_lease(wolf, 13) != null, "A new direct sighting resumes pursuit with a new lease")
	ai.queue_free()
	await process_frame
func _shared_report(handle: AgentHandle, kind: int, position: Vector2, observed_tick: int, expires_tick: int) -> LocalObservation:
	var report := LocalObservation.new()
	report.handle = handle
	report.species = kind
	report.position = position
	report.observed_tick = observed_tick
	report.expires_tick = expires_tick
	report.source = LocalObservation.Source.SHARED
	return report

func _queue_report(ai: AICoordinator, sender: AgentHandle, recipient: AgentHandle, report: LocalObservation, delivery_tick: int) -> void:
	var message := LocalKnowledgeBroker.Message.new()
	message.sender = sender
	message.recipient = recipient
	message.sighting = report
	message.delivery_tick = delivery_tick
	ai.knowledge.pending.append(message)

func _test_shared_batch() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	var ai := CountingCoordinator.new()
	root.add_child(ai)
	ai.setup(store, SpatialGrid.new(config.world_size, config.cell_size), ResourceGrid.new(config), IntentBuffer.new(), config)
	var counted := CountingPerception.new()
	ai.perception = counted
	var sender: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 110))
	var recipient: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 100))
	var other: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(100, 120))
	var wolf_a: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(150, 100))
	var wolf_b: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(180, 100))
	var wolf_c: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(110, 100))
	var expired_target: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2(200, 100))
	for handle: AgentHandle in [sender, recipient, other]:
		ai.register_agent(handle, 0)
	await process_frame
	var context: AgentContext = ai.contexts[recipient.slot]
	context.last_perception_tick = 7
	var direct: LocalObservation = _shared_report(wolf_c, SimTypes.Species.WOLF, Vector2(110, 100), 13, 133)
	direct.source = LocalObservation.Source.DIRECT
	context.observations[wolf_c.slot] = direct
	_queue_report(ai, sender, recipient, _shared_report(wolf_a, SimTypes.Species.WOLF, Vector2(150, 100), 10, 130), 14)
	_queue_report(ai, sender, recipient, _shared_report(wolf_a, SimTypes.Species.WOLF, Vector2(155, 100), 12, 132), 14)
	_queue_report(ai, sender, recipient, _shared_report(wolf_a, SimTypes.Species.WOLF, Vector2(152, 100), 11, 131), 14)
	_queue_report(ai, sender, recipient, _shared_report(wolf_b, SimTypes.Species.WOLF, Vector2(180, 100), 13, 133), 14)
	_queue_report(ai, sender, recipient, _shared_report(wolf_c, SimTypes.Species.WOLF, Vector2(999, 999), 13, 133), 14)
	_queue_report(ai, sender, recipient, _shared_report(expired_target, SimTypes.Species.WOLF, Vector2(200, 100), 1, 14), 14)
	_queue_report(ai, sender, other, _shared_report(wolf_a, SimTypes.Species.WOLF, Vector2(155, 100), 12, 132), 14)
	_queue_report(ai, sender, recipient, _shared_report(wolf_b, SimTypes.Species.WOLF, Vector2(181, 100), 14, 134), 15)
	var old_sender: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	store.remove_agent(old_sender)
	store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	_queue_report(ai, old_sender, recipient, _shared_report(expired_target, SimTypes.Species.WOLF, Vector2(200, 100), 13, 133), 14)
	var old_recipient: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	store.remove_agent(old_recipient)
	var fresh_recipient: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2.ZERO)
	ai.register_agent(fresh_recipient, 0)
	_queue_report(ai, sender, old_recipient, _shared_report(wolf_a, SimTypes.Species.WOLF, Vector2(155, 100), 12, 132), 14)
	var old_target: AgentHandle = store.create_agent(SimTypes.Species.WOLF, Vector2.ZERO)
	store.remove_agent(old_target)
	store.create_agent(SimTypes.Species.WOLF, Vector2.ZERO)
	var stale: LocalObservation = _shared_report(old_target, SimTypes.Species.WOLF, Vector2.ZERO, 13, 133)
	_queue_report(ai, sender, recipient, stale, 14)
	ai.knowledge.deliver(ai, 14)
	_check(counted.refreshes.get(recipient.slot, 0) == 1 and counted.refreshes.get(other.slot, 0) == 1 and counted.refreshes.size() == 2, "All same-step reports refresh each changed recipient exactly once")
	_check(ai.wakeups.get(recipient.slot, 0) == 1 and ai.wakeups.get(other.slot, 0) == 1 and ai.wakeups.size() == 2, "A shared batch wakes each changed recipient exactly once")
	var newest: LocalObservation = context.observations[wolf_a.slot]
	_check(newest.observed_tick == 12 and newest.expires_tick == 132 and newest.position == Vector2(155, 100), "Out-of-order reports preserve the newest original sighting and its TTL")
	_check(context.observations[wolf_c.slot] == direct and direct.source == LocalObservation.Source.DIRECT and direct.position == Vector2(110, 100), "Equal-age sharing cannot replace a direct sighting")
	_check(context.threat == direct, "Derived threat is selected from the complete merged snapshot")
	_check(context.last_perception_tick == 7 and context.current_tick == 14, "Shared refresh advances simulation knowledge time but not direct-perception time")
	_check(not context.observations.has(expired_target.slot), "Expired-at-boundary reports and stale-sender reports are rejected in a mixed batch")
	_check(not context.observations.has(old_target.slot) and ai.contexts[fresh_recipient.slot].observations.is_empty(), "Stale target and recipient generations cannot reach reused slots")
	_check(ai.knowledge.pending.size() == 1, "Batch processing retains reports scheduled for a future step")
	_check(not ai.perception.merge_shared(context, stale, 14), "Direct merge callers also reject an old target generation")
	ai.knowledge.deliver(ai, 15)
	_check(counted.refreshes.get(recipient.slot, 0) == 2 and ai.wakeups.get(recipient.slot, 0) == 2 and ai.knowledge.pending.is_empty(), "Future report refreshes and wakes once on its due step")
	var future: LocalObservation = context.observations[wolf_b.slot]
	_check(future.observed_tick == 14 and future.expires_tick == 134, "Delayed delivery does not renew the original expiry")
	_queue_report(ai, sender, recipient, future.copy_sighting(), 16)
	ai.knowledge.deliver(ai, 16)
	_check(counted.refreshes.get(recipient.slot, 0) == 2 and ai.wakeups.get(recipient.slot, 0) == 2, "An unchanged batch neither refreshes facts nor wakes decisions")
	counted.refreshes.clear()
	ai.grid.rebuild(store)
	ai.perception.update(context, 16)
	_check(counted.refreshes.get(recipient.slot, 0) == 1 and context.last_perception_tick == 16, "A direct sensing job still performs exactly one complete refresh")
	ai.queue_free()
	await process_frame

func _test_cross_step_stage_fairness() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	var ai := SingleJobBudgetCoordinator.new()
	root.add_child(ai)
	ai.setup(store, SpatialGrid.new(config.world_size, config.cell_size), ResourceGrid.new(config), IntentBuffer.new(), config)
	for index: int in range(30):
		var handle: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(200 + index, 200))
		ai.register_agent(handle, 0)
	await process_frame
	var perceptions: int = 0
	var decisions: int = 0
	var first_stages: Array[int] = []
	for tick: int in range(20):
		ai.begin_frame()
		ai.begin_step(tick)
		ai.grid.rebuild(store)
		ai.step(tick)
		perceptions += ai.last_perception_jobs
		decisions += ai.last_decision_jobs
		if tick < 4:
			first_stages.append(ai.last_perception_jobs)
	_check(perceptions == 10 and decisions == 10, "A one-job budget serves both backlogged stages across step and frame boundaries")
	_check(first_stages == [1, 0, 1, 0], "A budget-consuming perception job leaves a decision first on the next step")
	ai.queue_free()
	await process_frame

func _test_cross_step_urgent_fairness() -> void:
	var store := AgentStore.new()
	var config := SimulationConfig.new()
	config.perception_jobs = 0
	var ai := SingleJobBudgetCoordinator.new()
	root.add_child(ai)
	ai.setup(store, SpatialGrid.new(config.world_size, config.cell_size), ResourceGrid.new(config), IntentBuffer.new(), config)
	var normals: Array[AgentHandle] = []
	for index: int in range(13):
		var handle: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(200 + index, 200))
		ai.register_agent(handle, 0)
		normals.append(handle)
	var urgent: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(250, 200))
	ai.register_agent(urgent, 0)
	await process_frame
	for tick: int in range(8):
		ai.wake_for_observation(ai.contexts[urgent.slot], tick)
		ai.begin_frame()
		ai.begin_step(tick)
		ai.step(tick)
	var served_normals: int = 0
	for handle: AgentHandle in normals:
		if ai.contexts[handle.slot].last_decision_tick > 0:
			served_normals += 1
	_check(served_normals == 6, "Persistent urgent traffic leaves six of eight one-job dispatches for normal FIFO work")
	_check(ai.contexts[urgent.slot].last_decision_tick == 4, "Urgent quota survives eight separate frame-budget resets")
	ai.queue_free()
	await process_frame

func _test_probes() -> void:
	var probes := Probes.new(true)
	for index: int in 4100:
		probes.begin_step(index)
		probes.record(Probes.Tag.DECISION, 8)
		probes.job(Probes.Tag.DECISION, SimTypes.Species.WOLF, 8, 0, 3, Probes.Task.HUNT, 12)
		probes.count_job(Probes.Counter.DECISION_SERVED)
		probes.end_step()
	var group: int = SimTypes.Species.WOLF * Probes.Tag.size() + Probes.Tag.DECISION
	_check(probes.counts[Probes.Tag.DECISION] == 4100 and probes.sums[Probes.Tag.DECISION] == 32800 and probes.maxima[Probes.Tag.DECISION] == 8, "Probe aggregates include records overwritten in the bounded ring")
	_check(probes.histogram[group * 64 + 4] == 4100 and probes.job_counts[group] == 4100, "Power-of-two histogram boundary retains the complete job distribution")
	_check(probes.ring.size() == 4096 * 8 and probes.ring[0] == 4096 and probes.queue_ring.size() == 4096 * 14, "Job and queue rings wrap without capacity growth")
	probes.reset_window()
	_check(probes.written == 0 and probes.queue_written == 0 and probes.counts[Probes.Tag.DECISION] == 0 and probes.ring[0] == 4096, "Window reset clears aggregates and cursors but reuses ring storage")
