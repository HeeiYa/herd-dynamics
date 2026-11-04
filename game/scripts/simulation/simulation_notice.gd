class_name SimulationNotice
extends RefCounted
## An ordered fact, independent of replaceable display snapshots.
enum Kind { RECEIPT, OBSERVER, CAPTURE, BEHAVIOR }
var kind: Kind
var receipt: SimulationCommand.Receipt
var observer: Dictionary
var capture: CaptureEvent
var pose: PublishedPose
var previous_behavior: int = SimTypes.Behavior.IDLE
var held: bool = false
var tick: int
var position: Vector2
