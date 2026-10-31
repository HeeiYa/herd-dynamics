class_name PastureSettings
extends Resource
## An owned generation draft. Live geometry changes only at a world reset.
@export var world_size: Vector2 = Vector2(1600.0, 1000.0)
@export var grass_cell_size: float = 80.0
@export var initial_coverage: float = 0.675
@export var food_per_standard_area: float = 1.0

static func from_config(config: SimulationConfig) -> PastureSettings:
	var result := PastureSettings.new()
	result.world_size = config.world_size
	result.grass_cell_size = config.resource_cell_size
	result.initial_coverage = config.initial_grass_coverage
	result.food_per_standard_area = config.grass_capacity
	return result

func validated_copy() -> PastureSettings:
	if not world_size.is_finite() or not is_finite(grass_cell_size) or not is_finite(initial_coverage) or not is_finite(food_per_standard_area):
		return null
	if world_size.x < 320.0 or world_size.x > 6400.0 or world_size.y < 240.0 or world_size.y > 4000.0:
		return null
	if grass_cell_size < 40.0 or grass_cell_size > 160.0 or initial_coverage < 0.0 or initial_coverage > 1.0:
		return null
	if food_per_standard_area < 0.05 or food_per_standard_area > 8.0:
		return null
	return duplicate() as PastureSettings

func apply_to(config: SimulationConfig) -> void:
	config.world_size = world_size
	config.resource_cell_size = grass_cell_size
	config.initial_grass_coverage = initial_coverage
	config.grass_capacity = food_per_standard_area
