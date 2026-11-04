extends SceneTree
## Fixed-input interaction fixtures. An optional frozen script is loaded only
## at this test boundary; no reference implementation is shipped in the game.
const PRODUCTION: Script = preload("res://scripts/simulation/interaction_system.gd")
var _reference: GDScript
var _reference_hash: String = ""
var _output_directory: String = ""
var _checks: int = 0
var _failures: int = 0
var _records: Array[Dictionary] = []

class Fixture extends RefCounted:
	var config := SimulationConfig.new()
	var store := AgentStore.new()
	var intents := IntentBuffer.new()
	var resources: ResourceGrid
	# Dynamic access is confined to the frozen-reference test adapter.
	var system: RefCounted

	func _init(implementation: Script) -> void:
		config.hunger_rate = 0.0
		config.sheep_metabolism = 0.0
		config.grass_recovery_rate = 0.0
		config.attack_windup_ticks = 0
		config.attack_window_ticks = 2
		config.attack_cooldown_ticks = 5
		resources = ResourceGrid.new(config)
		system = implementation.new() as RefCounted
		system.call(&"setup", store, resources, intents, config)

	func graze(actor: AgentHandle, cell: int, expiry: int = 100) -> void:
		var intent := MotionIntent.new()
		intent.mode = SimTypes.IntentMode.GRAZE
		intent.resource_cell = cell
		intent.expires_tick = expiry
		intents.write(actor, intent)

	func attack(actor: AgentHandle, target: AgentHandle, token: int) -> void:
		var intent := MotionIntent.new()
		intent.mode = SimTypes.IntentMode.ATTACK
		intent.behavior = SimTypes.Behavior.ATTACK
		intent.target = target
		intent.owner_token = token
		intent.expires_tick = 100
		intents.write(actor, intent)

	func remove(actor: AgentHandle) -> void:
		system.call(&"remove", actor)
		intents.remove(actor)
		store.remove_agent(actor)

	func populate(count: int) -> void:
		for index: int in range(count):
			var species: int = SimTypes.Species.SHEEP
			if index % 13 == 0:
				species = SimTypes.Species.WOLF
			elif index % 13 == 1:
				species = SimTypes.Species.DOG
			var cell: int = index % resources.cell_count
			var position: Vector2 = resources.cell_center(cell)
			if index % 17 == 0:
				position = Vector2(-1.0, -1.0)
			var actor: AgentHandle = store.create_agent(species, position)
			store.hunger[store.resolve(actor)] = float(index % 11) / 10.0
			graze(actor, cell if index % 19 != 0 else -1, 3 if index % 7 == 0 else 100)
			if index % 11 == 0:
				store.set_held(actor, true)
			if index % 23 == 0:
				store.mark_dead(actor)

	func snapshot() -> Dictionary:
		var requests: Dictionary = system.get(&"_requests")
		var slots: Array = requests.keys()
		slots.sort()
		var attacks: Array[Dictionary] = []
		for slot: int in slots:
			var request: AttackRequest = requests[slot]
			attacks.append({"actor": identity(request.actor), "target": identity(request.target),
				"token": request.owner_token, "accepted": request.accepted_tick,
				"start": request.active_start_tick, "end": request.active_end_tick,
				"cooldown": request.cooldown_until_tick, "status": request.status,
				"fraction": request.contact_fraction})
		var captured: Array[Dictionary] = []
		var events: Array = system.get(&"captures")
		for event: CaptureEvent in events:
			captured.append({"actor": identity(event.actor), "target": identity(event.target),
				"tick": event.tick, "position": vector_values(event.position),
				"previous": vector_values(event.previous_position), "facing": vector_values(event.facing)})
		var removed: Array[String] = []
		var deaths: Array = system.get(&"deaths")
		for actor: AgentHandle in deaths:
			removed.append(identity(actor))
		return {"count": store.count, "capacity": store.capacity, "epoch": store.epoch,
			"alive": Array(store.alive), "held": Array(store.held), "hunger": Array(store.hunger),
			"slot_to_dense": Array(store.slot_to_dense), "dense_to_slot": Array(store.dense_to_slot),
			"generations": Array(store.generations), "attacks": attacks, "captures": captured, "deaths": removed,
			"grass_consumed": system.get(&"grass_consumed"), "amount": Array(resources._amount),
			"materialized_tick": Array(resources._materialized_tick), "previous_amount": Array(resources._previous_amount),
			"previous_tick": Array(resources._previous_tick), "resource_capacity": Array(resources._capacity)}

	static func identity(actor: AgentHandle) -> String:
		return actor.key() if actor != null else "null"

	static func vector_values(value: Vector2) -> Array[float]:
		return [value.x, value.y]

