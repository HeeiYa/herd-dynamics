class_name PoseBuffer
extends RefCounted
## A publication owns this lease, not its backing Array. Readers may retain
## individual immutable poses. Only the worker writes an exclusively owned lease.
var _records: Array[PublishedPose] = []

func prepare(count: int) -> void:
	_records.resize(count)
	# The exclusive lease can release the whole previous frame in one native
	# operation, before the worker tries to recycle its individual pose objects.
	_records.fill(null)

func size() -> int:
	return _records.size()

func at(dense: int) -> PublishedPose:
	return _records[dense]

func write(dense: int, pose: PublishedPose) -> void:
	_records[dense] = pose
