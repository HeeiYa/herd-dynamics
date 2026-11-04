class_name AgentInspector
extends VBoxContainer
## Read-only character card with an always-visible summary and diagnostics.
## Receives formatted display values from AgentInspectorPresenter.

signal follow_requested
signal remove_requested

@onready var _title: Label = get_node("Title")
@onready var _summary: RichTextLabel = get_node("Summary")
@onready var _hunger: ProgressBar = get_node("HungerRow/Hunger")
@onready var _hunger_row: HBoxContainer = get_node("HungerRow")
@onready var _details_heading: Label = get_node("DetailsHeading")
@onready var _details: RichTextLabel = get_node("Details")
@onready var _actions: HBoxContainer = get_node("Actions")
@onready var _empty: Label = get_node("Empty")

func _ready() -> void:
	$Actions/Follow.pressed.connect(func() -> void: follow_requested.emit())
	$Actions/Remove.pressed.connect(func() -> void: remove_requested.emit())
	_show_empty(true)

func _show_empty(empty: bool) -> void:
	_empty.visible = empty
	for node: Control in [_title, _summary, _hunger_row, _actions, _details_heading, _details]:
		node.visible = not empty
