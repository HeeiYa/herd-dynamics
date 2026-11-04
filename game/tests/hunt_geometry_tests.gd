extends SceneTree
## Geometry/diagnostic contracts; CPU setup is not a production behavior result.
var _checks: int = 0
var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _run() -> void:
	_check_arguments()
	_check_offsets_and_bounds()
	_check_direction_covariance()
	_check_registration()
	_check_failed_fixture()
	print("HUNT_GEOMETRY_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_arguments() -> void:
	var empty := PackedStringArray()
	_check(ProductionHuntGeometry.from_arguments(empty) == ProductionHuntGeometry.Variant.BASELINE, "Missing geometry preserves the original baseline")
	_check(ProductionHuntGeometry.argument_error(empty, "two-flocks", 1000).is_empty(), "Unrelated existing protocols need no new option")
	for label: String in ["baseline", "north", "oblique"]:
		var arguments := PackedStringArray(["--hunt-geometry=" + label])
		_check(ProductionHuntGeometry.argument_error(arguments, "hunt-cooperation", 80).is_empty(), "Each declared geometry is accepted for the fixed comparison")
		_check(ProductionHuntGeometry.variant_name(ProductionHuntGeometry.from_arguments(arguments)) == label, "Explicit values survive parsing without fallback")
	_check(not ProductionHuntGeometry.argument_error(PackedStringArray(["--hunt-geometry=unknown"]), "hunt-cooperation", 80).is_empty(), "Unknown values cannot silently become baseline")
	_check(not ProductionHuntGeometry.argument_error(PackedStringArray(["--hunt-geometry=north"]), "two-flocks", 80).is_empty(), "Geometry cannot be silently ignored by another protocol")
	_check(not ProductionHuntGeometry.argument_error(PackedStringArray(["--hunt-geometry=north"]), "hunt-cooperation", 1000).is_empty(), "New layouts keep the declared 80-sheep comparison")
	_check(not ProductionHuntGeometry.argument_error(PackedStringArray(["--hunt-geometry=north", "--hunt-geometry=baseline"]), "hunt-cooperation", 80).is_empty(), "Duplicate conflicting choices cannot use last-value wins")
	_check(not ProductionHuntGeometry.argument_error(PackedStringArray(["--hunt-geometery=north"]), "hunt-cooperation", 80).is_empty(), "Misspelled hunt options fail explicitly")
	_check(ProductionHuntGeometry.argument_error(PackedStringArray(["--hunt-geometry=baseline"]), "hunt-cooperation", 1000).is_empty(), "Existing baseline count range remains supported")

func _check_offsets_and_bounds() -> void:
	var expected: Array[Vector2] = [Vector2(-110, 0), Vector2(-100, -50), Vector2(-100, 50)]
	_check(ProductionHuntGeometry.offsets(ProductionHuntGeometry.Variant.BASELINE) == expected, "Baseline offsets preserve all original float values and order")
	_check(ProductionHuntGeometry.offsets(ProductionHuntGeometry.Variant.NORTH) == [Vector2(0, -110), Vector2(50, -100), Vector2(-50, -100)], "North rotates only the three stimulus offsets by an exact quarter turn")
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	var settings := AISettings.new()
	var reference := Vector2(600, 700)
	for variant: ProductionHuntGeometry.Variant in [ProductionHuntGeometry.Variant.BASELINE, ProductionHuntGeometry.Variant.NORTH, ProductionHuntGeometry.Variant.OBLIQUE]:
		var positions: Array[Vector2] = []
		for offset: Vector2 in ProductionHuntGeometry.offsets(variant):
			positions.append(reference + offset)
		_check(ProductionHuntGeometry.placement_error(reference, positions, config.agent_radius, config.world_size, config.perception_radius, settings.cooperation_radius).is_empty(), "Each finite geometry has full bodies inside the world and real observation/cooperation opportunity")
		positions[0] = Vector2(config.agent_radius - 1.0, 700)
		_check(not ProductionHuntGeometry.placement_error(reference, positions, config.agent_radius, config.world_size, config.perception_radius, settings.cooperation_radius).is_empty(), "A body crossing a boundary fails instead of relying on stage0 clamp")
	_check(ProductionHuntGeometry.body_inside_world(Vector2(13, 13), 13, config.world_size), "A body tangent to the boundary is inside")
	_check(not ProductionHuntGeometry.body_inside_world(Vector2(NAN, 700), 13, config.world_size), "Nonfinite positions are not accepted as geometry")
	var overlap: Array[Vector2] = [reference + Vector2(-110, 0), reference + Vector2(-110, 1), reference + Vector2(-100, 50)]
	_check(not ProductionHuntGeometry.placement_error(reference, overlap, 13, config.world_size, config.perception_radius, settings.cooperation_radius).is_empty(), "Overlapping stimuli cannot manufacture a capture opportunity")
	var far: Array[Vector2] = [reference + Vector2(-1000, 0), reference + Vector2(-100, -50), reference + Vector2(-100, 50)]
	_check(not ProductionHuntGeometry.placement_error(reference, far, 13, config.world_size, config.perception_radius, settings.cooperation_radius).is_empty(), "An out-of-range hunter fails fixture validation")

func _check_direction_covariance() -> void:
	var probe := ProductionHuntProbe.new()
	var actor := Vector2(500, 600)
	var target := Vector2(640, 680)
	var translation := Vector2(1000, 700)
	for velocity: Vector2 in [Vector2(45, 17), Vector2.ZERO]:
		for role: int in [CoordinationSystem.Role.MAIN, CoordinationSystem.Role.LEFT, CoordinationSystem.Role.RIGHT]:
			probe._target_position_at_step_start = target
			probe._target_velocity_at_step_start = velocity
			var direction: Vector2 = probe._role_direction_at_step_start(actor, role)
			for angle: float in [PI * 0.5, PI * 0.25]:
				probe._target_position_at_step_start = target.rotated(angle) + translation
				probe._target_velocity_at_step_start = velocity.rotated(angle)
				var rotated: Vector2 = probe._role_direction_at_step_start(actor.rotated(angle) + translation, role)
				_check(rotated.is_equal_approx(direction.rotated(angle)), "Independent role axes rotate with real geometry, including stationary-prey fallback")
				_check(is_equal_approx((direction * 3.0).rotated(angle).dot(rotated), 3.0), "Role-direction progress is invariant under the fixture rotation")
				_check((-direction).rotated(angle).dot(rotated) < 0.0, "Opposite actual motion cannot count as positive role progress")

func _new_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	var config := SimulationConfig.new()
	config.world_size = Vector2(2400, 1400)
	config.detached_ai = true
	config.ai_budget_usec = 6000
	var initial := ScenarioConfig.new()
	initial.sheep_count = 0
	initial.wolf_count = 0
	initial.dog_count = 0
	world.setup(config, initial)
	return world

func _close(world: SimulationWorld) -> void:
	world.motion.close()
	world.ai.reset()
	world.free()

func _check_registration() -> void:
	var reference_positions: PackedVector2Array = PackedVector2Array()
	for variant: ProductionHuntGeometry.Variant in [ProductionHuntGeometry.Variant.BASELINE, ProductionHuntGeometry.Variant.NORTH, ProductionHuntGeometry.Variant.OBLIQUE]:
		var world: SimulationWorld = _new_world()
		var probe := ProductionHuntProbe.new()
		probe.geometry_variant = variant
		probe.setup(world, 80, 42)
		_check(world.store.count == 0, "All initial sheep enter through normal stage0 registration")
		world._apply_commands()
		probe.observe_step_start(world)
		var positions := PackedVector2Array()
		for dense: int in world.store.count:
			positions.append(world.store.position_current[dense])
		if variant == ProductionHuntGeometry.Variant.BASELINE:
			reference_positions = positions
		_check(positions == reference_positions and positions.size() == 80 and positions[0] == Vector2(600, 700), "All variants preserve every sheep position and RNG call order")
		# Jump only in this registration fixture; it does not claim warmup/AI quality.
		world.tick = ProductionHuntProbe.HUNTER_TICK
		probe.before_step(world)
		_check(world.counts()[SimTypes.Species.WOLF] == 0, "Stimulus placement is queued rather than bypassing stage0")
		world._apply_commands()
		probe.observe_step_start(world)
		var geometry: Dictionary = probe._geometry_report()
		_check(geometry["fixture_valid"] and geometry["registered_hunters"].size() == 3, "All three actual registered coordinates match the validated stimulus")
		_check(world.counts()[SimTypes.Species.WOLF] == 3 and probe._records.size() == 3, "Three ordinary hunter lives retain independent records")
		for record: ProductionHuntTrace in probe._records:
			_check(record.eligible_tick == 240 and record.cooperation_eligible_tick == 240, "Actual post-stage0 geometry supplies perception/cooperation denominators")
		_close(world)

func _check_failed_fixture() -> void:
	var world: SimulationWorld = _new_world()
	var probe := ProductionHuntProbe.new()
	probe.geometry_variant = ProductionHuntGeometry.Variant.INVALID
	probe.setup(world, 80, 42)
	var report: Dictionary = probe.finish_report()
	_check(probe.finished and not report["fixture_valid"] and not str(report["fixture_error"]).is_empty(), "Invalid geometry produces an explicit finite failure report even before a prey exists")
	_check(world.store.count == 0 and not world.has_pending_observer_commands(), "Rejected setup creates no partial animal roster")
	_close(world)
	world = _new_world()
	probe = ProductionHuntProbe.new()
	probe.setup(world, 80, 42)
	world._apply_commands()
	probe.observe_step_start(world)
	world.store.relocate(probe._bait, Vector2(13, 700))
	world.tick = 240
	probe.before_step(world)
	report = probe.finish_report()
	_check(probe.finished and not report["fixture_valid"] and report["requested_hunter_positions"].size() == 3, "Runtime out-of-bounds stimulus preserves requested coordinates and fails without clamp/retry")
	_check(world.counts()[SimTypes.Species.WOLF] == 0 and not world.has_pending_observer_commands(), "Runtime rejection cannot enqueue a partial wolf batch")
	_close(world)
