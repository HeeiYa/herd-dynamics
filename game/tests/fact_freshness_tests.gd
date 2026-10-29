extends SceneTree
## Decisions must use valid local facts even when sensing is deferred.
class CountingGrid extends SpatialGrid:
	var queries: int = 0

	func query(center: Vector2, search_radius: float, species_filter: int, store: AgentStore, output: Array[int]) -> void:
		queries += 1
		super.query(center, search_radius, species_filter, store, output)

	func query_flock(center: Vector2, search_radius: float, store: AgentStore, output: SpatialGrid.FlockSample) -> void:
		queries += 1
		super.query_flock(center, search_radius, store, output)

	func query_peers(center: Vector2, search_radius: float, species_filter: int, store: AgentStore, output: Array[AgentHandle], max_results: int, exclude: AgentHandle) -> void:
		queries += 1
		super.query_peers(center, search_radius, species_filter, store, output, max_results, exclude)

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
	await _test_expired_nearest_threat()
	await _test_expired_flock_memory()
	await _test_dead_and_reused_threat()
	await _test_shared_direct_provenance()
	await _test_compact_flock_expiry()
	await _test_compact_dog_anchor_expiry()
	await _test_compact_local_communication()
	await _test_observer_crosses_known_risk()
	await _test_individual_flock_tracks_observer()
	print("FACT_FRESHNESS_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _new_ai(compact_flock: bool = false) -> AICoordinator:
	var config := SimulationConfig.new()
	config.compact_flock_knowledge = compact_flock
	var ai := AICoordinator.new()
	root.add_child(ai)
	ai.setup(AgentStore.new(), CountingGrid.new(config.world_size, config.cell_size), ResourceGrid.new(config), IntentBuffer.new(), config)
	return ai

func _observer(ai: AICoordinator, kind: int, position: Vector2 = Vector2(500, 500)) -> AgentContext:
	var handle: AgentHandle = ai.store.create_agent(kind, position)
	# Future schedules keep the fixture's explicit decision dispatch independent
	# of periodic sensing; the production BT and decision entry are still used.
	ai.register_agent(handle, 1000)
	return ai.contexts[handle.slot]

func _sighting(context: AgentContext, kind: int, position: Vector2, observed_tick: int, expires_tick: int) -> LocalObservation:
	var sighting := LocalObservation.new()
	sighting.handle = context.coordinator.store.create_agent(kind, position)
	sighting.species = kind
	sighting.position = position
	sighting.observed_tick = observed_tick
	sighting.last_direct_tick = observed_tick
	sighting.expires_tick = expires_tick
	sighting.source = LocalObservation.Source.DIRECT
	context.observations[sighting.handle.slot] = sighting
	return sighting

func _decide(ai: AICoordinator, context: AgentContext, tick: int) -> MotionIntent:
	ai._request_urgent(context, tick)
	_check(ai._run_decision(tick), "The real decision queue dispatches the requested BT update")
	return ai.intents.get_intent(context.handle, tick)

func _test_expired_nearest_threat() -> void:
	var ai: AICoordinator = _new_ai()
	var sheep: AgentContext = _observer(ai, SimTypes.Species.SHEEP)
	var nearer: LocalObservation = _sighting(sheep, SimTypes.Species.WOLF, Vector2(520, 500), 0, 120)
	var farther: LocalObservation = _sighting(sheep, SimTypes.Species.WOLF, Vector2(460, 500), 30, 150)
	await process_frame
	ai.perception.refresh_shared_facts(sheep, 119)
	sheep.last_perception_tick = 30
	_check(sheep.threat == nearer and sheep.safe_after_tick < 120, "Fixture selects the near threat before its TTL and safety deadline expire")
	var first: MotionIntent = _decide(ai, sheep, 119)
	_check(first != null and first.behavior == SimTypes.Behavior.FLEE, "Valid first threat enters the real flee branch")
	# The known second threat is deliberately moved out of range. A decision
	# refresh may reuse its recorded position but must not query its live state.
	ai.store.position_current[ai.store.resolve(farther.handle)] = Vector2(1400, 900)
	var intent: MotionIntent = _decide(ai, sheep, 120)
	_check(sheep.threat == farther, "An expired selected threat is replaced by another still-valid local memory before BT evaluation")
	_check(intent != null and intent.behavior == SimTypes.Behavior.FLEE and intent.target == farther.handle, "The BT keeps fleeing from the remaining valid threat at the exact expiry boundary")
	_check(intent != null and intent.destination.x > 500, "Flee direction uses the recorded threat position rather than its unseen live position")
	_check(sheep.last_perception_tick == 30 and (ai.grid as CountingGrid).queries == 0, "Decision-time fact maintenance does not scan the grid or advance direct visibility")
	_decide(ai, sheep, 150)
	_check(sheep.threat == null and not sheep.is_alert(), "When all threats and safety memory expire, stale references do not keep alert scheduling active")
	_check(sheep.task_name != &"flee_threat", "The real BT leaves fleeing when no valid threat or safety hold remains")
	ai.queue_free()
	await process_frame

func _test_expired_flock_memory() -> void:
	var ai: AICoordinator = _new_ai()
	var wolf: AgentContext = _observer(ai, SimTypes.Species.WOLF)
	_sighting(wolf, SimTypes.Species.SHEEP, Vector2(700, 500), 10, 130)
	_sighting(wolf, SimTypes.Species.SHEEP, Vector2(720, 500), 10, 130)
	await process_frame
	ai.perception.refresh_shared_facts(wolf, 129)
	_check(wolf.flock_count == 2, "Fixture has two valid remembered sheep before their deadline")
	var intent: MotionIntent = _decide(ai, wolf, 130)
	_check(wolf.flock_count == 0, "Decision-time group facts exclude all sheep memories at their exact TTL")
	_check(wolf.prey == null and wolf.task_name == &"search_area", "The real wolf BT uses the no-prey fallback after all evidence expires")
	_check(intent != null and intent.target == null and (ai.grid as CountingGrid).queries == 0, "Expired-memory fallback creates no live target lookup or hidden new scan")
	ai.queue_free()
	await process_frame

func _test_dead_and_reused_threat() -> void:
	var ai: AICoordinator = _new_ai()
	var wolf: AgentContext = _observer(ai, SimTypes.Species.WOLF)
	var nearer: LocalObservation = _sighting(wolf, SimTypes.Species.DOG, Vector2(520, 500), 100, 220)
	var farther: LocalObservation = _sighting(wolf, SimTypes.Species.DOG, Vector2(460, 500), 100, 220)
	await process_frame
	ai.perception.refresh_shared_facts(wolf, 119)
	_check(wolf.threat == nearer, "Fixture selects the nearer living dog")
	ai.store.mark_dead(nearer.handle)
	ai.store.remove_agent(nearer.handle)
	var replacement: AgentHandle = ai.store.create_agent(SimTypes.Species.DOG, Vector2(510, 500))
	_check(replacement.slot == nearer.handle.slot and not replacement.same_life(nearer.handle), "Lifecycle fixture reuses the slot with a different full identity")
	var intent: MotionIntent = _decide(ai, wolf, 120)
	_check(wolf.threat == farther, "A lifecycle change reselects the remaining known threat before its own TTL expires")
	_check(intent != null and intent.behavior == SimTypes.Behavior.RETREAT and intent.target == farther.handle, "The real wolf BT retreats from valid recorded danger after a nearer life is removed")
	_check(wolf.observation_for(nearer.handle) == null and wolf.observation_for(replacement) == null, "Slot reuse never grants knowledge of the replacement life")
	ai.store.mark_dead(farther.handle)
	_decide(ai, wolf, 121)
	_check(wolf.threat == null and wolf.task_name != &"flee_threat", "The last threat's logical death clears the BT danger fact before structural removal")
	_check((ai.grid as CountingGrid).queries == 0, "Lifecycle invalidation refreshes only existing knowledge")
	ai.queue_free()
	await process_frame

func _test_shared_direct_provenance() -> void:
	var ai: AICoordinator = _new_ai()
	var sheep: AgentContext = _observer(ai, SimTypes.Species.SHEEP)
	var direct: LocalObservation = _sighting(sheep, SimTypes.Species.WOLF, Vector2(460, 500), 100, 220)
	sheep.last_perception_tick = 100
	await process_frame
	ai.perception.refresh_shared_facts(sheep, 100)
	var shared: LocalObservation = direct.copy_sighting()
	shared.position = Vector2(450, 500)
	shared.observed_tick = 101
	shared.expires_tick = 221
	_check(ai.perception.merge_shared(sheep, shared, 102), "Newer shared information replaces the prior local observation")
	ai.perception.refresh_shared_facts(sheep, 102)
	var intent: MotionIntent = _decide(ai, sheep, 102)
	_check(intent != null and intent.behavior == SimTypes.Behavior.FLEE and intent.target == direct.handle, "Shared knowledge reaches the real flee branch")
	_check(shared.source == LocalObservation.Source.SHARED and shared.last_direct_tick == 100 and sheep.last_perception_tick == 100, "Decision maintenance preserves the receiver's independent direct-scan marker")
	_check(shared.observed_tick == 101 and shared.expires_tick == 221, "Decision maintenance never refreshes a shared observation's original evidence age")
	_check((ai.grid as CountingGrid).queries == 0, "Shared evidence does not trigger an implicit world scan")
	ai.queue_free()
	await process_frame

func _test_compact_flock_expiry() -> void:
	var ai: AICoordinator = _new_ai(true)
	var sheep: AgentContext = _observer(ai, SimTypes.Species.SHEEP)
	# Isolate flock expiry from the new hungry-foraging priority.
	ai.store.hunger[ai.store.resolve(sheep.handle)] = 0.1
	ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(650, 500))
	ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(670, 500))
	await process_frame
	ai.grid.rebuild(ai.store)
	sheep.current_tick = 10
	ai.perception.update(sheep, 10)
	var query_count: int = (ai.grid as CountingGrid).queries
	_check(sheep.flock_count == 3 and sheep.observations.is_empty(), "Compact sensing stores the whole local flock without per-sheep observations")
	_check(sheep.flock_sample_observed_tick == 10 and sheep.flock_sample_expires_tick == 130, "A flock sample has the original scan's bounded evidence age")
	var before: MotionIntent = _decide(ai, sheep, 129)
	_check(before != null and before.behavior == SimTypes.Behavior.REGROUP, "The real sheep BT regroups toward a still-valid compact sample")
	ai.store.position_current[ai.store.resolve(sheep.handle)] = Vector2(520, 500)
	var expired: MotionIntent = _decide(ai, sheep, 130)
	_check(sheep.flock_count == 1 and sheep.flock_center == Vector2(520, 500), "An expired compact flock falls back to the observer's current position")
	_check(expired != null and expired.behavior != SimTypes.Behavior.REGROUP, "The real sheep BT leaves regrouping at the compact sample's exact TTL")
	_check(sheep.last_perception_tick == 10 and (ai.grid as CountingGrid).queries == query_count, "Compact expiry does not rescan the world or renew direct visibility")
	ai.queue_free()
	await process_frame

