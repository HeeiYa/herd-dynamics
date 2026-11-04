class_name ObserverSessionLog
extends RefCounted
## Append-only local evidence of applied observer actions. No simulation writes.
## Only explicit controls are recorded; this is not a per-frame telemetry stream.

var path: String = ""
var _file: FileAccess
var _sequence: int = 0
var _source: SimulationAccess
const QUEUE_LIMIT: int = 4096
var _writer := Thread.new()
var _mutex := Mutex.new()
var _ready := Semaphore.new()
var _lines: Array[String] = []
var _closing: bool = false
var _failed: bool = false

func start(world: SimulationAccess, runner: SimulationRunner, output_path: String = "") -> bool:
	_source = world
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
	var started: Error = _writer.start(_write_loop)
	if started != OK:
		_file.close()
		_file = null
		push_error("Cannot start observer log writer: " + error_string(started))
		return false
	world.observer_event_ready = can_accept
	world.observer_event.connect(_append)
	world.record_observer_event("session", {
		"schema": 1, "engine": Engine.get_version_info().string,
		"utc": Time.get_datetime_string_from_system(true),
		"counts": [world.scenario.sheep_count, world.scenario.wolf_count, world.scenario.dog_count],
		"parameters": world.tuning.snapshot(), "paused": runner.paused, "time_scale": runner.speed,
	})
	return true

## Worker facts stay in their reliable FIFO until the bounded disk queue has
## room. A slow disk applies backpressure without a file operation on the UI.
func can_accept() -> bool:
	if not _mutex.try_lock():
		return false
	var available: bool = _failed or _lines.size() < QUEUE_LIMIT
	_mutex.unlock()
	return available

func _append(record: Dictionary) -> void:
	var entry: Dictionary = record.duplicate(true)
	entry["sequence"] = _sequence
	var line: String = JSON.stringify(entry)
	_mutex.lock()
	if _failed or _closing:
		_mutex.unlock()
		return
	if _lines.size() >= QUEUE_LIMIT:
		_mutex.unlock()
		# Inline diagnostics have no reliable transport to throttle. Fail loudly
		# instead of silently claiming a complete recording or blocking input.
		push_error("Observer log queue is full; inline evidence is incomplete: " + path)
		return
	_sequence += 1
	_lines.append(line)
	_mutex.unlock()
	_ready.post()

func _write_loop() -> void:
	while true:
		_ready.wait()
		_mutex.lock()
		var batch: Array[String] = _lines
		_lines = []
		var closing: bool = _closing
		_mutex.unlock()
		for line: String in batch:
			_file.store_line(line)
		if not batch.is_empty():
			_file.flush()
		var error: Error = _file.get_error()
		if error != OK:
			_mutex.lock()
			_failed = true
			_mutex.unlock()
			push_error("Observer log write failed; evidence is incomplete: %s (%s)" % [path, error_string(error)])
			break
		if closing:
			break
	_file.close()
	_file = null

## Shutdown only. Drain accepted lines before closing the writer and its file.
func close() -> void:
	if _source != null:
		if _source.observer_event.is_connected(_append):
			_source.observer_event.disconnect(_append)
		if _source.observer_event_ready == can_accept:
			_source.observer_event_ready = Callable()
	_source = null
	if _writer.is_started():
		_mutex.lock()
		_closing = true
		_mutex.unlock()
		_ready.post()
		_writer.wait_to_finish()
