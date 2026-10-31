class_name SimulationCommand
extends RefCounted
## Immutable after enqueue. The executor owns the command and returns its ID
## only at a safe boundary; old-epoch requests receive explicit rejection.
enum Kind { PAUSE, SINGLE_STEP, SPEED, RESET, SPAWN, PLACE, REMOVE, HOLD, DROP, CANCEL_GRAB, TUNING, SELECT, STALL }
var kind: Kind
var request_id: int = 0
var epoch: int = 0
var handle: AgentHandle
var position: Vector2
var integer: int = 0
var scalar: float = 0.0
var scenario: ScenarioConfig
var tuning: TuningCatalog.Change

class Receipt extends RefCounted:
	var request_id: int
	var epoch: int
	var tick: int
	var accepted: bool
	var reason: String
	var submitted_usec: int = 0
	var completed_usec: int = 0

var submitted_usec: int = 0

func owned_copy() -> SimulationCommand:
	var copy := SimulationCommand.new()
	copy.kind = kind
	copy.request_id = request_id
	copy.epoch = epoch
	copy.handle = handle
	copy.position = position
	copy.integer = integer
	copy.scalar = scalar
	copy.submitted_usec = submitted_usec
	copy.scenario = scenario.duplicate(true) as ScenarioConfig if scenario != null else null
	copy.tuning = TuningCatalog.Change.new(tuning.key, tuning.value) if tuning != null else null
	return copy
