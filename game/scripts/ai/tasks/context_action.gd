extends BTAction
## Every running leaf owns exactly one intent token. Exit only clears its own work.
var context: AgentContext
var token: int = 0
var entered_tick: int = 0
var _task_identifier: StringName

func _setup() -> void:
	context = blackboard.get_var(AIBlackboard.CONTEXT) as AgentContext
	assert(context != null)
	_task_identifier = StringName(get_script().resource_path.get_file().get_basename())

func _enter() -> void:
	token = context.new_token()
	entered_tick = context.current_tick

func _exit() -> void:
	context.coordinator.intents.clear_owned(context.handle, token)
	context.coordinator.coordination.release(context.handle, token)
	if context.lease_token == token:
		context.lease_token = 0

func write_intent(mode: int, behavior: int, destination: Vector2, speed: float, reason: String, target: AgentHandle = null, resource_cell: int = -1) -> void:
	var intent := MotionIntent.new()
	intent.mode = mode
	intent.behavior = behavior
	intent.destination = destination.clamp(Vector2.ZERO, context.coordinator.config.world_size)
	intent.speed = speed
	intent.target = target
	intent.owner_token = token
	intent.expires_tick = context.current_tick + context.coordinator.config.intent_ticks
	intent.resource_cell = resource_cell
	intent.reason = reason
	context.coordinator.intents.write(context.handle, intent)
	# A failed higher-priority attempt must not replace the running leaf's label.
	context.task_token = token
	context.task_name = _task_identifier
