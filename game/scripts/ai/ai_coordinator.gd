class_name AICoordinator
extends Node
enum Stage { PERCEPTION, DECISION }
class DecisionEntry extends RefCounted:
	var handle: AgentHandle
	var ticket: int
	var _due_tick: int
	var due_tick: int:
		get: return _due_tick

	func _init(agent_handle: AgentHandle, request_ticket: int, request_due_tick: int) -> void:
		handle = agent_handle
		ticket = request_ticket
		_due_tick = request_due_tick

## Public AI boundary. Time buckets enqueue once; FIFO queues retain deferred work.
## One shared render-frame wall-clock budget covers all fixed-step catch-up calls.
var probes: Probes
var store: AgentStore
var grid: SpatialGrid
var resources: ResourceGrid
var intents: IntentBuffer
var config: SimulationConfig
var settings := AISettings.new()
var contexts: Dictionary[int, AgentContext] = {}
var coordination := CoordinationSystem.new()
var perception := PerceptionSystem.new()
var knowledge := LocalKnowledgeBroker.new()
var last_perception_jobs: int = 0
var last_decision_jobs: int = 0
var max_decision_delay_ticks: int = 0
var max_perception_delay_ticks: int = 0
var budget_exhaustions: int = 0
var frame_used_usec: int = 0
var current_tick: int = 0
var _trees: Array[BehaviorTree] = []
var _pools: Array[Array] = [[], [], []]
var _perception_due: Dictionary[int, Array] = {}
var _decision_due: Dictionary[int, Array] = {}
var _perception_queue: Array[AgentHandle] = []
var _decision_queue: Array[DecisionEntry] = []
var _urgent_queue: Array[DecisionEntry] = []
var _perception_head: int = 0
var _decision_head: int = 0
var _urgent_head: int = 0
# This stage cursor survives both fixed-step and render-frame boundaries.
var _next_stage: Stage = Stage.PERCEPTION

func _init(instrumentation: Probes = null) -> void:
	probes = instrumentation if instrumentation != null else Probes.new()

func setup(agent_store: AgentStore, spatial_grid: SpatialGrid, resource_grid: ResourceGrid, intent_buffer: IntentBuffer, simulation_config: SimulationConfig) -> void:
	store = agent_store
	grid = spatial_grid
	resources = resource_grid
	intents = intent_buffer
	config = simulation_config
	coordination.setup(store, config, settings)
	_trees.assign([
		load("res://ai/trees/sheep.tres") as BehaviorTree,
		load("res://ai/trees/wolf.tres") as BehaviorTree,
		load("res://ai/trees/dog.tres") as BehaviorTree,
	])
	for tree: BehaviorTree in _trees:
		assert(tree != null, "The three formal behavior tree resources must load.")

func register_agent(handle: AgentHandle, created_tick: int = -1) -> void:
	var birth_tick: int = current_tick if created_tick < 0 else created_tick
	var dense: int = store.resolve(handle)
	assert(dense >= 0)
	var species: int = store.species[dense]
	var context: AgentContext
	if not _pools[species].is_empty():
		context = _pools[species].pop_back() as AgentContext
	else:
		context = AgentContext.new()
		context.coordinator = self
		context.species = species
		context.name = "AgentContext"
		add_child(context)
		context.player = BTPlayer.new()
		context.player.name = "BehaviorTree"
		context.player.update_mode = BTPlayer.MANUAL
		context.player.blackboard = Blackboard.new()
		context.player.blackboard.set_var(AIBlackboard.CONTEXT, context)
		context.player.set_scene_root_hint(context)
		context.player.behavior_tree = _trees[species]
		context.add_child(context.player)
	context.handle = handle
	context.current_tick = birth_tick
	context.last_decision_tick = birth_tick
	context.last_perception_tick = -1
	context.safe_after_tick = 0
	context.commit_until = 0
	context.pursuit_until = 0
	context.intercept_rest_until = 0
	context.feeding_until = 0
	context.flock_count = 0
	context.protection_anchor = store.position_current[dense]
	context.flock_center = context.protection_anchor
	context.wander_until = 0
	context.task_name = &"Waiting for first perception"
	context.player.active = true
	contexts[handle.slot] = context
	_schedule_perception(context, birth_tick + handle.slot % settings.calm_perception_ticks)
	_schedule_decision(context, birth_tick + handle.slot % settings.calm_decision_ticks)

