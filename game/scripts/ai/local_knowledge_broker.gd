class_name LocalKnowledgeBroker
extends RefCounted
## One-hop, bounded local communication. A copied report keeps the DIRECT sighting's
## timestamp and expiry; messages never manufacture fresh evidence by rebroadcast.
class Message extends RefCounted:
	var sender: AgentHandle
	var recipient: AgentHandle
	var sighting: LocalObservation
	var delivery_tick: int

var pending: Array[Message] = []
# Lifecycle changes happen outside delivery; slot keys deduplicate validated lives.
var _changed_recipients: Dictionary[int, AgentContext] = {}
var _visible_peers: Array[AgentHandle] = []

func publish(context: AgentContext) -> void:
	var ai: AICoordinator = context.coordinator
	if ai.settings.max_share_recipients <= 0:
		return
	var relevant_species: int = SimTypes.Species.SHEEP if context.species == SimTypes.Species.WOLF else SimTypes.Species.WOLF
	var report: LocalObservation
	var nearest: float = INF
	var origin: Vector2 = context.position()
	for slot: int in context.observations:
		var sighting: LocalObservation = context.observations[slot]
		if sighting.species != relevant_species or sighting.source != LocalObservation.Source.DIRECT or sighting.observed_tick != context.current_tick:
			continue
		var distance: float = origin.distance_squared_to(sighting.position)
		if distance < nearest:
			nearest = distance
			report = sighting
	if report == null:
		return
	if ai.config.compact_flock_knowledge:
		# Communication validates current geometry; aggregate flock knowledge is
		# not evidence that any remembered peer can still receive this report.
		var share_radius: float = minf(ai.config.perception_radius, ai.settings.cooperation_radius)
		ai.grid.query_peers(origin, share_radius, context.species, ai.store, _visible_peers, ai.settings.max_share_recipients, context.handle)
		for recipient: AgentHandle in _visible_peers:
			_send(context, recipient, report)
		_visible_peers.clear()
		return
	var recipients: int = 0
	for slot: int in context.observations:
		var ally: LocalObservation = context.observations[slot]
		if ally.species != context.species or ally.source != LocalObservation.Source.DIRECT or ally.observed_tick != context.current_tick:
			continue
		if origin.distance_to(ally.position) > ai.settings.cooperation_radius:
			continue
		_send(context, ally.handle, report)
		recipients += 1
		if recipients >= ai.settings.max_share_recipients:
			break

func _send(context: AgentContext, recipient: AgentHandle, report: LocalObservation) -> void:
	var message := Message.new()
	message.sender = context.handle
	message.recipient = recipient
	message.sighting = report.copy_sighting()
	message.delivery_tick = context.current_tick + 1
	pending.append(message)

func deliver(ai: AICoordinator, tick: int) -> void:
	var merge_start: int = Time.get_ticks_usec() if ai.probes.enabled else 0
	_changed_recipients.clear()
	var retained: int = 0
	for message: Message in pending:
		if message.delivery_tick > tick:
			pending[retained] = message
			retained += 1
			continue
		if not ai.store.is_alive(message.sender) or not ai.store.is_alive(message.recipient) or not ai.store.is_alive(message.sighting.handle):
			continue
		var recipient: AgentContext = ai.contexts.get(message.recipient.slot)
		if recipient == null or not recipient.handle.same_life(message.recipient):
			continue
		if ai.perception.merge_shared(recipient, message.sighting, tick):
			_changed_recipients[recipient.handle.slot] = recipient
	pending.resize(retained)
	if ai.probes.enabled:
		ai.probes.record(Probes.Tag.MERGE, Time.get_ticks_usec() - merge_start)
	# All reports are merged before any derived facts are rebuilt. Decision tasks
	# cannot run inside this phase, so only the complete recipient snapshot matters.
	for slot: int in _changed_recipients:
		var recipient: AgentContext = _changed_recipients[slot]
		ai.perception.refresh_shared_facts(recipient, tick)
		ai.wake_for_observation(recipient, tick)
	_changed_recipients.clear()

func remove(handle: AgentHandle) -> void:
	var retained: int = 0
	for message: Message in pending:
		if message.sender.same_life(handle) or message.recipient.same_life(handle) or message.sighting.handle.same_life(handle):
			continue
		pending[retained] = message
		retained += 1
	pending.resize(retained)

func clear() -> void:
	pending.clear()
	_changed_recipients.clear()
	_visible_peers.clear()
