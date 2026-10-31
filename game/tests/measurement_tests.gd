extends SceneTree
## Measurement contracts: catch-up totals, zero-step frames and full denominators.
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
	var config := SimulationConfig.new()
	config.instrument_enabled = true
	config.ai_budget_usec = 100000
	var scenario := ScenarioConfig.new()
	scenario.sheep_count = 3
	scenario.wolf_count = 0
	scenario.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, scenario)
	var view := WorldPresentation.new(world.probes)
	root.add_child(view)
	view.setup(world.store, world.intents, world.resources, config)
	var runner := SimulationRunner.new()
	root.add_child(runner)
	runner.set_process(false)
	runner.setup(world, view)
	runner.accumulator_seconds = config.fixed_dt * 3.25
	runner._last_usec = Time.get_ticks_usec()
	runner._process(0.0)
	_check(runner.last_step_count == 3, "Fixture publishes three catch-up steps in one frame")
	_check(world.probes.counts[Probes.Tag.VISUAL_PUBLISH] == 3, "Visual publication is timed once for each published step")
	_check(runner.frame_observe_usec >= world.probes.sums[Probes.Tag.VISUAL_PUBLISH], "Frame publication timer contains all three inner timers")
	_check(runner.frame_field_build_usec + runner.frame_field_sample_usec + runner.frame_exact_sample_usec <= runner.frame_phase_usec[4], "Motion components fit inside the accumulated motion phase")
	_check(world.probes.counts[Probes.Tag.BODY_PREPARE] == 1 and world.probes.counts[Probes.Tag.SHADOWS] == 1, "Body preparation and shadows run once per render frame")
	runner.accumulator_seconds = 0.0
	runner._last_usec = Time.get_ticks_usec()
	runner._process(0.0)
	_check(runner.last_step_count == 0, "Fixture includes an interpolation-only frame")
	_check(runner.frame_observe_usec == 0 and runner.frame_field_build_usec == 0 and runner.frame_moved_agent_steps == 0, "Zero-step frame cannot repeat the previous frame's totals")
	_check(world.probes.counts[Probes.Tag.VISUAL_PUBLISH] == 3, "Repeated present does not count an extra publication")
	var held: AgentHandle = world.store.handle_at(0)
	world.queue_hold(held)
	world._apply_commands()
	var unserved: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(500, 500))
	_check(world.ai.inspect(unserved).last_perception_tick == -1, "Fixture includes an unserved live sheep")
	var benchmark := BenchmarkSession.new()
	var quality: Array[Dictionary] = benchmark._quality_snapshot(world)
	_check(quality[SimTypes.Species.SHEEP]["active"] == 3, "Quality denominator excludes held lives and includes unserved lives")
	_check(quality[SimTypes.Species.SHEEP]["never_perceived"] >= 1, "Unserved lives remain explicit in the quality result")
	_check(quality[SimTypes.Species.SHEEP]["missing_or_expired_intent"] >= 1, "Missing intents are counted instead of omitted")
	benchmark.free()
	runner.queue_free()
	view.queue_free()
	world.queue_free()
	await process_frame
	print("MEASUREMENT_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
