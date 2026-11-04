extends SceneTree
## CPU-side input projections must bind caches to a store, not just counters.
## No RenderingDevice is needed to compare the used identity direction column.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _make_store(remove_first: bool) -> AgentStore:
	var store := AgentStore.new()
	var first: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500), 13.0)
	var second: AgentHandle = store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500), 13.0)
	store.remove_agent(first if remove_first else second)
	store.create_agent(SimTypes.Species.SHEEP, Vector2(500, 500), 13.0)
	return store

func _pack(kernel: GpuMotionKernel, store: AgentStore) -> PackedByteArray:
	var config := SimulationConfig.new()
	var field := CrowdMotionField.new(config.world_size, config.crowd_cell_size)
	field.rebuild(store)
	var intents := IntentBuffer.new()
	for dense: int in store.count:
		var intent := MotionIntent.new()
		intent.mode = SimTypes.IntentMode.MOVE
		intent.destination = Vector2(800, 500)
		intent.speed = 70.0
		intent.expires_tick = 100
		intents.write(store.handle_at(dense), intent)
	kernel._pack_bulk(store, intents, field, config, 0)
	# Capacity tails are deliberately unused by the shader and may hold old rows.
	return kernel._identity_directions.slice(0, store.count).to_byte_array()

func _run() -> void:
	var first: AgentStore = _make_store(true)
	var second: AgentStore = _make_store(false)
	_check(first.epoch == second.epoch and first.life_revision == second.life_revision,
		"Independent stores can share lifecycle counters")
	_check(not first.handle_at(0).same_life(second.handle_at(0)),
		"Equal counters do not imply equal dense life mappings")
	var reused := GpuMotionKernel.new()
	var fresh := GpuMotionKernel.new()
	_pack(reused, first)
	var expected: PackedByteArray = _pack(fresh, second)
	_check(_pack(reused, second) == expected,
		"Switching stores with matching counters must not reuse another dense mapping")
	var rebuilds: int = reused.identity_cache_rebuilds
	_check(_pack(reused, second) == expected and reused.identity_cache_rebuilds == rebuilds,
		"Repeated input from the same store still reuses its identity projection")
	second.reset()
	second.create_agent(SimTypes.Species.DOG, Vector2(500, 500), 13.0)
	_check(_pack(reused, second) == _pack(GpuMotionKernel.new(), second),
		"Reset and a different population cannot inherit prior input identities")
	print("GPU_INPUT_IDENTITY_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
