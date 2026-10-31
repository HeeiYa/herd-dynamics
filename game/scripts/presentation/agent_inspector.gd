class_name AgentInspector
extends VBoxContainer
## Read-only character card: a plain-language summary first, details on demand.
## Reads intents, the AI context (via AICoordinator.inspect) and attack records;
## it never writes simulation state.

signal follow_requested
signal remove_requested

@onready var _title: Label = get_node("Title")
@onready var _summary: RichTextLabel = get_node("Summary")
@onready var _hunger: ProgressBar = get_node("HungerRow/Hunger")
@onready var _hunger_row: HBoxContainer = get_node("HungerRow")
@onready var _details_toggle: Button = get_node("DetailsToggle")
@onready var _details: Label = get_node("Details")
@onready var _actions: HBoxContainer = get_node("Actions")
@onready var _empty: Label = get_node("Empty")

func _ready() -> void:
	$Actions/Follow.pressed.connect(func() -> void: follow_requested.emit())
	$Actions/Remove.pressed.connect(func() -> void: remove_requested.emit())
	_details_toggle.pressed.connect(_toggle_details)
	_show_empty(true)

func _toggle_details() -> void:
	_details.visible = _details_toggle.button_pressed
	_details_toggle.text = "详细调试 ▾" if _details.visible else "详细调试 ▸"

func _show_empty(empty: bool) -> void:
	_empty.visible = empty
	for node: Control in [_title, _summary, _hunger_row, _actions, _details_toggle]:
		node.visible = not empty
	_details.visible = not empty and _details_toggle.button_pressed
