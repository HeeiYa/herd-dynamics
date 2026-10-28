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
