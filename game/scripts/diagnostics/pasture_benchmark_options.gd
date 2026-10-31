class_name PastureBenchmarkOptions
extends RefCounted
## Benchmark boundary only: explicit world/food settings and spatial A/B mode.
static func apply_to(config: SimulationConfig, options: Dictionary[String, String]) -> bool:
	var draft: PastureSettings = PastureSettings.from_config(config)
	for name: String in ["width", "height", "grass-cell", "grass-initial", "grass-density"]:
		if options.has(name) and not options[name].is_valid_float():
			return false
	draft.world_size = Vector2(
		float(options.get("width", str(draft.world_size.x))),
		float(options.get("height", str(draft.world_size.y)))
	)
	draft.grass_cell_size = float(options.get("grass-cell", str(draft.grass_cell_size)))
	draft.initial_coverage = float(options.get("grass-initial", str(draft.initial_coverage)))
	draft.food_per_standard_area = float(options.get("grass-density", str(draft.food_per_standard_area)))
	if draft.validated_copy() == null:
		return false
	draft.apply_to(config)
	match options.get("spatial", "auto"):
		"auto": config.spatial_backend = SimulationConfig.SpatialBackend.AUTO
		"dense": config.spatial_backend = SimulationConfig.SpatialBackend.DENSE
		"sparse": config.spatial_backend = SimulationConfig.SpatialBackend.SPARSE
		_: return false
	return true

static func describe(config: SimulationConfig) -> Dictionary:
	return {
		"world_size": [config.world_size.x, config.world_size.y],
		"resource_cell_size": config.resource_cell_size,
		"initial_coverage": config.initial_grass_coverage,
		"grass_capacity_per_standard_area": config.grass_capacity,
		"grass_recovery_per_second": config.grass_recovery_rate,
		"grazing_food_per_second": config.grazing_rate,
		"sheep_metabolism_food_per_second": config.sheep_metabolism,
		"sheep_stomach_food_capacity": config.sheep_stomach_capacity,
		"forage_cell_radius": config.forage_cell_radius,
		"spatial_requested": SimulationConfig.SpatialBackend.keys()[config.spatial_backend],
		"sparse_spatial": config.use_sparse_spatial(),
	}
