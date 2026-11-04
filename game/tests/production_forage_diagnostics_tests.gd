extends SceneTree
## Diagnostic boundary checks use explicit owner-thread fixture states. They do
## not replace the separately measured normal-worker production scenario.
var _checks: int = 0
var _failures: int = 0

class Fixture extends RefCounted:
	var world := SimulationWorld.new()
	var record := ProductionForageTrace.new()
	var context: AgentContext
	var target_cell: int

	func _init() -> void:
		var config := SimulationConfig.new()
		config.world_size = Vector2(2400, 1400)
		config.detached_ai = true
		config.ai_budget_usec = 6000
		config.grass_recovery_rate = 0.0
		var scenario := ScenarioConfig.new()
		scenario.sheep_count = 0
		scenario.wolf_count = 0
		scenario.dog_count = 0
		world.setup(config, scenario)
		record.handle = world.create_at(SimTypes.Species.SHEEP, Vector2(100, 100))
		context = world.ai.inspect(record.handle)
		context.task_name = &"graze_grass"
		context.task_token = 1
		target_cell = world.resources.cell_at(Vector2(200, 100))
		record.diagnostics.detailed = true

	func publish(mode: int, cell: int, tick: int) -> MotionIntent:
		var intent := MotionIntent.new()
		intent.mode = mode
		intent.behavior = SimTypes.Behavior.GRAZE
		intent.resource_cell = cell
		intent.destination = world.resources.cell_center(cell) if cell >= 0 else Vector2(400, 100)
		intent.owner_token = context.task_token
		intent.expires_tick = tick + 90
		world.intents.write(record.handle, intent)
		return intent

	func begin(tick: int) -> void:
		world.tick = tick
		context.current_tick = tick
		var dense: int = world.store.resolve(record.handle)
		record.previous_position = world.store.position_current[dense]
		record.previous_hunger = world.store.hunger[dense]
		record.diagnostics.begin_step(world, record)

	func finish(tick: int) -> void:
		world.tick = tick + 1
		record.diagnostics.end_step(world, record, context, world.intents.get_intent(record.handle, tick), tick)

	func close() -> void:
		world.motion.close()
		world.ai.reset()
		world.free()

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)

