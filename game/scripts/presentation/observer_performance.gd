class_name ObserverPerformance
extends RefCounted
## Read-only, low-frequency performance presentation. A rate window never spans
## a reset, pause, single-step or requested-speed transition.
const POLL_USEC: int = 1000000
const WINDOW_USEC: int = 2000000
const REALTIME_TOLERANCE: float = 0.98
const DISPLAY_WARNING_MSEC: float = 100.0
const FRAME_WARNING_MSEC: float = 1000.0 / 60.0
const BACKPRESSURE_WARNING_FRACTION: float = 0.01
const MISSING_INTENT_WARNING_FRACTION: float = 0.001
var actual_speed: float = -1.0
var target_speed: float = 1.0
var paused: bool = false
var backpressure_fraction: float = 0.0
var source_age_msec: float = -1.0
var _last_poll_usec: int = 0
var _window_usec: int = 0
var _window_steps: int = 0
var _window_wait_usec: int = 0
var _epoch: int = -1
var _observed_display_epoch: int = -1
var _window_paused: bool = false
var _window_speed: float = 1.0

func refresh(access: SimulationAccess, runner: SimulationRunner, now_usec: int) -> void:
	paused = runner.paused
	target_speed = runner.speed
	var transition: bool = paused != _window_paused or not is_equal_approx(target_speed, _window_speed) or access.store.epoch != _observed_display_epoch
	if not transition and now_usec - _last_poll_usec < POLL_USEC:
		return
	_last_poll_usec = now_usec
	_observed_display_epoch = access.store.epoch
	if access.executor != null:
		var counters: Dictionary = access.executor.diagnostic_counters()
		var completed_usec: int = int(counters["completed_publication_usec"])
		if completed_usec == 0:
			return
		source_age_msec = maxf(0.0, float(now_usec - completed_usec) / 1000.0)
		observe(int(counters["epoch"]), int(counters["steps"]), int(counters["read_usec"]), paused, target_speed, access.config.fixed_dt, int(counters["backpressure_wait_usec"]))
	else:
		source_age_msec = 0.0
		observe(access.store.epoch, access.tick, now_usec, paused, target_speed, access.config.fixed_dt, 0)

## Units: wall microseconds, completed fixed steps and simulated seconds/step.
## Worker counters include completed publication; they do not use display tick.
func observe(epoch: int, completed_steps: int, now_usec: int, is_paused: bool, requested_speed: float, fixed_dt: float, wait_usec: int) -> void:
	paused = is_paused
	target_speed = requested_speed
	var changed: bool = epoch != _epoch or is_paused != _window_paused or not is_equal_approx(requested_speed, _window_speed) or completed_steps < _window_steps
	if changed or _window_usec == 0 or is_paused:
		_epoch = epoch
		_window_paused = is_paused
		_window_speed = requested_speed
		_restart_window(completed_steps, now_usec, wait_usec)
		actual_speed = -1.0
		backpressure_fraction = 0.0
		return
	var elapsed_usec: int = now_usec - _window_usec
	if elapsed_usec < WINDOW_USEC:
		return
	actual_speed = float(completed_steps - _window_steps) * fixed_dt * 1000000.0 / elapsed_usec
	backpressure_fraction = clampf(float(wait_usec - _window_wait_usec) / elapsed_usec, 0.0, 1.0)
	_restart_window(completed_steps, now_usec, wait_usec)

func _restart_window(steps: int, now_usec: int, wait_usec: int) -> void:
	_window_steps = steps
	_window_usec = now_usec
	_window_wait_usec = wait_usec

func rate_text() -> String:
	if paused:
		return "模拟 已暂停 / 单步"
	if actual_speed < 0.0:
		return "模拟 采样中 / 目标 %.2f×" % target_speed
	return "模拟 %.2f× / 目标 %.2f×" % [actual_speed, target_speed]

func status_text(display_age_msec: float, frame_p95_msec: float, missing_intent_fraction: float = -1.0) -> String:
	if paused:
		return "暂停观察 · 不判过载"
	var causes: PackedStringArray = _load_causes(display_age_msec, frame_p95_msec, missing_intent_fraction)
	if causes.is_empty():
		return "正在采样" if actual_speed < 0.0 else "当前节奏正常"
	return "负载提示 · " + " / ".join(causes)

func has_load_warning(display_age_msec: float, frame_p95_msec: float, missing_intent_fraction: float = -1.0) -> bool:
	return not paused and not _load_causes(display_age_msec, frame_p95_msec, missing_intent_fraction).is_empty()

func _load_causes(display_age_msec: float, frame_p95_msec: float, missing_intent_fraction: float) -> PackedStringArray:
	var causes := PackedStringArray()
	if actual_speed >= 0.0 and actual_speed < target_speed * REALTIME_TOLERANCE:
		causes.append("模拟欠速")
	if backpressure_fraction > BACKPRESSURE_WARNING_FRACTION:
		causes.append("可靠交付等待")
	if display_age_msec > DISPLAY_WARNING_MSEC:
		causes.append("显示滞后")
	if frame_p95_msec > FRAME_WARNING_MSEC:
		causes.append("前端帧慢")
	if missing_intent_fraction > MISSING_INTENT_WARNING_FRACTION:
		causes.append("意图欠服务")
	return causes

static func selected_decision_text(access: SimulationAccess, selected: AgentHandle) -> String:
	if selected == null:
		return "所选决策：选中角色查看"
	if not access.store.is_alive(selected):
		return "所选决策：角色已离开"
	if access.store.is_held(selected):
		return "所选决策：提起期间暂停"
	var inspection: AgentInspection = access.inspect(selected)
	if inspection == null:
		return "所选决策：等待观察数据"
	# last_decision_tick starts at birth for BT elapsed-time accounting. Until
	# a leaf has produced an action, that initializer is not a serviced decision.
	if inspection.task_name in [&"Uninitialized", &"Waiting for first perception"]:
		return "所选决策：等待首次 / 恢复感知"
	var age_msec: float = maxi(0, access.tick - inspection.last_decision_tick) * access.config.fixed_dt * 1000.0
	var queued: String = " · 排队中" if inspection.decision_queued or inspection.urgent_queued else ""
	return "所选决策：距上次 %.0f ms（模拟时间）%s" % [age_msec, queued]

static func intent_text(access: SimulationAccess) -> String:
	if access.executor == null:
		return "全群意图：inline 未采样"
	var metrics: SimulationTelemetry = access.control_status
	if metrics == null or metrics.epoch != access.store.epoch:
		return "全群意图：等待新场景数据"
	if metrics.active_agents == 0:
		return "全群意图：无参与者"
	return "缺失意图 %d / %d（%.2f%%）" % [metrics.missing_intents, metrics.active_agents, 100.0 * metrics.missing_intents / metrics.active_agents]

static func missing_intent_fraction(access: SimulationAccess) -> float:
	var metrics: SimulationTelemetry = access.control_status
	if access.executor == null or metrics == null or metrics.epoch != access.store.epoch or metrics.active_agents == 0:
		return -1.0
	return float(metrics.missing_intents) / metrics.active_agents
