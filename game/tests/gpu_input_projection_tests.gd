extends SceneTree
## Compare only GPU-consumed intent/phase columns against the existing scalar
## production packer. No RenderingDevice or duplicate movement algorithm is used.

class CountedIntents extends IntentBuffer:
	var lookups: int = 0

	func get_intent(handle: AgentHandle, tick: int) -> MotionIntent:
		lookups += 1
		return super.get_intent(handle, tick)

class CountedField extends CrowdMotionField:
	var classifications: int = 0

	func uses_dense_sample(dense: int, search_radius: float, enter_count: int, exit_count: int) -> bool:
		classifications += 1
		return super.uses_dense_sample(dense, search_radius, enter_count, exit_count)

class Fixture extends RefCounted:
	var store := AgentStore.new()
	var intents := CountedIntents.new()
	var config := SimulationConfig.new()
	var kernel := GpuMotionKernel.new()
	var scalar := GpuMotionKernel.new()
	var field: CountedField
	var reference_field: CountedField

	func _init(sparse: bool = false) -> void:
		field = CountedField.new(config.world_size, config.crowd_cell_size, sparse)
		reference_field = CountedField.new(config.world_size, config.crowd_cell_size, sparse)

	func close() -> void:
		kernel.close()
		scalar.close()

var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _intent(expires_tick: int = 1000, mode: int = SimTypes.IntentMode.MOVE, destination: Vector2 = Vector2(900, 500)) -> MotionIntent:
	var result := MotionIntent.new()
	result.expires_tick = expires_tick
	result.mode = mode
	result.destination = destination
	result.speed = 70.0
	result.behavior = SimTypes.Behavior.RETREAT
	result.owner_token = 7
	return result

func _populate(fixture: Fixture, count: int, expires_tick: int = 1000) -> void:
	for index: int in count:
		var handle: AgentHandle = fixture.store.create_agent(index % 3, Vector2(500, 500), 13.0)
		fixture.intents.write(handle, _intent(expires_tick))

func _compare(fixture: Fixture, tick: int, label: String) -> int:
	fixture.field.rebuild(fixture.store)
	fixture.reference_field.rebuild(fixture.store)
	fixture.field.classifications = 0
	fixture.reference_field.classifications = 0
	fixture.scalar._actors.resize(fixture.store.capacity * GpuMotionKernel.ACTOR_FLOATS)
	fixture.scalar._pack_actors(fixture.store, fixture.intents, fixture.reference_field, fixture.config, tick)
	var lookups_before: int = fixture.intents.lookups
	var bytes: PackedByteArray = fixture.kernel._pack_bulk(fixture.store, fixture.intents, fixture.field, fixture.config, tick)
	var lookup_delta: int = fixture.intents.lookups - lookups_before
	_check(bytes.size() == fixture.store.capacity * GpuMotionKernel.ACTOR_FLOATS * GpuMotionKernel.BYTES_PER_FLOAT, label + ": unchanged upload layout")
	for dense: int in fixture.store.count:
		var base: int = dense * GpuMotionKernel.ACTOR_FLOATS
		var expected := Vector4(
			fixture.scalar._actors[base + GpuMotionKernel.ActorColumn.DESTINATION_X],
			fixture.scalar._actors[base + GpuMotionKernel.ActorColumn.DESTINATION_Y],
			fixture.scalar._actors[base + GpuMotionKernel.ActorColumn.SPEED],
			fixture.scalar._actors[base + GpuMotionKernel.ActorColumn.MODE])
		_check(fixture.kernel._intent_records[dense] == expected, "%s: complete intent projection row %d" % [label, dense])
		var expected_life: int = GpuMotionKernel.LifeState.DEAD
		if fixture.store.alive[dense] != 0:
			expected_life = GpuMotionKernel.LifeState.HELD if fixture.store.held[dense] != 0 else GpuMotionKernel.LifeState.ACTIVE
		var expected_flags := Vector4(expected_life,
			fixture.scalar._actors[base + GpuMotionKernel.ActorColumn.DENSE_SAMPLE],
			fixture.scalar._actors[base + GpuMotionKernel.ActorColumn.RETREAT], 0.0)
		_check(fixture.kernel._phase_flags[dense] == expected_flags, "%s: unchanged participation and density row %d" % [label, dense])
	_check(fixture.kernel.field_agent_count == fixture.scalar.field_agent_count and fixture.kernel.exact_agent_count == fixture.scalar.exact_agent_count,
		label + ": same field/exact denominators")
	_check(fixture.field.classifications == fixture.reference_field.classifications,
		label + ": same classification calls; no skipped density updates")
	return lookup_delta

