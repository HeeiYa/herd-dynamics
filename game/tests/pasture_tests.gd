extends SceneTree
## Ecology quantities, generation geometry and safe parameter application.
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
	_test_resource_units()
	_test_rate_change()
	_test_stomach_and_reset()
	await _test_local_foraging()
	await _test_parameter_drafts()
	print("PASTURE_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_resource_units() -> void:
	for width: float in [40.0, 80.0, 160.0]:
		var config := SimulationConfig.new()
		config.world_size = Vector2(803, 487)
		config.resource_cell_size = width
		config.initial_grass_coverage = 0.6
		config.grass_capacity = 2.0
		config.grass_recovery_rate = 0.0
		var resources := ResourceGrid.new(config)
		var capacity: float = 0.0
		var consumed: float = 0.0
		for cell: int in resources.cell_count:
			capacity += resources.food_capacity(cell)
			consumed += resources.consume(cell, 1000.0, 0)
			_check(is_zero_approx(resources.get_effective_amount(cell, 1)), "Consumption depletes actual cell capacity")
		_check(absf(capacity - config.world_size.x * config.world_size.y / ResourceGrid.STANDARD_AREA * 2.0) < 0.0001, "Subdividing or cropping cells conserves total capacity")
		_check(absf(consumed - capacity * 0.6) < 0.0001, "Food transferred equals initial coverage times capacity")

func _test_rate_change() -> void:
	var config := SimulationConfig.new()
	config.initial_grass_coverage = 0.2
	config.grass_recovery_rate = 0.1
	var resources := ResourceGrid.new(config)
	var before: float = resources.get_effective_amount(0, 59)
	resources.set_recovery_rate(0.2, 60, config.fixed_dt)
	_check(absf(resources.get_effective_amount(0, 60) - 0.3) < 0.00001, "Changing rate cannot retroactively grow grass")
	_check(absf(resources.get_effective_amount(0, 59) - before) < 0.00001, "Previous display tick survives rate change")
	_check(absf(resources.get_effective_amount(0, 120) - 0.5) < 0.00001, "Only the future uses the new growth rate")
	resources.set_recovery_rate(0.0, 120, config.fixed_dt)
	_check(absf(resources.get_effective_amount(0, 300) - 0.5) < 0.00001, "Zero recovery is a valid experiment")
	var copy: ResourceGrid = resources.publication_copy(config)
	resources.consume(0, 1.0, 300)
	_check(absf(copy.get_effective_amount(0, 301) - 0.5) < 0.00001, "Resource publication independently owns its mutable columns")

func _test_stomach_and_reset() -> void:
	var config := SimulationConfig.new()
	var initial := ScenarioConfig.new()
	initial.sheep_count = 0
	initial.wolf_count = 0
	initial.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, initial)
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(100, 100))
	var wolf: AgentHandle = world.create_at(SimTypes.Species.WOLF, Vector2(200, 100))
	world.store.hunger[world.store.resolve(sheep)] = 0.5
	world.store.hunger[world.store.resolve(wolf)] = 0.5
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.STOMACH_CAPACITY, 2.0))
	world._apply_observer_commands()
	_check(absf(world.store.hunger[world.store.resolve(sheep)] - 0.75) < 0.00001, "Bigger stomach does not create stored food")
	_check(is_equal_approx(world.store.hunger[world.store.resolve(wolf)], 0.5), "Sheep capacity does not change wolves")
	world.queue_tuning(TuningCatalog.Change.new(TuningCatalog.Param.STOMACH_CAPACITY, 0.25))
	world._apply_observer_commands()
	_check(is_zero_approx(world.store.hunger[world.store.resolve(sheep)]), "Smaller stomach clamps excess reserve")
	var epoch: int = world.store.epoch
	var larger: ScenarioConfig = initial.duplicate(true) as ScenarioConfig
	larger.pasture = PastureSettings.new()
	larger.pasture.world_size = Vector2(3200, 2000)
	larger.pasture.grass_cell_size = 40.0
	world.reset(larger)
	_check(world.store.epoch == epoch + 1 and not world.store.is_alive(sheep), "Changing geometry creates a new life epoch")
	_check(world.resources.columns == 80 and world.resources.rows == 50, "Resource grid uses the new independent resolution")
	_check(world.grid.columns == 40 and world.grid.rows == 25, "Perception grid size is independent of grass resolution")
	_check(is_equal_approx(config.sheep_stomach_capacity, 0.25), "Applied ecological tuning survives generation")
	var owned: ScenarioConfig = larger.validated_copy()
	larger.pasture.world_size = Vector2(6400, 4000)
	_check(owned.pasture.world_size == Vector2(3200, 2000), "Generation command owns nested settings")
	larger.pasture.grass_cell_size = NAN
	_check(larger.validated_copy() == null, "Non-finite geometry is rejected before reset")
	world.free()

