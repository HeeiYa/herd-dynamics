class_name ScenarioConfig
extends Resource
enum Layout { PASTURE, TWO_FLOCKS, CROWDED }
@export var layout: Layout = Layout.PASTURE
@export var random_seed: int = 42
@export var sheep_count: int = 40
@export var wolf_count: int = 4
@export var dog_count: int = 2
