class_name AttackRequest
extends RefCounted
## One accepted attack per actor life. The newest token also acts as a replay watermark.
enum Status { WINDUP, ACTIVE, CAPTURED, MISSED, CANCELLED }
var actor: AgentHandle
var target: AgentHandle
var owner_token: int
var accepted_tick: int
var active_start_tick: int
var active_end_tick: int
var cooldown_until_tick: int
var status: Status = Status.WINDUP
var contact_fraction: float = -1.0

func is_pending() -> bool:
	return status == Status.WINDUP or status == Status.ACTIVE