func _check_stable_and_ttl() -> void:
	var fixture := Fixture.new()
	_populate(fixture, 3, 5)
	_check(_compare(fixture, 0, "initial") == 3, "Initial active rows use complete lookups")
	var old_publication: IntentBuffer = fixture.intents.publication_copy()
	_check(_compare(fixture, 4, "stable before expiry") == 0, "Unchanged input skips object lookup and projection")
	_check(_compare(fixture, 5, "expiry tick") == 0, "TTL invalidates at n without a writer or new lookup")
	_check(fixture.kernel.field_agent_count + fixture.kernel.exact_agent_count == 0, "Expired intent stops classification immediately")
	_check(_compare(fixture, 6, "already expired") == 0, "Stable expired records remain cached")
	_check(_compare(fixture, 4, "explicit replay rewind") == 3, "Rewind rereads TTL rather than keeping an expired sentinel")
	_check(old_publication.get_intent(fixture.store.handle_at(0), 4) != null,
		"Old immutable publication remains valid at its historical tick")
	fixture.close()

func _check_mutations_and_buffer_identity() -> void:
	var fixture := Fixture.new()
	_populate(fixture, 1)
	var handle: AgentHandle = fixture.store.handle_at(0)
	_compare(fixture, 1, "first revision zero")
	fixture.intents.remove(handle)
	fixture.intents.write(handle, _intent(1000, SimTypes.IntentMode.FLEE, Vector2(300, 800)))
	_check(fixture.intents.get_intent(handle, 1).revision == 0, "ABA fixture returns to revision zero")
	_check(_compare(fixture, 2, "remove write ABA") == 1, "Mutation stamp detects remove/write ABA")
	fixture.intents.clear_owned(handle, 999)
	_check(_compare(fixture, 3, "wrong owner clear") == 0, "Rejected owner clear does not invalidate a valid cache")
	fixture.intents.clear_owned(handle, 7)
	_check(_compare(fixture, 4, "accepted owner clear") == 1, "Accepted clear removes projected intent")
	fixture.intents.write(handle, _intent())
	_compare(fixture, 5, "write before clear")
	var epoch: int = fixture.store.epoch
	fixture.intents.clear()
	_check(_compare(fixture, 6, "same epoch clear") == 1 and fixture.store.epoch == epoch,
		"Clear invalidates even without a world reset")
	fixture.intents.write(handle, _intent(1000, SimTypes.IntentMode.GRAZE, Vector2(40, 80)))
	_compare(fixture, 7, "write after clear")
	fixture.intents = CountedIntents.new()
	fixture.intents.write(handle, _intent(1000, SimTypes.IntentMode.ATTACK, Vector2(800, 40)))
	_check(_compare(fixture, 8, "new buffer matching local stamp") == 1, "Buffer instance is part of cache identity")
	var wrong_life := AgentHandle.new(handle.slot, handle.generation + 1, handle.world_epoch)
	fixture.intents.write(wrong_life, _intent())
	_check(_compare(fixture, 9, "wrong complete identity") == 1, "Changed rows retain full generation validation")
	var external := AgentHandle.new(handle.slot, handle.generation, handle.world_epoch)
	fixture.intents.write(external, _intent())
	_compare(fixture, 10, "equivalent external identity")
	var transient: MotionIntent = _intent()
	var weak_intent: WeakRef = weakref(transient)
	fixture.intents.write(handle, transient)
	transient = null
	_compare(fixture, 11, "intent reference lifetime")
	fixture.intents.remove(handle)
	_check(weak_intent.get_ref() == null, "GPU cache owns numeric projection, not a MotionIntent reference")
	_compare(fixture, 12, "remove after projection")
	fixture.close()
	_check(fixture.kernel._cached_store == null and fixture.kernel._cached_intents == null and fixture.kernel._input_handles.is_empty(),
		"Close releases bound owners and canonical life references")
	_check(fixture.kernel._input_versions.is_empty() and fixture.kernel._intent_records.is_empty(),
		"Close releases private projection columns")