func _test_compact_dog_anchor_expiry() -> void:
	var ai: AICoordinator = _new_ai(true)
	var dog: AgentContext = _observer(ai, SimTypes.Species.DOG)
	ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(650, 500))
	ai.store.create_agent(SimTypes.Species.SHEEP, Vector2(670, 500))
	var distant_wolf: AgentHandle = ai.store.create_agent(SimTypes.Species.WOLF, Vector2(1400, 900))
	await process_frame
	ai.grid.rebuild(ai.store)
	dog.current_tick = 10
	ai.perception.update(dog, 10)
	var query_count: int = (ai.grid as CountingGrid).queries
	var anchor: Vector2 = dog.protection_anchor
	_check(dog.flock_count == 2 and anchor == Vector2(660, 500), "Direct compact sensing establishes the dog's local protection anchor")
	var report := LocalObservation.new()
	report.handle = distant_wolf
	report.species = SimTypes.Species.WOLF
	report.position = Vector2(1400, 900)
	report.observed_tick = 129
	report.expires_tick = 249
	report.source = LocalObservation.Source.SHARED
	_check(ai.perception.merge_shared(dog, report, 129), "A new shared threat can arrive shortly before the flock sample expires")
	ai.perception.refresh_shared_facts(dog, 129)
	_check(dog.flock_sample_observed_tick == 10 and dog.flock_sample_expires_tick == 130, "Sharing a threat never renews the independent flock sample")
	var intent: MotionIntent = _decide(ai, dog, 130)
	_check(dog.flock_count == 0 and dog.protection_anchor == anchor, "Expired dog flock knowledge retains its last protection anchor without claiming live sheep")
	_check(intent != null and intent.destination == anchor and dog.task_name == &"search_last_flock", "An expired flock sample sends the dog toward the last observed region rather than guarding empty space")
	_check(dog.last_perception_tick == 10 and (ai.grid as CountingGrid).queries == query_count, "Dog fallback and sharing never manufacture a fresh flock scan")
	ai.queue_free()
	await process_frame

