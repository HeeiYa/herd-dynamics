extends "res://scripts/ai/tasks/context_action.gd"
var selected_cell: int = -1
var _destination: Vector2 = Vector2.ZERO
var _progress_distance: float = INF
var _progress_tick: int = 0
var _blocked_cell: int = -1
var _blocked_until_tick: int = 0
var _owner_life: AgentHandle

func _enter() -> void:
	super._enter()
	selected_cell = -1
	if _owner_life == null or not _owner_life.same_life(context.handle):
		_owner_life = context.handle
		_blocked_cell = -1
		_blocked_until_tick = 0

func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	if selected_cell < 0 or ai.resources.get_effective_amount(selected_cell, context.current_tick) < ResourceGrid.MIN_GRAZABLE_AMOUNT:
		_select_cell()
	if selected_cell < 0:
		return FAILURE
	var arrived: bool = ai.resources.can_graze_at(selected_cell, context.position())
	if not arrived and _approach_stalled():
		_blocked_cell = selected_cell
		_blocked_until_tick = context.current_tick + ai.settings.graze_retry_ticks * 2
		context.grazing_retry_after_tick = context.current_tick + ai.settings.graze_retry_ticks
		return FAILURE
	var mode: int = SimTypes.IntentMode.GRAZE if arrived else SimTypes.IntentMode.MOVE
	var speed: float = 0.0 if arrived else ai.settings.graze_speed
	write_intent(mode, SimTypes.Behavior.GRAZE, _destination, speed, "Committed local grass region; interaction owns consumption", null, selected_cell)
	return RUNNING

func _select_cell() -> void:
	var ai: AICoordinator = context.coordinator
	var excluded: int = _blocked_cell if context.current_tick < _blocked_until_tick else -1
	var current_cell: int = ai.resources.cell_at(context.position())
	if current_cell != excluded and ai.resources.get_effective_amount(current_cell, context.current_tick) >= ResourceGrid.MIN_GRAZABLE_AMOUNT:
		# Food already underfoot is reachable. Prefer it to a slightly richer
		# neighboring cell whose approach crosses the same crowded feeding group.
		selected_cell = current_cell
	else:
		selected_cell = ai.resources.best_cell(context.position(), ai.config.perception_radius, context.current_tick, excluded)
	if selected_cell < 0:
		return
	var dense: int = ai.store.resolve(context.handle)
	assert(dense >= 0, "An active grazing task must own a live agent")
	_destination = ai.resources.grazing_point(selected_cell, context.handle, ai.store.radius[dense])
	_progress_distance = context.position().distance_to(_destination)
	_progress_tick = context.current_tick

func _approach_stalled() -> bool:
	var settings: AISettings = context.coordinator.settings
	var distance: float = context.position().distance_to(_destination)
	if distance < _progress_distance - settings.graze_progress_distance:
		_progress_distance = distance
		_progress_tick = context.current_tick
	return context.current_tick - _progress_tick >= settings.graze_no_progress_ticks
