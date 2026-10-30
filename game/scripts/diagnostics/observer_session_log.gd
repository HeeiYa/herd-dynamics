class_name ObserverSessionLog
extends RefCounted
## Append-only local evidence of applied observer actions. No simulation writes.
## Only explicit controls are recorded; this is not a per-frame telemetry stream.

var path: String = ""
var _file: FileAccess
var _sequence: int = 0

func start(world: SimulationWorld, runner: SimulationRunner, output_path: String = "") -> bool:
	path = output_path
	if path.is_empty():
		var directory: String = OS.get_executable_path().get_base_dir().path_join("observer-sessions")
		if OS.has_feature("editor"):
			directory = ProjectSettings.globalize_path("res://").path_join("../docs/evidence/observer-sessions").simplify_path()
		var filename: String = "session-%s-%d-%d.jsonl" % [
			Time.get_datetime_string_from_system(true).replace(":", "-"), OS.get_process_id(), Time.get_ticks_usec()]
		path = directory.path_join(filename)
	var error: Error = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error != OK:
		push_error("Cannot create observer log directory: %s (%s)" % [path, error_string(error)])
		return false
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		push_error("Cannot open observer log: %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return false
	world.observer_event.connect(_append)
	world.record_observer_event("session", {
		"schema": 1, "engine": Engine.get_version_info().string,
		"utc": Time.get_datetime_string_from_system(true),
		"counts": [world.scenario.sheep_count, world.scenario.wolf_count, world.scenario.dog_count],
		"parameters": world.tuning.snapshot(), "paused": runner.paused, "time_scale": runner.speed,
	})
	return true

func _append(record: Dictionary) -> void:
	if _file == null:
		return
	var entry: Dictionary = record.duplicate(true)
	entry["sequence"] = _sequence
	_sequence += 1
	_file.store_line(JSON.stringify(entry))
	_file.flush()
	var error: Error = _file.get_error()
	if error != OK:
		push_error("Observer log write failed: %s (%s)" % [path, error_string(error)])
		close()

func close() -> void:
	if _file != null:
		_file.close()
		_file = null