func _test_observer_crosses_known_risk() -> void:
	var ai: AICoordinator = _new_ai(true)
	var wolf: AgentContext = _observer(ai, SimTypes.Species.WOLF)
	var known_dog: LocalObservation = _sighting(wolf, SimTypes.Species.DOG, Vector2(620, 500), 100, 220)
	await process_frame
	ai.perception.refresh_shared_facts(wolf, 100)
	_check(wolf.threat == null, "A known dog outside risk distance does not initially cause retreat")
	ai.store.position_current[ai.store.resolve(wolf.handle)] = Vector2(540, 500)
	ai.store.position_current[ai.store.resolve(known_dog.handle)] = Vector2(1400, 900)
	var intent: MotionIntent = _decide(ai, wolf, 101)
	_check(wolf.threat == known_dog and intent != null and intent.behavior == SimTypes.Behavior.RETREAT, "The observer's own movement recomputes risk from the recorded dog position")
	_check(known_dog.observed_tick == 100 and (ai.grid as CountingGrid).queries == 0, "Recomputing risk does not manufacture a direct scan or read unseen movement")
	ai.queue_free()
	await process_frame

func _test_individual_flock_tracks_observer() -> void:
	var ai: AICoordinator = _new_ai(false)
	var sheep: AgentContext = _observer(ai, SimTypes.Species.SHEEP)
	var known_sheep: LocalObservation = _sighting(sheep, SimTypes.Species.SHEEP, Vector2(700, 500), 100, 220)
	sheep.last_perception_tick = 100
	await process_frame
	ai.perception.refresh_shared_facts(sheep, 100)
	_check(sheep.threat_observations.is_empty() and sheep.flock_center == Vector2(600, 500), "Individual flock memory includes the observer without any threat memory")
	ai.store.position_current[ai.store.resolve(sheep.handle)] = Vector2(540, 500)
	ai.store.position_current[ai.store.resolve(known_sheep.handle)] = Vector2(1400, 900)
	_decide(ai, sheep, 101)
	_check(sheep.flock_center == Vector2(620, 500) and sheep.flock_count == 2, "A moving observer updates its own contribution to the remembered flock before deciding")
	_check(known_sheep.position == Vector2(700, 500) and known_sheep.observed_tick == 100, "The other member's unseen movement never refreshes its recorded position or evidence age")
	_check(sheep.last_perception_tick == 100 and (ai.grid as CountingGrid).queries == 0, "Recomputing the individual flock center does not perform another spatial query")
	ai.perception.prepare_decision(sheep, 220)
	_check(sheep.flock_count == 1 and sheep.flock_center == Vector2(540, 500), "Expired individual flock memory retains only the observer")
	ai.store.position_current[ai.store.resolve(sheep.handle)] = Vector2(560, 500)
	ai.perception.prepare_decision(sheep, 221)
	_check(sheep.flock_center == Vector2(560, 500), "With no remembered flock or threats, the lone observer's center keeps following its movement")
	ai.queue_free()
	await process_frame

