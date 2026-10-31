class_name MotionIntent
extends RefCounted
var actor: AgentHandle
var mode: int = SimTypes.IntentMode.STOP
var behavior: int = SimTypes.Behavior.IDLE
var target: AgentHandle
var destination: Vector2 = Vector2.ZERO
var speed: float = 0.0
var owner_token: int = 0
var revision: int = 0
var expires_tick: int = 0
var resource_cell: int = -1
var reason: String = ""

func publication_copy() -> MotionIntent:
	var copy := MotionIntent.new()
	copy.actor = actor
	copy.mode = mode
	copy.behavior = behavior
	copy.target = target
	copy.destination = destination
	copy.speed = speed
	copy.owner_token = owner_token
	copy.revision = revision
	copy.expires_tick = expires_tick
	copy.resource_cell = resource_cell
	copy.reason = reason
	return copy
