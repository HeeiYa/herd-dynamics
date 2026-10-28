class_name CaptureEvent
extends RefCounted
## Immutable-by-convention display/result record; neither handle is a dense index.
var actor: AgentHandle
var target: AgentHandle
var position: Vector2
var facing: Vector2
var tick: int