func _check_lifecycle_and_growth() -> void:
	var fixture := Fixture.new()
	_populate(fixture, 3)
	var first: AgentHandle = fixture.store.handle_at(0)
	_compare(fixture, 1, "before hold")
	fixture.store.set_held(first, true)
	_check(_compare(fixture, 2, "held") == 2, "Lifecycle change rereads all active survivors and excludes held life")
	fixture.store.set_held(first, false)
	_check(_compare(fixture, 3, "released") == 3, "Release rebuilds participation without bypassing the current intent")
	fixture.store.remove_agent(first)
	_check(_compare(fixture, 4, "swap deletion") == 2, "Swap deletion cannot reuse old dense input rows")
	var replacement: AgentHandle = fixture.store.create_agent(SimTypes.Species.DOG, Vector2(200, 400), 11.0)
	_check(replacement.slot == first.slot and replacement.generation != first.generation, "Fixture reuses a slot as a new life")
	_compare(fixture, 5, "new generation stale slot intent")
	fixture.intents.write(replacement, _intent())
	_compare(fixture, 6, "new generation intent")
	fixture.store.mark_dead(replacement)
	_check(_compare(fixture, 7, "dead before removal") == 2, "Dead row is excluded before swap removal")
	fixture.store.remove_agent(replacement)
	_compare(fixture, 8, "dead removed")
	_check(fixture.kernel._input_handles.size() == fixture.store.count, "Removed dense tail releases its handle reference")
	_populate(fixture, 130)
	_check(_compare(fixture, 9, "capacity growth") == fixture.store.count, "Capacity growth rebuilds every active input projection")
	_check(_compare(fixture, 10, "stable expanded population") == 0, "Expanded columns reuse unchanged projections")
	fixture.store.reset()
	fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500))
	_compare(fixture, 11, "new epoch with old intent buffer")
	fixture.intents.write(fixture.store.handle_at(0), _intent())
	_compare(fixture, 12, "new epoch first valid intent")
	fixture.close()

func _new_mapped_store(remove_first: bool) -> AgentStore:
	var result := AgentStore.new()
	var first: AgentHandle = result.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500))
	var second: AgentHandle = result.create_agent(SimTypes.Species.WOLF, Vector2(500, 500))
	result.remove_agent(first if remove_first else second)
	result.create_agent(SimTypes.Species.DOG, Vector2(500, 500))
	return result

func _check_store_identity() -> void:
	var fixture := Fixture.new()
	fixture.store = _new_mapped_store(true)
	for dense: int in fixture.store.count:
		fixture.intents.write(fixture.store.handle_at(dense), _intent())
	_compare(fixture, 1, "first independent store")
	var previous_revision: int = fixture.store.life_revision
	fixture.store = _new_mapped_store(false)
	_check(fixture.store.life_revision == previous_revision, "Independent stores deliberately share lifecycle counters")
	fixture.intents = CountedIntents.new()
	for dense: int in fixture.store.count:
		fixture.intents.write(fixture.store.handle_at(dense), _intent(1000, SimTypes.IntentMode.MOVE, Vector2(20 + dense, 600)))
	# Rebuild a field per world: its own full-life hysteresis is not a cross-world cache.
	fixture.field = CountedField.new(fixture.config.world_size, fixture.config.crowd_cell_size)
	fixture.reference_field = CountedField.new(fixture.config.world_size, fixture.config.crowd_cell_size)
	_check(_compare(fixture, 2, "same counters different store") == 2, "Store instance invalidates derived canonical handles")
	fixture.close()