func _initialize() -> void:
	call_deferred(&"_run")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)

func _load_arguments() -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			_output_directory = argument.trim_prefix("--output=")
		if argument.begins_with("--reference="):
			var path: String = argument.trim_prefix("--reference=")
			if not FileAccess.file_exists(path):
				push_error("Frozen reference does not exist: " + path)
				return false
			var source: String = FileAccess.get_file_as_string(path)
			if not source.begins_with("class_name InteractionSystem"):
				push_error("Expected the frozen InteractionSystem source")
				return false
			_reference_hash = source.sha256_text()
			_reference = GDScript.new()
			_reference.source_code = source.replace("class_name InteractionSystem", "")
			if _reference.reload() != OK:
				return false
	return true

func _run() -> void:
	if not _load_arguments():
		quit(1)
		return
	for count: int in [0, 1, 17, 129, 257, 4097]:
		_test_participants(count)
	if _reference == null:
		print("Frozen-reference comparison skipped; running standalone contracts")
	_test_proportion()
	_test_capture_before_grazing()
	_test_wolf_hold_cooldown_and_reuse()
	_test_geometry_reset()
	_test_profile_sampling()
	_write_results()
	print("INTERACTION_OPTIMIZATION_TESTS checks=%d failures=%d reference_compared=%s" % [_checks, _failures, _reference != null])
	quit(0 if _failures == 0 else 1)

func _pair() -> Array[Fixture]:
	var fixtures: Array[Fixture] = [Fixture.new(PRODUCTION)]
	if _reference != null:
		fixtures.append(Fixture.new(_reference))
	return fixtures

func _step_and_compare(fixtures: Array[Fixture], tick: int, label: String, dt: float = 1.0 / 60.0) -> void:
	for fixture: Fixture in fixtures:
		fixture.system.call(&"step", tick, dt)
	var actual: Dictionary = fixtures[0].snapshot()
	var valid_hunger: bool = true
	for value: float in actual.hunger:
		valid_hunger = valid_hunger and is_finite(value) and value >= 0.0 and value <= 1.0
	_check(valid_hunger, label + ": hunger remains finite and bounded")
	var row: Dictionary = {"case": label, "tick": tick, "actual": actual}
	if fixtures.size() == 2:
		var expected: Dictionary = fixtures[1].snapshot()
		_check(actual == expected, label + ": complete outcome equals frozen reference")
		row["reference"] = expected
	_records.append(row)

func _test_participants(count: int) -> void:
	var fixtures: Array[Fixture] = _pair()
	for fixture: Fixture in fixtures:
		fixture.config.sheep_stomach_capacity = 0.25
		fixture.config.sheep_metabolism = 0.017
		fixture.config.hunger_rate = 0.023
		fixture.config.grazing_rate = 0.137
		fixture.populate(count)
	for tick: int in range(8):
		for fixture: Fixture in fixtures:
			if tick == 2:
				fixture.intents.clear()
			elif tick == 3:
				for dense: int in range(fixture.store.count):
					fixture.graze(fixture.store.handle_at(dense), fixture.resources.cell_at(fixture.store.position_next[dense]), 4)
			elif tick == 4 and fixture.store.count > 0:
				var retired: AgentHandle = fixture.store.handle_at(0)
				fixture.remove(retired)
				fixture.store.create_agent(SimTypes.Species.SHEEP, fixture.resources.cell_center(0))
				fixture.graze(retired, 0)
			elif tick >= 5:
				for dense: int in range(fixture.store.count):
					var actor: AgentHandle = fixture.store.handle_at(dense)
					fixture.store.set_held(actor, tick == 5)
					fixture.graze(actor, fixture.resources.cell_at(fixture.store.position_next[dense]))
		_step_and_compare(fixtures, tick, "participants-%d-%d" % [count, tick])
		if tick in [2, 4, 5]:
			_check(is_zero_approx(float(fixtures[0].system.get(&"grass_consumed"))), "Cleared/expired/held participants cannot read last step's demand")