func _test_compact_local_communication() -> void:
	var ai: AICoordinator = _new_ai(true)
	var sender: AgentContext = _observer(ai, SimTypes.Species.SHEEP)
	var former_peer: AgentContext = _observer(ai, SimTypes.Species.SHEEP, Vector2(560, 500))
	var current_peer: AgentContext = _observer(ai, SimTypes.Species.SHEEP, Vector2(1000, 500))
	var second_hop: AgentContext = _observer(ai, SimTypes.Species.SHEEP, Vector2(800, 500))
	var wolf: AgentHandle = ai.store.create_agent(SimTypes.Species.WOLF, Vector2(440, 500))
	await process_frame
	ai.grid.rebuild(ai.store)
	sender.current_tick = 10
	ai.perception.update(sender, 10)
	_check(sender.flock_count == 2 and sender.observations.size() == 1, "Compact sensing remembers the wolf and aggregates peers without individual ally observations")
	# Recipient geometry must stand on its own even when a retained group sample
	# describes different peers from the currently published spatial snapshot.
	ai.store.position_current[ai.store.resolve(former_peer.handle)] = Vector2(1000, 600)
	ai.store.position_current[ai.store.resolve(current_peer.handle)] = Vector2(650, 500)
	ai.grid.rebuild(ai.store)
	ai.knowledge.publish(sender)
	_check(ai.knowledge.pending.size() == 1 and ai.knowledge.pending[0].recipient.same_life(current_peer.handle), "Only the currently reachable peer receives a report, independently of the old flock sample")
	ai.knowledge.deliver(ai, 10)
	_check(current_peer.observations.is_empty() and ai.knowledge.pending.size() == 1, "Compact communication still waits until the next simulation step")
	ai.knowledge.deliver(ai, 11)
	var received: LocalObservation = current_peer.observation_for(wolf)
	_check(received != null and received.source == LocalObservation.Source.SHARED, "The current peer receives shared evidence without needing an individual ally observation")
	_check(received != null and received.last_direct_tick == -1 and current_peer.last_perception_tick == -1, "A recipient that never scanned the wolf cannot inherit the sender's direct visibility")
	_check(received != null and received.observed_tick == 10 and received.expires_tick == 130, "Next-step delivery preserves the original observation timestamp and TTL")
	_check(former_peer.observations.is_empty(), "An out-of-range former peer receives no report from stale group knowledge")
	var intent: MotionIntent = _decide(ai, current_peer, 11)
	_check(intent != null and intent.behavior == SimTypes.Behavior.FLEE and intent.target != null and intent.target.same_life(wolf), "The broker wakeup drives the recipient's real flee branch")
	ai.knowledge.publish(current_peer)
	ai.knowledge.deliver(ai, 12)
	_check(ai.knowledge.pending.is_empty() and second_hop.observations.is_empty(), "A recipient cannot relay shared evidence to another nearby peer")
	var original: LocalObservation = sender.observations[wolf.slot]
	_check(original.source == LocalObservation.Source.DIRECT and original.last_direct_tick == 10, "Each delivered copy keeps the sender's direct provenance independent")
	ai.queue_free()
	await process_frame
