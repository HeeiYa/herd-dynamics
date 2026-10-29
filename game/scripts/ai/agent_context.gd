class_name AgentContext
extends Node
## The only per-agent Node: private knowledge, BT instance, and strategy state.
## All authoritative physical data stays in AgentStore.
var coordinator: AICoordinator
var handle: AgentHandle
var species: int = SimTypes.Species.SHEEP
var player: BTPlayer
var observations: Dictionary[int, LocalObservation] = {}
# PerceptionSystem alone maintains these derived observation caches. For the
# individual-memory policy, the sheep sum excludes this observer.
var remembered_flock_sum: Vector2 = Vector2.ZERO
var remembered_flock_count: int = 0
var flock_cache_dirty: bool = true
var flock_cache_expires_tick: int = 0
var fact_cache_life_revision: int = -1
var facts_dirty: bool = true
var facts_expire_tick: int = 0
var facts_origin: Vector2 = Vector2.ZERO
# A direct flock sample is a fixed historical observation, replaced as a whole.
# It owns values rather than a reference to the query system's scratch sample.
var flock_sample_count: int = 0
var flock_sample_center: Vector2 = Vector2.ZERO
var flock_sample_observed_tick: int = -1
var flock_sample_expires_tick: int = 0
var threat_view_dirty: bool = true
var threat_observations: Array[LocalObservation] = []
# Indices refer only to threat_observations, never AgentStore dense indices.
var threat_view_indices: Dictionary[int, int] = {}
var threat: LocalObservation
var prey: LocalObservation
var dog_threat: LocalObservation
var flock_center: Vector2 = Vector2.ZERO
var flock_count: int = 0
var protection_anchor: Vector2 = Vector2.ZERO
var last_threat_position: Vector2 = Vector2.ZERO
var safe_after_tick: int = 0
var feeding_until: int = 0
var feeding_position: Vector2 = Vector2.ZERO
var committed_target: AgentHandle
var commit_until: int = 0
var pursuit_until: int = 0
var intercept_rest_until: int = 0
var returning_to_flock: bool = false
var retreating: bool = false
var last_flock_seen_tick: int = -1
var last_flock_searched_tick: int = -1
var grazing_committed: bool = false
var regrouping: bool = false
var grazing_retry_after_tick: int = 0
var rejected_prey: AgentHandle
var rejected_prey_until: int = 0
var next_perception_tick: int = 0
var next_decision_tick: int = 0
var perception_queued: bool = false
var decision_queued: bool = false
var urgent_queued: bool = false
# Distinguishes successive pending requests for one life, including promotion.
var decision_ticket: int = 0
var current_tick: int = 0
var last_decision_tick: int = 0
var last_perception_tick: int = -1
var task_name: StringName = &"Uninitialized"
var task_token: int = 0
var lease_token: int = 0
var wander_destination: Vector2 = Vector2.ZERO
var wander_until: int = 0
var exploration_history: PackedVector2Array = PackedVector2Array()
var exploration_history_cursor: int = 0
var exploration_sequence: int = 0
var exploration_progress_position: Vector2 = Vector2.ZERO
var exploration_progress_tick: int = 0
var _next_token: int = 1

func position() -> Vector2:
	var dense: int = coordinator.store.resolve(handle)
	if dense < 0:
		return protection_anchor
	return coordinator.store.position_current[dense]

func new_token() -> int:
	var token: int = _next_token
	_next_token += 1
	return token

func observation_for(target: AgentHandle) -> LocalObservation:
	if target == null:
		return null
	var observation: LocalObservation = observations.get(target.slot)
	if observation == null or not observation.handle.same_life(target):
		return null
	if current_tick >= observation.expires_tick or not coordinator.store.is_alive(target):
		return null
	return observation

func is_alert() -> bool:
	if current_tick < safe_after_tick:
		return true
	if threat != null and observation_for(threat.handle) != null:
		return true
	if dog_threat != null and observation_for(dog_threat.handle) != null:
		return true
	return prey != null and observation_for(prey.handle) != null

func clear_runtime() -> void:
	if player != null:
		player.active = false
		if player.get_bt_instance() != null:
			player.get_bt_instance().get_root_task().abort()
	observations.clear()
	remembered_flock_sum = Vector2.ZERO
	remembered_flock_count = 0
	flock_cache_dirty = true
	flock_cache_expires_tick = 0
	fact_cache_life_revision = -1
	facts_dirty = true
	facts_expire_tick = 0
	facts_origin = Vector2.ZERO
	flock_sample_count = 0
	flock_sample_center = Vector2.ZERO
	flock_sample_observed_tick = -1
	flock_sample_expires_tick = 0
	threat_view_dirty = true
	threat_observations.clear()
	threat_view_indices.clear()
	threat = null
	prey = null
	dog_threat = null
	committed_target = null
	rejected_prey = null
	rejected_prey_until = 0
	returning_to_flock = false
	retreating = false
	last_flock_seen_tick = -1
	last_flock_searched_tick = -1
	grazing_committed = false
	regrouping = false
	grazing_retry_after_tick = 0
	wander_destination = Vector2.ZERO
	wander_until = 0
	exploration_history.clear()
	exploration_history_cursor = 0
	exploration_sequence = 0
	exploration_progress_position = Vector2.ZERO
	exploration_progress_tick = 0
	feeding_until = 0
	lease_token = 0
	perception_queued = false
	decision_queued = false
	urgent_queued = false
	decision_ticket += 1
