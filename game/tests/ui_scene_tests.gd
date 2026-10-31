extends SceneTree
## Scene composition can be previewed and interacted with without a world or GPU.
var _failures: int = 0
var _checks: int = 0
var _actions: Array[ObserverHud.Action] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _run() -> void:
	var hud: ObserverHud = preload("res://scenes/ui/observer_hud.tscn").instantiate() as ObserverHud
	root.add_child(hud)
	await process_frame
	hud.action_requested.connect(func(action: ObserverHud.Action) -> void: _actions.append(action))
	hud.pause.pressed.emit()
	_check(_actions == [ObserverHud.Action.PAUSE], "HUD reports actions without requiring simulation")
	_check(hud.theme == UiStyle.interface_theme(), "Editor scene and runtime use the same theme resource")
	_check(hud.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Transparent HUD root passes pasture input")
	_check(hud.find_children("*", "Node2D", true, false).is_empty(), "UI preview creates no world, camera or simulation nodes")
	hud.toggle_panel()
	_check(hud.right_panel.visible, "Sidebar is independently previewable")
	hud.toggle_ui()
	_check(not hud.right_panel.visible and hud.restore_button.visible, "Hide retains the restore control")
	hud.toggle_ui()
	_check(hud.right_panel.visible, "Restore retains the open-panel state")
	_check(hud.inspector.get_node("Empty").visible, "Inspector has a useful empty state before binding")
	_check(hud.tuning.get_node("Rows").get_child_count() == 0, "Tuning preview does not construct a live world")
	var parameter: Control = preload("res://scenes/ui/parameter_row.tscn").instantiate() as Control
	root.add_child(parameter)
	_check(parameter.get_node("Editor/Slider") is HSlider, "Parameter row is a reusable scene")
	_check(not (parameter.get_node("Editor/Slider") as HSlider).scrollable, "Wheel scrolling cannot silently edit tuning")
	parameter.free()
	hud.free()
	print("UI_SCENE_TESTS checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