func unregister_agent(handle: AgentHandle) -> void:
	var context: AgentContext = _context(handle)
	if context == null:
		return
	context.clear_runtime()
	coordination.remove(handle)
	knowledge.remove(handle)
	intents.remove(handle)
	contexts.erase(handle.slot)
	_pools[context.species].append(context)

func reset() -> void:
	for slot: int in contexts:
		var context: AgentContext = contexts[slot]
		context.clear_runtime()
		_pools[context.species].append(context)
	contexts.clear()
	coordination.clear()
	knowledge.clear()
	_perception_due.clear()
	_decision_due.clear()
	_perception_queue.clear()
	_decision_queue.clear()
	_urgent_queue.clear()
	_perception_head = 0
	_decision_head = 0
	_urgent_head = 0
	_next_stage = Stage.PERCEPTION
	current_tick = 0
	frame_used_usec = 0
	last_perception_jobs = 0
	last_decision_jobs = 0
	max_decision_delay_ticks = 0
	max_perception_delay_ticks = 0
	budget_exhaustions = 0

func begin_frame() -> void:
	frame_used_usec = 0

func begin_step(tick: int) -> void:
	if probes.enabled:
		probes.begin_step(tick)
	current_tick = tick
	var started: int = Time.get_ticks_usec()
	coordination.begin_step(tick)
	var delivery_start: int = Time.get_ticks_usec() if probes.enabled else 0
	if probes.enabled:
		probes.record(Probes.Tag.COORDINATION, delivery_start - started)
	knowledge.deliver(self, tick)
	if probes.enabled:
		probes.record(Probes.Tag.DELIVERY, Time.get_ticks_usec() - delivery_start)
	if probes.enabled:
		probes.record(Probes.Tag.BEGIN_STEP, Time.get_ticks_usec() - started)
	frame_used_usec += Time.get_ticks_usec() - started

func step(tick: int) -> void:
	current_tick = tick
	last_perception_jobs = 0
	last_decision_jobs = 0
	var started: int = Time.get_ticks_usec()
	_enqueue_due(tick)
	if probes.enabled:
		probes.record(Probes.Tag.ENQUEUE, Time.get_ticks_usec() - started)
	# A costly final job leaves the other stage first in line on the next step.
	while _has_work() and _budget_available(started):
		if not _run_next_job(tick):
			break
	_compact_queues()
	frame_used_usec += Time.get_ticks_usec() - started
	if _has_work() and frame_used_usec >= config.ai_budget_usec:
		budget_exhaustions += 1
		if probes.enabled:
			probes.count_job(Probes.Counter.BUDGET_EXHAUSTED)

func _run_next_job(tick: int) -> bool:
	var preferred: Stage = _next_stage
	var alternate: Stage = Stage.DECISION if preferred == Stage.PERCEPTION else Stage.PERCEPTION
	if _try_stage(preferred, tick):
		_next_stage = alternate
		return true
	if _try_stage(alternate, tick):
		_next_stage = preferred
		return true
	return false

func _try_stage(stage: Stage, tick: int) -> bool:
	if stage == Stage.PERCEPTION:
		return last_perception_jobs < config.perception_jobs and _run_perception(tick)
	return last_decision_jobs < config.decision_jobs and _run_decision(tick)

func _budget_available(started: int) -> bool:
	return frame_used_usec + Time.get_ticks_usec() - started < config.ai_budget_usec

func _has_work() -> bool:
	return _perception_head < _perception_queue.size() or _decision_head < _decision_queue.size() or _urgent_head < _urgent_queue.size()

func _context(handle: AgentHandle) -> AgentContext:
	var context: AgentContext = contexts.get(handle.slot)
	if context == null or not context.handle.same_life(handle):
		return null
	return context

func _schedule_perception(context: AgentContext, due_tick: int) -> void:
	context.next_perception_tick = due_tick
	if not _perception_due.has(due_tick):
		_perception_due[due_tick] = []
	_perception_due[due_tick].append(context.handle)

