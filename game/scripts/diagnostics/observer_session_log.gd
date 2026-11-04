class_name ObserverSessionLog
extends RefCounted
## Append-only local evidence of applied observer actions. No simulation writes.
## Controls and small opt-in endurance records; never a per-frame telemetry stream.

var path: String = ""
var _file: FileAccess
var _sequence: int = 0
var _source: SimulationAccess
const QUEUE_LIMIT: int = 4096
const ENDURANCE_EVENT_RESERVE: int = 64
const ENDURANCE_LINE_LIMIT_BYTES: int = 16384
var _writer := Thread.new()
var _mutex := Mutex.new()
var _ready := Semaphore.new()
var _lines: Array[String] = []
var _closing: bool = false
var _failed: bool = false
var _accepted: int = 0
var _written: int = 0
var _dropped: int = 0
var _sample_dropped: int = 0 # Main-thread producer only, including try-lock misses.
var _queue_peak: int = 0
var _inflight: int = 0

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
		_dropped += 1
		_mutex.unlock()
		return
	if _lines.size() >= QUEUE_LIMIT:
		_dropped += 1
		_mutex.unlock()
		# Inline diagnostics have no reliable transport to throttle. Fail loudly
		# instead of silently claiming a complete recording or blocking input.
		push_error("Observer log queue is full; inline evidence is incomplete: " + path)
		return
	_sequence += 1
	_accepted += 1
	_lines.append(line)
	_queue_peak = maxi(_queue_peak, _lines.size())
	_mutex.unlock()
	_ready.post()

## Main-thread diagnostic producer only. Small records share the one writer;
## they never enter the reliable observer stream or consume its reserved room.
func try_append_endurance_sample(record: Dictionary) -> bool:
	if record.size() > 64:
		_sample_dropped += 1
		return false
	for key: Variant in record:
		if key is not String or not _endurance_value_allowed(record[key]):
			_sample_dropped += 1
			return false
	var entry: Dictionary = record.duplicate(true)
	entry["sequence"] = _sequence
	var line: String = JSON.stringify(entry)
	if line.to_utf8_buffer().size() > ENDURANCE_LINE_LIMIT_BYTES or not _mutex.try_lock():
		_sample_dropped += 1
		return false
	if _failed or _closing or not _writer.is_started() or _lines.size() >= QUEUE_LIMIT - ENDURANCE_EVENT_RESERVE:
		_mutex.unlock()
		_sample_dropped += 1
		return false
	_sequence += 1
	_accepted += 1
	_lines.append(line)
	_queue_peak = maxi(_queue_peak, _lines.size())
	_mutex.unlock()
	_ready.post()
	return true

func _endurance_value_allowed(value: Variant) -> bool:
	if value == null or value is bool or value is int or value is float:
		return true
	if value is String:
		return value.length() <= 512
	if value is Array and value.size() <= 16:
		for item: Variant in value:
			if item is not int and item is not float and item is not bool:
				return false
		return true
	return false

## The caller must be the same main-thread producer. Compare accepted/written
## only after close; while running there may be a whole bounded batch in flight.
func writer_status() -> Dictionary:
	_mutex.lock()
	var result: Dictionary = {"failed": _failed, "closing": _closing,
		"accepted": _accepted, "written": _written, "dropped": _dropped + _sample_dropped,
		"sample_dropped": _sample_dropped, "queue_depth": _lines.size(),
		"queue_peak": _queue_peak, "inflight": _inflight}
	_mutex.unlock()
	return result

func _write_loop() -> void:
	while true:
		_ready.wait()
		_mutex.lock()
		var batch: Array[String] = _lines
		_lines = []
		_inflight = batch.size()
		var closing: bool = _closing
		_mutex.unlock()
		for line: String in batch:
			_file.store_line(line)
		if not batch.is_empty():
			_file.flush()
		var error: Error = _file.get_error()
		_mutex.lock()
		if error != OK:
			_failed = true
			_dropped += batch.size() + _lines.size()
			_lines.clear()
			_inflight = 0
			_mutex.unlock()
			push_error("Observer log write failed; evidence is incomplete: %s (%s)" % [path, error_string(error)])
			break
		_written += batch.size()
		_inflight = 0
		_mutex.unlock()
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
