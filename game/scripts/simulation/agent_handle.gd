class_name AgentHandle
extends RefCounted
## A life identity. Read-only properties prevent callers from changing its meaning.
var _slot: int
var _generation: int
var _world_epoch: int
var slot: int:
	get: return _slot
var generation: int:
	get: return _generation
var world_epoch: int:
	get: return _world_epoch

func _init(new_slot: int = -1, new_generation: int = 0, new_epoch: int = 0) -> void:
	_slot = new_slot
	_generation = new_generation
	_world_epoch = new_epoch

func same_life(other: AgentHandle) -> bool:
	return other != null and slot == other.slot and generation == other.generation and world_epoch == other.world_epoch

func key() -> String:
	return "%d:%d:%d" % [world_epoch, slot, generation]
