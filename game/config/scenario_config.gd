class_name ScenarioConfig
extends Resource
## Initial conditions only. Presets never schedule chases or outcomes.
## PASTURE, TWO_FLOCKS and CROWDED are the V1 layouts used by recorded
## benchmarks; their placement code is frozen. Later layouts are appended so
## numeric benchmark arguments keep their historical meaning.
enum Layout { PASTURE, TWO_FLOCKS, CROWDED, NATURAL, SCATTERED, HERDS_AND_THREATS }
@export var layout: Layout = Layout.PASTURE
@export var random_seed: int = 42
@export var sheep_count: int = 40
@export var wolf_count: int = 4
@export var dog_count: int = 2
@export var pasture: PastureSettings

static func is_planned(value: Layout) -> bool:
	return value == Layout.NATURAL or value == Layout.SCATTERED or value == Layout.HERDS_AND_THREATS

func validated_copy() -> ScenarioConfig:
	if sheep_count < 0 or wolf_count < 0 or dog_count < 0:
		return null
	if layout < Layout.PASTURE or layout > Layout.HERDS_AND_THREATS:
		return null
	if pasture != null and pasture.validated_copy() == null:
		return null
	return duplicate(true) as ScenarioConfig