func _schedule_decision(context: AgentContext, due_tick: int) -> void:
	context.next_decision_tick = due_tick
	if not _decision_due.has(due_tick):
		_decision_due[due_tick] = []
	_decision_due[due_tick].append(context.handle)

func _enqueue_due(tick: int) -> void:
	if _perception_due.has(tick):
		for handle: AgentHandle in _perception_due[tick]:
			var context: AgentContext = _context(handle)
			if context != null and not context.perception_queued and context.next_perception_tick == tick:
				context.perception_queued = true
				_perception_queue.append(handle)
		_perception_due.erase(tick)
	if _decision_due.has(tick):
		for handle: AgentHandle in _decision_due[tick]:
			var context: AgentContext = _context(handle)
			if context != null and not context.decision_queued and context.next_decision_tick == tick:
				context.decision_ticket += 1
				context.decision_queued = true
				_decision_queue.append(DecisionEntry.new(handle, context.decision_ticket, tick))
		_decision_due.erase(tick)

func _request_urgent(context: AgentContext, tick: int) -> void:
	if context.urgent_queued:
		return
	context.next_decision_tick = mini(context.next_decision_tick, tick)
	if not context.decision_queued:
		context.decision_ticket += 1
	context.decision_queued = true
	context.urgent_queued = true
	_urgent_queue.append(DecisionEntry.new(context.handle, context.decision_ticket, context.next_decision_tick))

func _run_perception(tick: int) -> bool:
	while _perception_head < _perception_queue.size():
		var handle: AgentHandle = _perception_queue[_perception_head]
		_perception_head += 1
		var context: AgentContext = _context(handle)
		if context == null or not context.perception_queued:
			if probes.enabled:
				probes.count_job(Probes.Counter.PERCEPTION_STALE)
			continue
		context.current_tick = tick
		context.perception_queued = false
		max_perception_delay_ticks = maxi(max_perception_delay_ticks, tick - context.next_perception_tick)
		var was_alert: bool = context.is_alert()
		var job_start: int = Time.get_ticks_usec() if probes.enabled else 0
		var candidates_before: int = grid.candidate_count
		perception.update(context, tick)
		var publish_start: int = Time.get_ticks_usec() if probes.enabled else 0
		knowledge.publish(context)
		if probes.enabled:
			probes.record(Probes.Tag.PUBLISH, Time.get_ticks_usec() - publish_start)
			var elapsed_us: int = Time.get_ticks_usec() - job_start
			probes.record(Probes.Tag.PERCEPTION_JOB, elapsed_us)
			probes.job(Probes.Tag.PERCEPTION_JOB, context.species, elapsed_us, grid.candidate_count - candidates_before, context.observations.size())
			probes.count_job(Probes.Counter.PERCEPTION_SERVED)
		if was_alert != context.is_alert():
			_request_urgent(context, tick)
		var interval: int = settings.alert_perception_ticks if context.is_alert() else settings.calm_perception_ticks
		_schedule_perception(context, tick + interval)
		last_perception_jobs += 1
		return true
	return false

func _peek_decision(urgent: bool) -> DecisionEntry:
	var queue: Array[DecisionEntry] = _urgent_queue if urgent else _decision_queue
	var head: int = _urgent_head if urgent else _decision_head
	while head < queue.size():
		var entry: DecisionEntry = queue[head]
		var context: AgentContext = _context(entry.handle)
		var current_request: bool = context != null and context.decision_queued and context.decision_ticket == entry.ticket
		if current_request and context.urgent_queued == urgent:
			break
		# Promotion cancels the normal copy, but remains the same live request.
		# Superseded tickets and removed lives count as stale physical entries.
		if not current_request or urgent:
			if probes.enabled:
				probes.count_job(Probes.Counter.URGENT_STALE if urgent else Probes.Counter.DECISION_STALE)
		head += 1
	if urgent:
		_urgent_head = head
	else:
		_decision_head = head
	return queue[head] if head < queue.size() else null

