class_name ObserverHud
extends Control
## Editable scene composition. Controls report user actions; no simulation is started here.

enum Action { STEP, RESET, OVERVIEW, HIDE_UI, PANEL, SELECT, GRAB, PLACE, SPAWN_SHEEP, SPAWN_WOLVES, SPAWN_DOG, PAUSE }
signal action_requested(action: Action)
signal speed_changed(index: int)
signal species_changed(species: int)
signal overlays_changed
signal usable_rect_changed(area: Rect2)
const PANEL_GAP: float = 10.0
var ui_visible: bool = true
var panel_open: bool = false
var toast_seconds: float = 0.0

@onready var counts_label: Label = get_node("TopBar/Content/CountsLabel")
@onready var dogs: SpinBox = get_node("RightPanel/Tabs/场景/Scenario/DogsRow/Dogs")
@onready var inspector: AgentInspector = get_node("RightPanel/Tabs/角色/Inspector")
@onready var layout: OptionButton = get_node("RightPanel/Tabs/场景/Scenario/Layout")
@onready var panel_toggle: Button = get_node("TopBar/Content/PanelToggle")
@onready var pause: Button = get_node("TopBar/Content/Pause")
@onready var perf_card: PanelContainer = get_node("PerfCard")
@onready var perf_summary: Label = get_node("PerfCard/Content/Header/PerfSummary")
@onready var place_option: OptionButton = get_node("Toolbar/Tools/PlaceOption")
@onready var planner_label: Label = get_node("RightPanel/Tabs/场景/Scenario/PlannerLabel")
@onready var restore_button: Button = get_node("RestoreButton")
@onready var right_panel: PanelContainer = get_node("RightPanel")
@onready var scene_label: Label = get_node("TopBar/Content/SceneLabel")
@onready var seed: SpinBox = get_node("RightPanel/Tabs/场景/Scenario/SeedRow/Seed")
@onready var sheep: SpinBox = get_node("RightPanel/Tabs/场景/Scenario/SheepRow/Sheep")
@onready var speed: OptionButton = get_node("TopBar/Content/Speed")
@onready var stats: Label = get_node("PerfCard/Content/Stats")
@onready var tabs: TabContainer = get_node("RightPanel/Tabs")
@onready var time_label: Label = get_node("TopBar/Content/TimeLabel")
@onready var toast: Label = get_node("Toast")
@onready var toolbar: PanelContainer = get_node("Toolbar")
@onready var top_bar: PanelContainer = get_node("TopBar")
@onready var tuning: TuningPanel = get_node("RightPanel/Tabs/参数/Tuning")
@onready var wolves: SpinBox = get_node("RightPanel/Tabs/场景/Scenario/WolvesRow/Wolves")
var tool_buttons: Array[Button] = []
var overlay_buttons: Dictionary[StringName, Button] = {}

func _ready() -> void:
	(find_child("SingleStep", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.STEP))
	(find_child("Reset", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.RESET))
	(find_child("Overview", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.OVERVIEW))
	(find_child("HideUI", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.HIDE_UI))
	(find_child("RestoreButton", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.HIDE_UI))
	(find_child("PanelToggle", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.PANEL))
	(find_child("SelectTool", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.SELECT))
	(find_child("GrabTool", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.GRAB))
	(find_child("PlaceTool", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.PLACE))
	(find_child("ResetScenario", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.RESET))
	(find_child("SpawnSheep", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.SPAWN_SHEEP))
	(find_child("SpawnWolves", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.SPAWN_WOLVES))
	(find_child("SpawnDog", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.SPAWN_DOG))
	(find_child("Pause", true, false) as Button).pressed.connect(func() -> void: action_requested.emit(Action.PAUSE))
	speed.item_selected.connect(func(index: int) -> void: speed_changed.emit(index))
	place_option.item_selected.connect(func(index: int) -> void: species_changed.emit(index))
	tool_buttons.append(find_child("SelectTool", true, false) as Button)
	tool_buttons.append(find_child("GrabTool", true, false) as Button)
	tool_buttons.append(find_child("PlaceTool", true, false) as Button)
	overlay_buttons[&"destination"] = find_child("OverlayDestination", true, false) as Button
	overlay_buttons[&"destination"].pressed.connect(func() -> void: overlays_changed.emit())
	overlay_buttons[&"target"] = find_child("OverlayTarget", true, false) as Button
	overlay_buttons[&"target"].pressed.connect(func() -> void: overlays_changed.emit())
	overlay_buttons[&"perception"] = find_child("OverlayPerception", true, false) as Button
	overlay_buttons[&"perception"].pressed.connect(func() -> void: overlays_changed.emit())
	overlay_buttons[&"protection"] = find_child("OverlayProtection", true, false) as Button
	overlay_buttons[&"protection"].pressed.connect(func() -> void: overlays_changed.emit())
	overlay_buttons[&"marks"] = find_child("OverlayMarks", true, false) as Button
	overlay_buttons[&"marks"].pressed.connect(func() -> void: overlays_changed.emit())
	get_viewport().size_changed.connect(update_layout)
	for panel: Control in [top_bar, toolbar, right_panel]:
		panel.resized.connect(update_layout)
	var expand := find_child("ExpandPerformance", true, false) as Button
	expand.toggled.connect(func(pressed: bool) -> void:
		expand.text = "▾" if pressed else "▴"
		stats.visible = pressed
		perf_card.reset_size()
	)


func toggle_ui() -> void:
	ui_visible = not ui_visible
	for node: Control in [top_bar, toolbar, perf_card]:
		node.visible = ui_visible
	right_panel.visible = ui_visible and panel_open
	restore_button.visible = not ui_visible
	update_layout()

func toggle_panel() -> void:
	panel_open = not panel_open
	right_panel.visible = ui_visible and panel_open
	panel_toggle.text = "面板 ▸" if panel_open else "面板 ◂"
	update_layout()

## The pasture area the camera centers and fits: the viewport minus the
## measured rectangles of the visible docked panels. Other modules use the
## camera's conversions instead of re-deriving these offsets.
func update_layout() -> void:
	var viewport: Rect2 = get_viewport_rect()
	# Keep controls reachable on small windows; details remain in their panels.
	var compact: bool = viewport.size.x < 1200.0
	scene_label.visible = not compact
	time_label.visible = not compact
	var left: float = viewport.position.x
	var top: float = viewport.position.y
	var right: float = viewport.end.x
	if top_bar.visible:
		top = top_bar.get_global_rect().end.y
	if toolbar.visible:
		left = toolbar.get_global_rect().end.x + PANEL_GAP
	if right_panel.visible:
		right = right_panel.get_global_rect().position.x - PANEL_GAP
	usable_rect_changed.emit(Rect2(left, top, right - left, viewport.end.y - top))

func show_toast(text: String) -> void:
	if text.is_empty() or toast == null:
		return
	toast.text = text
	toast.reset_size()
	toast.visible = true
	toast.modulate.a = 1.0
	toast_seconds = 2.6

func _process(delta: float) -> void:
	if toast_seconds > 0.0:
		toast_seconds -= delta
		toast.modulate.a = clampf(toast_seconds / 0.4, 0.0, 1.0)
		if toast_seconds <= 0.0:
			toast.visible = false