func _test_local_foraging() -> void:
	var config := SimulationConfig.new()
	config.ai_budget_usec = 100000
	config.initial_grass_coverage = 0.0
	config.grass_recovery_rate = 0.0
	config.sheep_metabolism = 0.0
	var initial := ScenarioConfig.new()
	initial.sheep_count = 0
	initial.wolf_count = 0
	initial.dog_count = 0
	var world := SimulationWorld.new()
	root.add_child(world)
	world.setup(config, initial)
	var sheep: AgentHandle = world.create_at(SimTypes.Species.SHEEP, Vector2(360, 360))
	world.store.hunger[world.store.resolve(sheep)] = 0.9
	await process_frame
	var origin: Vector2 = world.store.position_current[0]
	for tick: int in 120:
		world.ai.begin_frame()
		world.step()
	var intent: MotionIntent = world.intents.get_intent(sheep, world.tick)
	_check(intent != null and intent.behavior == SimTypes.Behavior.SEARCH, "Hungry sheep explores when all nearby cells are depleted")
	_check(world.store.position_current[0].distance_to(origin) > 20.0, "Empty pasture does not leave a sheep grazing in place")
	# Restart a controlled one-sheep fixture with exactly one rich neighbor.
	world.reset(initial)
	sheep = world.create_at(SimTypes.Species.SHEEP, origin)
	world.store.hunger[world.store.resolve(sheep)] = 0.9
	var cell: int = world.resources.cell_at(origin)
	var neighbor: int = cell + 1
	world.resources._amount[neighbor] = 1.0
	world.resources._previous_amount[neighbor] = 1.0
	await process_frame
	for tick: int in 240:
		world.ai.begin_frame()
		world.step()
	_check(world.resources.get_effective_amount(neighbor, world.tick) < 0.95, "Sheep migrates to adjacent food and consumes it")
	_check(world.store.hunger[0] < 0.8, "Migration supplies actual food to the stomach")
	# These threshold checks use the same bounded lookup as the production BT.
	world.resources._amount.fill(0.0)
	world.resources._previous_amount.fill(0.0)
	world.resources._materialized_tick.fill(0)
	world.resources._previous_tick.fill(0)
	world.resources._amount[neighbor] = 0.1
	world.resources._previous_amount[neighbor] = 0.1
	_check(world.resources.best_neighbor(origin, 1, 0, sheep) == -1, "Barely regrown grass does not trigger an immediate return")
	world.resources.set_recovery_rate(0.1, 0, config.fixed_dt)
	_check(world.resources.best_neighbor(origin, 1, 60, sheep) >= 0, "Recovered grass becomes eligible without an eager world update")
	world.free()

func _test_parameter_drafts() -> void:
	var catalog := TuningCatalog.new(SimulationConfig.new(), AISettings.new())
	var panel: TuningPanel = preload("res://scenes/ui/tuning_panel.tscn").instantiate() as TuningPanel
	root.add_child(panel)
	panel.setup(catalog, func(_change: TuningCatalog.Change) -> bool: return false)
	var row: TuningPanel.Row = panel._rows[TuningCatalog.Param.WORLD_WIDTH]
	panel._submit(row, 3200.0)
	_check(panel.generation_draft().world_size.x == 3200.0, "Structural edits remain local generation drafts")
	_check(catalog.get_parameter(TuningCatalog.Param.WORLD_WIDTH).value == 1600.0, "Draft does not mutate current world size")
	panel._clear_pending()
	_check(row.pending, "Unrelated live parameter acknowledgement cannot erase a generation draft")
	panel._on_reset(3)
	_check(not row.pending and panel.generation_draft().world_size.x == 1600.0, "Reset discards uncommitted generation gestures")
	panel.queue_free()
	await process_frame