func _run_decision(tick: int) -> bool:
	var normal_entry: DecisionEntry = _peek_decision(false)
	var urgent_entry: DecisionEntry = _peek_decision(true)
	if normal_entry == null and urgent_entry == null:
		return false
	# Compare the two live FIFO heads by original due time; urgency breaks ties.
	# Promotion retains age but does not reorder the urgent FIFO, so this is not
	# a global earliest-deadline sort and does not scan or sort whole queues.
	var urgent: bool = urgent_entry != null and (normal_entry == null or urgent_entry.due_tick <= normal_entry.due_tick)
	var entry: DecisionEntry = urgent_entry if urgent else normal_entry
	if urgent:
		_urgent_head += 1
	else:
		_decision_head += 1
	var context: AgentContext = _context(entry.handle)
	context.decision_queued = false
	context.urgent_queued = false
	context.current_tick = tick
	max_decision_delay_ticks = maxi(max_decision_delay_ticks, tick - entry.due_tick)
	if context.player.get_bt_instance() != null:
		var elapsed: float = float(maxi(1, tick - context.last_decision_tick)) * config.fixed_dt
		var update_start: int = Time.get_ticks_usec() if probes.enabled else 0
		context.player.update(elapsed)
		if probes.enabled:
			var elapsed_us: int = Time.get_ticks_usec() - update_start
			probes.record(Probes.Tag.DECISION, elapsed_us)
			probes.job(Probes.Tag.DECISION, context.species, elapsed_us, 0, context.observations.size(), probes.task_names.find(context.task_name), tick - context.last_decision_tick)
			probes.count_job(Probes.Counter.DECISION_SERVED)
			if urgent:
				probes.count_job(Probes.Counter.URGENT_SERVED)
	context.last_decision_tick = tick
	var interval: int = settings.alert_decision_ticks if context.is_alert() else settings.calm_decision_ticks
	_schedule_decision(context, tick + interval)
	last_decision_jobs += 1
	return true

func _compact_queues() -> void:
	if _perception_head > 1024 or _perception_head == _perception_queue.size():
		_perception_queue = _perception_queue.slice(_perception_head)
		_perception_head = 0
	if _decision_head > 1024 or _decision_head == _decision_queue.size():
		_decision_queue = _decision_queue.slice(_decision_head)
		_decision_head = 0
	if _urgent_head > 1024 or _urgent_head == _urgent_queue.size():
		_urgent_queue = _urgent_queue.slice(_urgent_head)
		_urgent_head = 0

func notify_capture(actor: AgentHandle, position: Vector2, end_tick: int) -> void:
	var context: AgentContext = _context(actor)
	if context == null:
		return
	context.feeding_position = position
	context.feeding_until = end_tick
	context.prey = null
	context.committed_target = null
	coordination.remove(actor)
	_request_urgent(context, current_tick)

func is_feeding(handle: AgentHandle, tick: int) -> bool:
	var context: AgentContext = _context(handle)
	return context != null and tick < context.feeding_until

func describe(handle: AgentHandle, tick: int) -> String:
	var context: AgentContext = _context(handle)
	if context == null:
		return "AI context unavailable"
	var lease: CoordinationSystem.Lease = coordination.get_lease(handle, tick)
	var lease_text: String = "none"
	if lease != null:
		lease_text = "%s until %d" % [CoordinationSystem.Role.keys()[lease.role], lease.expires_tick]
	return "task=%s | sight age=%dt | lease=%s\nnext perception=%d decision=%d | memory=%d" % [context.task_name, tick - context.last_perception_tick, lease_text, context.next_perception_tick, context.next_decision_tick, context.observations.size()]
func wake_for_observation(context: AgentContext, tick: int) -> void:
	_request_urgent(context, tick)

func sample_pending(tick: int) -> void:
	probes.queues.fill(0)
	# Read-only scan of live queued contexts; stale physical entries are excluded.
	for slot: int in contexts:
		var context: AgentContext = contexts[slot]
		if context.perception_queued:
			probes.queues[0] += 1
			probes.queues[3] = maxi(probes.queues[3], tick - context.next_perception_tick)
		if context.decision_queued:
			var category: int = 2 if context.urgent_queued else 1
			probes.queues[category] += 1
			probes.queues[category + 3] = maxi(probes.queues[category + 3], tick - context.next_decision_tick)
