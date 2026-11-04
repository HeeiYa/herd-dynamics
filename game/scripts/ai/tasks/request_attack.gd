extends "res://scripts/ai/tasks/context_action.gd"
## Interaction owns windup, hit window, cooldown and capture after accepting this token.
func _tick(_delta: float) -> Status:
	var ai: AICoordinator = context.coordinator
	if context.prey == null or context.observation_for(context.prey.handle) == null:
		return FAILURE
	var attempt_ticks: int = ai.config.attack_windup_ticks + ai.config.attack_window_ticks + ai.config.attack_cooldown_ticks
	if context.current_tick >= entered_tick + attempt_ticks:
		# Retrying is still the same running pursuit. SUCCESS would clear the
		# movement intent until the next scheduled decision, abruptly stopping it.
		# Replace the token and immutable intent in this one owner-thread update;
		# Interaction still decides acceptance, windup, contact and cooldown.
		token = context.new_token()
		entered_tick = context.current_tick
	write_intent(SimTypes.IntentMode.ATTACK, SimTypes.Behavior.ATTACK, context.prey.position, ai.settings.wolf_speed, "Attack token handed to interaction", context.prey.handle)
	return RUNNING