func _test_proportion() -> void:
	var fixtures: Array[Fixture] = _pair()
	for fixture: Fixture in fixtures:
		fixture.config.grazing_rate = 1.0
		fixture.resources._amount[0] = 0.1
		var hungry: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, fixture.resources.cell_center(0))
		var content: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, fixture.resources.cell_center(0))
		fixture.store.hunger[0] = 0.8
		fixture.store.hunger[1] = 0.2
		fixture.graze(hungry, 0)
		fixture.graze(content, 0)
	_step_and_compare(fixtures, 0, "scarce-proportion", 1.0)
	_check(absf(fixtures[0].store.hunger[0] - 0.72) < 0.00001, "Greater hunger receives proportional food")
	_check(absf(fixtures[0].store.hunger[1] - 0.18) < 0.00001, "Smaller demand receives the same fulfillment fraction")
	_check(fixtures[0].resources._materialized_tick[0] == 1 and fixtures[0].resources._previous_tick[0] == 0, "One grass commit retains the previous display tick")

func _test_capture_before_grazing() -> void:
	var fixtures: Array[Fixture] = _pair()
	for fixture: Fixture in fixtures:
		var first: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
		var second: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
		var prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(110, 100))
		fixture.graze(prey, fixture.resources.cell_at(Vector2(110, 100)))
		fixture.attack(second, prey, 1)
		fixture.attack(first, prey, 1)
	_step_and_compare(fixtures, 0, "capture-before-food")
	var events: Array = fixtures[0].system.get(&"captures")
	_check(events.size() == 1 and events[0].actor.slot == 0, "Equal contacts keep stable actor ordering")
	_check(is_zero_approx(float(fixtures[0].system.get(&"grass_consumed"))), "A sheep captured this step cannot consume grass")
	_step_and_compare(fixtures, 1, "capture-does-not-repeat")
	_check((fixtures[0].system.get(&"captures") as Array).is_empty(), "Accepted token cannot replay a capture")

func _test_wolf_hold_cooldown_and_reuse() -> void:
	var fixtures: Array[Fixture] = _pair()
	for fixture: Fixture in fixtures:
		var wolf: AgentHandle = fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
		var prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(110, 100))
		fixture.attack(wolf, prey, 1)
	_step_and_compare(fixtures, 0, "wolf-first-capture")
	for fixture: Fixture in fixtures:
		var wolf: AgentHandle = fixture.store.handle_at(0)
		fixture.remove(fixture.store.handle_at(1))
		var next_prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(110, 100))
		fixture.system.call(&"suspend", wolf)
		fixture.store.set_held(wolf, true)
		fixture.attack(wolf, next_prey, 2)
	_step_and_compare(fixtures, 5, "held-wolf-past-cooldown")
	_check((fixtures[0].system.get(&"captures") as Array).is_empty(), "Held wolf cannot accept an attack after cooldown")
	for fixture: Fixture in fixtures:
		fixture.store.set_held(fixture.store.handle_at(0), false)
		fixture.attack(fixture.store.handle_at(0), fixture.store.handle_at(1), 1)
	_step_and_compare(fixtures, 6, "old-wolf-token")
	_check((fixtures[0].system.get(&"captures") as Array).is_empty(), "Old token stays rejected after cooldown")
	for fixture: Fixture in fixtures:
		fixture.attack(fixture.store.handle_at(0), fixture.store.handle_at(1), 2)
	_step_and_compare(fixtures, 7, "new-wolf-token")
	_check((fixtures[0].system.get(&"captures") as Array).size() == 1, "Dropped wolf can use a newer attack token")
	for fixture: Fixture in fixtures:
		var retired: AgentHandle = fixture.store.handle_at(0)
		fixture.remove(retired)
		fixture.store.create_agent(SimTypes.Species.WOLF, Vector2(100, 100))
		var new_prey: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, Vector2(110, 100))
		fixture.attack(retired, new_prey, 3)
	_step_and_compare(fixtures, 8, "stale-actor-after-swap-remove")
	_check((fixtures[0].system.get(&"captures") as Array).is_empty(), "Retired actor cannot authorize its replacement")