func _check_density_history(sparse: bool) -> void:
	var fixture := Fixture.new(sparse)
	_populate(fixture, 25)
	var subject: AgentHandle = fixture.store.handle_at(0)
	_compare(fixture, 1, "enter density")
	_check(fixture.kernel.field_agent_count == 25, "All valid moving intents enter dense sampling")
	for dense: int in range(17, 25):
		fixture.store.position_current[dense] = Vector2(100 + dense * 40, 800)
	fixture.intents.write(subject, _intent(1000, SimTypes.IntentMode.STOP))
	_compare(fixture, 2, "stop preserves history")
	fixture.intents.remove(subject)
	_compare(fixture, 3, "missing intent preserves history")
	fixture.store.set_held(subject, true)
	_compare(fixture, 4, "held preserves history")
	fixture.store.set_held(subject, false)
	fixture.intents.write(subject, _intent())
	_compare(fixture, 5, "resume in hysteresis band")
	_check(fixture.kernel._phase_flags[fixture.store.resolve(subject)].y == 1.0,
		"Returning active life preserves original dense hysteresis between thresholds")
	_check(_compare(fixture, 6, "stable density work still runs") == 0, "Intent cache does not require a repeated getter for density changes")
	fixture.close()

func _check_turnover_cost() -> void:
	var fixture := Fixture.new()
	_populate(fixture, 64)
	_compare(fixture, 1, "turnover initial")
	var total_reloads: int = 0
	for round_index: int in 6:
		var removed: AgentHandle = fixture.store.handle_at(0)
		fixture.store.remove_agent(removed)
		fixture.intents.remove(removed)
		var born: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500))
		fixture.intents.write(born, _intent())
		total_reloads += _compare(fixture, 2 + round_index, "turnover %d" % round_index)
	_check(total_reloads == 6 * 64, "High turnover explicitly pays O(N) complete rereads each lifecycle revision")
	_check(_compare(fixture, 8, "turnover quiet step") == 0, "Stable step resumes cache use after turnover")
	_check(fixture.kernel._input_handles.size() == 64 and fixture.kernel._input_versions.size() == fixture.store.capacity,
		"Projection storage remains bounded by current count/capacity after slot reuse")
	fixture.close()

func _check_empty_and_reopen() -> void:
	var fixture := Fixture.new()
	_populate(fixture, 2)
	_compare(fixture, 1, "warm before empty")
	while fixture.store.count > 0:
		var handle: AgentHandle = fixture.store.handle_at(0)
		fixture.store.remove_agent(handle)
		fixture.intents.remove(handle)
	_check(_compare(fixture, 2, "empty after warm") == 0, "Warm kernel accepts an empty store without looking up removed lives")
	_check(fixture.kernel._input_handles.is_empty(), "Empty projection releases all prior canonical life references")
	_populate(fixture, 2)
	_check(_compare(fixture, 3, "repopulate after empty") == 2, "Refilled slots get fresh projections after an empty interval")
	_check(_compare(fixture, 4, "stable refilled") == 0, "Refilled population can reuse its new projections")
	fixture.kernel.close()
	_check(_compare(fixture, 5, "reuse after close") == 2, "Closed kernel can rebuild all CPU input projections on reuse")
	_check(_compare(fixture, 6, "stable reopened") == 0, "Reopened projection does not carry stale invalidation state")
	fixture.close()

func _run() -> void:
	_check_stable_and_ttl()
	_check_mutations_and_buffer_identity()
	_check_lifecycle_and_growth()
	_check_store_identity()
	_check_density_history(false)
	_check_density_history(true)
	_check_turnover_cost()
	_check_empty_and_reopen()
	print("GPU_INPUT_PROJECTION_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
