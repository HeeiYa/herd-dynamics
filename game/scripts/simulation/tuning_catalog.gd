class_name TuningCatalog
extends RefCounted
## The single owner of runtime parameter edits. UI submits Change records via
## SimulationWorld.queue_tuning; apply() runs only at the stage-0 safe point.
## Defaults are captured from the configs at construction, so "restore default"
## always means this world's starting values, not hard-coded literals.
##
## Speed parameters are per-species multipliers over the BT speed settings.
## Running intents keep their speed until the next decision rewrites them.

enum Param {
	SHEEP_SPEED,
	WOLF_SPEED,
	DOG_SPEED,
	PERCEPTION_RADIUS,
	SEPARATION_STRENGTH,
	COHESION_WEIGHT,
	DOG_PROTECTION_RADIUS,
	DOG_LEASH_RADIUS,
}

class Parameter extends RefCounted:
	var key: Param
	var label: String
	var scope: String
	var unit: String
	var description: String
	var minimum: float
	var maximum: float
	var step: float
	var default_value: float
	var value: float

class Change extends RefCounted:
	var key: Param
	var value: float

	func _init(change_key: Param = Param.SHEEP_SPEED, change_value: float = 0.0) -> void:
		key = change_key
		value = change_value

class LogEntry extends RefCounted:
	var tick: int
	var epoch: int
	var key: Param
	var previous: float
	var value: float

var parameters: Array[Parameter] = []
# Local run record of applied edits, also printed to the log as TUNING lines.
var history: Array[LogEntry] = []
const HISTORY_LIMIT: int = 256
var applied_count: int = 0
var _config: SimulationConfig
var _settings: AISettings
# Base values of every BT speed field, captured before any multiplier.
var _base_speeds: Dictionary[StringName, float] = {}

const SPEED_FIELDS: Dictionary[Param, Array] = {
	Param.SHEEP_SPEED: [&"sheep_speed", &"sheep_flee_speed", &"graze_speed"],
	Param.WOLF_SPEED: [&"wolf_speed", &"wolf_search_speed"],
	Param.DOG_SPEED: [&"dog_speed", &"guard_speed"],
}

func _init(config: SimulationConfig, settings: AISettings) -> void:
	_config = config
	_settings = settings
	for fields: Array in SPEED_FIELDS.values():
		for field: StringName in fields:
			_base_speeds[field] = float(_settings.get(field))
	_add(Param.SHEEP_SPEED, "羊移动速度", "物种：羊", "×", "吃草、走动和逃跑速度的共同倍率。", 0.5, 1.6, 0.05, 1.0)
	_add(Param.WOLF_SPEED, "狼移动速度", "物种：狼", "×", "搜索、追击和撤退速度的共同倍率。", 0.5, 1.6, 0.05, 1.0)
	_add(Param.DOG_SPEED, "牧羊犬移动速度", "物种：牧羊犬", "×", "巡逻和拦截速度的共同倍率。", 0.5, 1.6, 0.05, 1.0)
	_add(Param.PERCEPTION_RADIUS, "AI 感知半径", "全局", "px", "每个角色扫描附近角色的距离；不是镜头视野。", 80.0, 320.0, 10.0, _config.perception_radius)
	_add(Param.SEPARATION_STRENGTH, "分离强度", "全局", "px/s", "相邻身体互相让开的最大推力。", 30.0, 160.0, 5.0, _config.separation_strength)
	_add(Param.COHESION_WEIGHT, "群聚强度", "羊", "", "走动的羊向邻近同伴靠拢的权重。", 0.0, 0.6, 0.02, _config.cohesion_weight)
	_add(Param.DOG_PROTECTION_RADIUS, "犬保护范围", "物种：牧羊犬", "px", "狼进入羊群该半径内时，犬视为威胁。", 100.0, 320.0, 10.0, _settings.protection_radius)
	_add(Param.DOG_LEASH_RADIUS, "犬追击范围", "物种：牧羊犬", "px", "拦截时离开羊群锚点的最远距离。", 120.0, 420.0, 10.0, _config.dog_leash_radius)

func _add(key: Param, label: String, scope: String, unit: String, description: String, minimum: float, maximum: float, step: float, default_value: float) -> void:
	var parameter := Parameter.new()
	parameter.key = key
	parameter.label = label
	parameter.scope = scope
	parameter.unit = unit
	parameter.description = description
	parameter.minimum = minimum
	parameter.maximum = maximum
	parameter.step = step
	parameter.default_value = default_value
	parameter.value = default_value
	assert(parameters.size() == key, "Parameters are stored in Param order")
	parameters.append(parameter)

func get_parameter(key: Param) -> Parameter:
	return parameters[key]

func is_modified(key: Param) -> bool:
	var parameter: Parameter = parameters[key]
	return not is_equal_approx(parameter.value, parameter.default_value)

## Stage 0 only. Values are clamped to the published range.
func apply(change: Change, tick: int, epoch: int = 0) -> LogEntry:
	assert(validated_copy(change) != null, "Only validated tuning commands reach stage 0")
	var parameter: Parameter = parameters[change.key]
	var value: float = clampf(change.value, parameter.minimum, parameter.maximum)
	if is_equal_approx(value, parameter.value):
		return null
	var entry := LogEntry.new()
	entry.tick = tick
	entry.epoch = epoch
	entry.key = change.key
	entry.previous = parameter.value
	entry.value = value
	history.append(entry)
	if history.size() > HISTORY_LIMIT:
		history.pop_front()
	applied_count += 1
	print("TUNING epoch=%d tick=%d %s %.3f -> %.3f" % [epoch, tick, Param.keys()[change.key], parameter.value, value])
	parameter.value = value
	_write(change.key, value)
	return entry

## Own a bounded finite snapshot; callers cannot mutate a queued command.
func validated_copy(change: Change) -> Change:
	if change == null or change.key < 0 or change.key >= parameters.size() or not is_finite(change.value):
		return null
	var parameter: Parameter = parameters[change.key]
	return Change.new(change.key, clampf(change.value, parameter.minimum, parameter.maximum))

func snapshot() -> Dictionary:
	var result: Dictionary = {}
	for parameter: Parameter in parameters:
		result[Param.keys()[parameter.key]] = parameter.value
	return result

func _write(key: Param, value: float) -> void:
	match key:
		Param.SHEEP_SPEED, Param.WOLF_SPEED, Param.DOG_SPEED:
			for field: StringName in SPEED_FIELDS[key]:
				_settings.set(field, _base_speeds[field] * value)
		Param.PERCEPTION_RADIUS:
			_config.perception_radius = value
		Param.SEPARATION_STRENGTH:
			_config.separation_strength = value
		Param.COHESION_WEIGHT:
			_config.cohesion_weight = value
		Param.DOG_PROTECTION_RADIUS:
			_settings.protection_radius = value
		Param.DOG_LEASH_RADIUS:
			_config.dog_leash_radius = value

func format_value(key: Param, value: float) -> String:
	var parameter: Parameter = parameters[key]
	if parameter.unit == "×":
		return "%.2f×" % value
	if parameter.unit.is_empty():
		return "%.2f" % value
	return "%d %s" % [roundi(value), parameter.unit]
