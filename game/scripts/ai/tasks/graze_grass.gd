extends "res://scripts/ai/tasks/context_action.gd"
var selected_cell: int = -1

func _enter() -> void:
	super._enter()
	selected_cell = -1

func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	if selected_cell < 0 or ai.resources.get_effective_amount(selected_cell, context.current_tick) < 0.03:
		selected_cell = ai.resources.best_cell(context.position(), ai.config.perception_radius, context.current_tick)
	if selected_cell < 0:
		return FAILURE
	var destination: Vector2 = ai.resources.cell_center(selected_cell)
	var arrived: bool = context.position().distance_to(destination) <= ai.settings.graze_arrival_distance
	var mode: int = SimTypes.IntentMode.GRAZE if arrived else SimTypes.IntentMode.MOVE
	var speed: float = 0.0 if arrived else ai.settings.graze_speed
	write_intent(mode, SimTypes.Behavior.GRAZE, destination, speed, "Local grass cell; interaction owns consumption", null, selected_cell)
	return RUNNING