func _run() -> void:
	_test_resource_snapshots_and_arrival()
	_test_ownership_expiry_and_transition_facts()
	_test_bounded_rows_and_undetailed_life()
	_test_real_protocol_integration()
	print("PRODUCTION_FORAGE_DIAGNOSTICS_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_resource_snapshots_and_arrival() -> void:
	var fixture := Fixture.new()
	fixture.publish(SimTypes.IntentMode.MOVE, fixture.target_cell, 241)
	fixture.begin(241)
	var coverage_before: float = fixture.world.resources.get_effective_amount(fixture.target_cell, 241)
	var consumed: float = fixture.world.resources.consume(fixture.target_cell, 0.1, 241)
	fixture.world.store.relocate(fixture.record.handle, Vector2(110, 100))
	var coverage_after: float = fixture.world.resources.get_effective_amount(fixture.target_cell, 242)
	fixture.finish(241)
	var sample: Dictionary = fixture.record.diagnostics.samples[0]
	_check(sample["input_tick"] == 241 and sample["completed_tick"] == 242, "Diagnostic rows label separate input and completed clocks")
	_check(is_equal_approx(sample["resource_coverage_at_input"], coverage_before) and is_equal_approx(sample["resource_coverage_at_end"], coverage_after), "Resource n/n+1 values retain the real consume boundary")
	_check(absf(float(sample["resource_food_decrease"]) - consumed) < 0.000001 and sample["derived_food_this_step"] == 0.0, "Cell consumption cannot be attributed to this sheep without its stomach evidence")
	_check(not sample["resource_member_before"] and not sample["resource_member_after"] and float(sample["distance_after"]) < float(sample["distance_before"]), "Closing toward a target cell is distinct from entering it")
	_check(fixture.world.resources.get_effective_amount(fixture.target_cell, 242) == coverage_after, "Read-only diagnostics never consume or materialize additional food")
	fixture.begin(242)
	fixture.world.store.relocate(fixture.record.handle, Vector2(170, 100))
	fixture.finish(242)
	_check(fixture.record.diagnostics.resource_member_steps == 1 and fixture.record.diagnostics.member_while_moving_steps == 1, "Physical entry while a MOVE intent remains is recorded separately from GRAZE permission")
	_check(fixture.record.diagnostics.first_resource_entry_tick == 243 and fixture.record.diagnostics.grazing_member_steps == 0, "First entry uses the completed clock and does not manufacture intake")
	fixture.publish(SimTypes.IntentMode.GRAZE, fixture.target_cell, 243)
	fixture.begin(243)
	fixture.finish(243)
	_check(fixture.record.diagnostics.grazing_member_steps == 1 and fixture.record.diagnostics.grazing_member_without_intake_steps == 1, "Owned GRAZE and cell membership without intake remain explicit")
	fixture.close()

func _test_ownership_expiry_and_transition_facts() -> void:
	var fixture := Fixture.new()
	fixture.publish(SimTypes.IntentMode.MOVE, fixture.target_cell, 241)
	fixture.begin(241)
	fixture.context.task_token = 2
	fixture.finish(241)
	_check(fixture.record.diagnostics.missing_or_unowned_steps == 1 and fixture.record.diagnostics.owned_grass_steps == 0, "Old owner tokens never count as current grass approach")
	var expiring: MotionIntent = fixture.publish(SimTypes.IntentMode.MOVE, fixture.target_cell, 242)
	# This is an unpublished replacement fixture record, never mutation after write.
	var expired := MotionIntent.new()
	expired.mode = expiring.mode
	expired.behavior = expiring.behavior
	expired.resource_cell = expiring.resource_cell
	expired.destination = expiring.destination
	expired.owner_token = fixture.context.task_token
	expired.expires_tick = 242
	fixture.world.intents.write(fixture.record.handle, expired)
	fixture.begin(242)
	fixture.finish(242)
	_check(fixture.record.diagnostics.missing_or_unowned_steps == 2, "The exclusive TTL endpoint is missing input, not a grazing stall")
	fixture.world.resources.consume(fixture.target_cell, fixture.world.resources.food_capacity(fixture.target_cell), 242)
	fixture.publish(SimTypes.IntentMode.MOVE, fixture.target_cell, 243)
	fixture.begin(243)
	fixture.context.task_name = &"search_area"
	fixture.context.task_token = 3
	fixture.context.grazing_retry_after_tick = 333
	fixture.publish(SimTypes.IntentMode.MOVE, -1, 243)
	fixture.finish(243)
	var event: Dictionary = fixture.record.diagnostics.event_rows().back()
	_check("GRAZE_BACKOFF_ENTERED" in str(event["transition_facts"]) and "PREVIOUS_RESOURCE_BELOW_MIN" in str(event["transition_facts"]), "Concurrent retry/depletion facts remain separate evidence rather than one invented exit cause")
	_check(fixture.record.diagnostics.backoff_entries == 1 and fixture.record.diagnostics.left_depleted_resource_count == 1, "Public retry and depleted-resource transitions have exact per-life counters")
	fixture.close()

func _test_bounded_rows_and_undetailed_life() -> void:
	var fixture := Fixture.new()
	for tick: int in range(300, 325):
		fixture.publish(SimTypes.IntentMode.MOVE, fixture.target_cell, tick)
		fixture.begin(tick)
		fixture.context.task_name = &"search_area" if fixture.context.task_name == &"graze_grass" else &"graze_grass"
		fixture.finish(tick)
	var summary: Dictionary = fixture.record.diagnostics.summary(fixture.record.handle)
	var events: Array[Dictionary] = fixture.record.diagnostics.event_rows()
	_check(summary["event_count"] == 25 and summary["events_retained"] == 16 and summary["events_omitted"] == 9, "Finite ring retention preserves exact event and omission counts")
	_check(events[0]["input_tick"] == 309 and events[-1]["input_tick"] == 324, "Exported ring rows retain the latest events in clock order")
	fixture.close()
	var undetailed := Fixture.new()
	undetailed.record.diagnostics.detailed = false
	undetailed.publish(SimTypes.IntentMode.MOVE, undetailed.target_cell, 1199)
	undetailed.begin(1199)
	undetailed.finish(1199)
	_check(undetailed.record.diagnostics.samples.is_empty() and undetailed.record.diagnostics.events.is_empty(), "Lives beyond the detail cap do not allocate periodic or transition rows")
	_check(undetailed.record.diagnostics.observed_steps == 1 and not undetailed.record.diagnostics.terminal.is_empty(), "Undetailed lives still retain aggregate and terminal resource evidence")
	undetailed.close()

func _test_real_protocol_integration() -> void:
	var fixture := Fixture.new()
	fixture.world.reset(fixture.world.scenario)
	var probe := ProductionForageProbe.new()
	probe.setup(fixture.world, 8, 42)
	for tick: int in ProductionForageProbe.END_TICK:
		probe.before_step(fixture.world)
		fixture.world.ai.begin_frame()
		fixture.world.step()
		probe.after_step(fixture.world)
	var report: Dictionary = probe.finish_report()
	_check(report["protocol"] == "production-forage-migration-v1" and report["forage_diagnostics_version"] == "forage-resource-evidence-v1", "Additional evidence does not silently replace the original success protocol")
	_check(report["records"].size() == 8 and report["forage_diagnostics"].size() == 8 and report["forage_terminal_context"].size() == 8, "All real registered lives remain in the old and new denominators")
	_check(report["forage_samples"].size() == 264 and report["forage_events"].size() <= 128, "Eight lives produce exactly 33 periodic rows each and bounded event rows")
	for row: Dictionary in report["forage_diagnostics"]:
		_check(row["observed_steps"] == 959, "Every post-drought step is aggregated even when detail is periodic")
	fixture.close()
