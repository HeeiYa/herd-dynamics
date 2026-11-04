extends SceneTree
## Real collapsed HUD: programmatic initialization and later text edits must agree.
var _checks: int = 0
var _failures: int = 0
var _main: Node2D
var _access: SimulationAccess

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _until(predicate: Callable, message: String) -> void:
	var deadline: int = Time.get_ticks_usec() + 5000000
	while not predicate.call() and Time.get_ticks_usec() < deadline:
		await process_frame
	_check(predicate.call(), message)

func _scenario(seed: int, sheep: int, wolves: int, dogs: int) -> ScenarioConfig:
	var scenario := ScenarioConfig.new()
	scenario.layout = ScenarioConfig.Layout.NATURAL
	scenario.random_seed = seed
	scenario.sheep_count = sheep
	scenario.wolf_count = wolves
	scenario.dog_count = dogs
	return scenario

func _report_inputs(stage: String) -> void:
	var inputs: Dictionary[String, SpinBox] = {
		"seed": _main.hud.seed, "sheep": _main.hud.sheep,
		"wolves": _main.hud.wolves, "dogs": _main.hud.dogs,
	}
	var record: Dictionary = {"stage": stage, "panel_open": _main.hud.panel_open}
	for name: String in inputs:
		var input: SpinBox = inputs[name]
		record[name] = {
			"value": input.value, "text": input.get_line_edit().text,
			"visible": input.is_visible_in_tree(), "focus": input.get_line_edit().has_focus(),
		}
	print("SCENARIO_INPUT_STATE " + JSON.stringify(record))

func _check_inputs(expected: PackedInt64Array, message: String) -> void:
	var inputs: Array[SpinBox] = [_main.hud.seed, _main.hud.sheep, _main.hud.wolves, _main.hud.dogs]
	for index: int in inputs.size():
		_check(
			int(inputs[index].value) == expected[index] and inputs[index].get_line_edit().text == str(expected[index]),
			message + " field %d" % index
		)

func _matches_scenario(seed: int, sheep: int, wolves: int, dogs: int) -> bool:
	var current: ScenarioConfig = _access.scenario
	return current.random_seed == seed and current.sheep_count == sheep and current.wolf_count == wolves and current.dog_count == dogs

func _run() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node2D
	_main.set_meta("initial_scenario", _scenario(73, 24, 0, 0))
	if OS.get_cmdline_user_args().has("--simulation=inline"):
		_main.set_meta("inline_simulation", true)
	root.add_child(_main)
	current_scene = _main
	await _until(func() -> bool: return _main._access != null and _main.observer.hud != null, "Scene services initialize")
	_access = _main._access
	_report_inputs("initialized")
	_check(not _main.hud.panel_open and not _main.hud.seed.is_visible_in_tree(), "Scenario inputs really start hidden in the collapsed HUD")
	await _until(func() -> bool: return _access.tick >= 5, "Initial population advances")
	for frame: int in 20:
		await process_frame
	_report_inputs("hidden_after_frames")
	_check_inputs(PackedInt64Array([73, 24, 0, 0]), "Hidden initialization keeps values and text aligned")
	_main._runner.request_pause(true)
	await _until(func() -> bool: return _main._runner.paused, "Pause acknowledges before reset")
	var epoch: int = _access.store.epoch
	(_main.hud.find_child("Reset", true, false) as Button).pressed.emit()
	await _until(func() -> bool: return _access.store.epoch > epoch, "Collapsed top-bar reset is applied")
	_check(_matches_scenario(73, 24, 0, 0), "Immediate reset preserves the complete programmatic scenario")
	# Setting the same values again must still normalize text; Range may emit no signal.
	_main.observer.apply_scenario(_scenario(73, 24, 0, 0))
	_check_inputs(PackedInt64Array([73, 24, 0, 0]), "Explicit apply synchronizes in the same stack")
	epoch = _access.store.epoch
	_main.observer.reset_scenario()
	await _until(func() -> bool: return _access.store.epoch > epoch, "Same-stack apply and reset is acknowledged")
	_check(_matches_scenario(73, 24, 0, 0), "Same-stack reset retains all counts and seed")
	# Only inspect out-of-range drafts; never request this deliberately huge world.
	_main.observer.apply_scenario(_scenario(2000000, -1, 2000, -1))
	_check_inputs(PackedInt64Array([999999, 0, 1000, 0]), "Programmatic values still use each SpinBox range")
	_main.observer.apply_scenario(_scenario(73, 24, 0, 0))
	_main.hud.toggle_panel()
	_main.hud.tabs.current_tab = 2
	await process_frame
	_main.hud.seed.get_line_edit().text = "91"
	_main.hud.sheep.get_line_edit().text = "35"
	_main.hud.wolves.get_line_edit().text = "-4"
	_main.hud.dogs.get_line_edit().text = "0"
	_main.hud.sheep.get_line_edit().grab_focus()
	_main.observer.refresh_panel()
	_check(_main.hud.sheep.get_line_edit().text == "35" and _main.hud.sheep.get_line_edit().has_focus(), "Refresh preserves a real uncommitted edit and focus")
	_report_inputs("typed_before_reset")
	epoch = _access.store.epoch
	(_main.hud.find_child("ResetScenario", true, false) as Button).pressed.emit()
	await _until(func() -> bool: return _access.store.epoch > epoch, "Reset button commits text without focus loss")
	_check(_matches_scenario(91, 35, 0, 0), "Typed scenario keeps UI-004 semantics and clamps negative counts")
	_report_inputs("typed_after_reset")
	print("SCENARIO_INPUT_TESTS checks=%d failures=%d" % [_checks, _failures])
	_main.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)