func _test_geometry_reset() -> void:
	var fixtures: Array[Fixture] = _pair()
	for fixture: Fixture in fixtures:
		fixture.populate(129)
	_step_and_compare(fixtures, 0, "before-reset")
	for fixture: Fixture in fixtures:
		fixture.system.call(&"reset")
		fixture.store.reset()
		fixture.intents.clear()
		fixture.config.world_size = Vector2(83, 49)
		fixture.config.resource_cell_size = 37.5
		fixture.resources.configure(fixture.config)
		fixture.system.call(&"setup", fixture.store, fixture.resources, fixture.intents, fixture.config)
		for position: Vector2 in [Vector2(0, 0), Vector2(37.5, 1), Vector2(37.49999, 1), Vector2(83, 1), Vector2(82.99, 48.99), Vector2(-0.001, 1)]:
			var sheep: AgentHandle = fixture.store.create_agent(SimTypes.Species.SHEEP, position)
			fixture.graze(sheep, fixture.resources.cell_at(position))
	_step_and_compare(fixtures, 0, "cropped-fractional-grid-after-reset")
	_check(fixtures[0].store.epoch == 2, "Reset changes epoch before rebuilding participants")

func _test_profile_sampling() -> void:
	var fixtures: Array[Fixture] = [Fixture.new(PRODUCTION), Fixture.new(PRODUCTION)]
	for fixture: Fixture in fixtures:
		fixture.populate(17)
	var measured: InteractionSystem = fixtures[0].system as InteractionSystem
	measured.profile_enabled = true
	measured.profile_interval_ticks = 2
	for tick: int in range(4):
		for fixture: Fixture in fixtures:
			fixture.system.call(&"step", tick, fixture.config.fixed_dt)
		_check(fixtures[0].snapshot() == fixtures[1].snapshot(), "Whole-step timing preserves fixed-input outcome")
		_check(measured.last_profile_tick == tick - tick % 2, "Profile timestamp identifies the retained sample")
		var phase_sum: int = 0
		for duration: int in measured.profile_usec:
			phase_sum += duration
		_check(phase_sum <= measured.profile_total_usec, "Phase durations stay inside the parent interaction timer")
	measured.reset()
	_check(measured.last_profile_tick == -1, "Reset invalidates the retained profile sample")

func _write_results() -> void:
	if _output_directory.is_empty():
		return
	var error: Error = DirAccess.make_dir_recursive_absolute(_output_directory)
	if error != OK:
		_check(false, "Cannot create output directory")
		return
	var path: String = _output_directory.path_join("interaction-optimization-results.json")
	if FileAccess.file_exists(path):
		_check(false, "Refuse to replace existing fixed-input results")
		return
	var output: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		_check(false, "Cannot open fixed-input results")
		return
	output.store_string(JSON.stringify({"checks": _checks, "failures": _failures,
		"reference_compared": _reference != null, "reference_sha256": _reference_hash,
		"engine": Engine.get_version_info(), "fixtures": _records}, "", true, true))
	output.flush()
	if output.get_error() != OK:
		_check(false, "Fixed-input results could not be written completely")
