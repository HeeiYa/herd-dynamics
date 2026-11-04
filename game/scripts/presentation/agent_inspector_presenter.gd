class_name AgentInspectorPresenter
extends RefCounted
## Formats one selected life from the branch's read interface. The card itself is simulation-free.
var _card: AgentInspector

func _init(card: AgentInspector) -> void:
	_card = card

func refresh(world: SimulationAccess, handle: AgentHandle) -> void:
	var dense: int = world.store.resolve(handle)
	if dense < 0:
		_card._show_empty(true)
		return
	_card._show_empty(false)
	var tick: int = world.tick
	var dt: float = world.config.fixed_dt
	var species: int = world.store.species[dense]
	var held: bool = world.store.held[dense] != 0
	var context: AgentInspection = world.inspect(handle)
	var intent: MotionIntent = world.intents.get_intent(handle, tick)
	_card._title.text = "%s · #%d" % [BehaviorText.species(species), handle.slot + 1]
	_card._hunger.value = world.store.hunger[dense]
	var lines := PackedStringArray()
	if held:
		lines.append("[b]状态[/b]  被提起（暂停自主行为与互动）")
	elif intent != null:
		lines.append("[b]状态[/b]  [color=#%s]%s[/color]" % [UiStyle.ACCENT.to_html(false), BehaviorText.behavior(intent.behavior)])
	else:
		lines.append("[b]状态[/b]  等待决策")
	if context != null:
		var reason_label: String = "原因" if intent != null and not held else "最近判断"
		lines.append("[b]%s[/b]  %s" % [reason_label, _reason_text(context.task_name)])
	if not held and intent != null:
		lines.append("[b]行动目的地[/b]  %s" % _destination_text(world, dense, intent))
		lines.append("[b]AI 目标[/b]  %s" % _target_text(world, context, intent))
	if context != null:
		var perception_age: int = tick - context.last_perception_tick
		var freshness: String = "尚未扫描" if context.last_perception_tick < 0 else _age_text(perception_age, dt)
		lines.append("[b]最近观察[/b]  %s · 记住 %d 条线索" % [freshness, context.observation_count])
		if species == SimTypes.Species.WOLF:
			_append_wolf_cooperation(lines, context, tick, dt, held, world.config.memory_ticks)
		elif species == SimTypes.Species.DOG:
			_append_dog_protection(lines, context, tick, dt, held, intent != null)
	var attack: AttackRequest = context.attack if context != null else null
	if attack != null and species == SimTypes.Species.WOLF:
		lines.append("[b]攻击[/b]  %s" % _attack_text(attack, tick, dt))
	_card._summary.text = "\n".join(lines)
	if _card._details.visible:
		_card._details.text = _details_text(world, handle, context, intent, attack)

func _destination_text(world: SimulationAccess, dense: int, intent: MotionIntent) -> String:
	if intent.mode == SimTypes.IntentMode.STOP:
		return "原地停留"
	if intent.mode == SimTypes.IntentMode.GRAZE:
		return "在当前草地吃草"
	var distance: float = world.store.position_current[dense].distance_to(intent.destination)
	return "约 %d px 外（黄色虚线）" % roundi(distance)

## Explains the AI's own knowledge of the target, never the live position.
func _target_text(world: SimulationAccess, context: AgentInspection, intent: MotionIntent) -> String:
	if intent.target == null:
		return "无"
	if context == null:
		return "等待观察记录"
	var sighting: LocalObservation = context.observation_for(intent.target, world.tick)
	if sighting == null:
		return "已失效（目标消失或记忆过期），等待重新决策"
	return _observation_text(sighting, context.last_perception_tick, world.tick, world.config.fixed_dt, world.config.memory_ticks)

static func _reason_text(task_name: StringName) -> String:
	match task_name:
		&"guard_flock":
			return "守在最近看到的一小群羊附近。"
		&"intercept_wolf":
			return "有狼靠近最近观察到的羊，正在前去拦截。"
		&"return_to_flock":
			return "结束追赶，返回记得的保护位置。"
		&"search_last_flock":
			return "羊离开了视野，正在沿旧线索寻找。"
		&"request_attack":
			return "已经接近猎物，正在尝试扑咬。"
	return BehaviorText.TASK_EXPLANATIONS.get(task_name, "正在判断周围的情况。")

static func _age_text(age_ticks: int, dt: float) -> String:
	return "%.1f 模拟秒前" % (maxi(0, age_ticks) * dt)

static func _observation_text(sighting: LocalObservation, scan_tick: int, tick: int, dt: float, memory_ticks: int) -> String:
	var source: String = "同伴转告"
	if sighting.source == LocalObservation.Source.DIRECT:
		var visible_at_scan: bool = sighting.was_visible_at_scan(scan_tick, tick, memory_ticks)
		source = "亲眼看到" if visible_at_scan else "亲眼见过的旧线索"
	return "%s #%d · %s，%s（记录的位置）" % [BehaviorText.species(sighting.species), sighting.handle.slot + 1, source, _age_text(tick - sighting.observed_tick, dt)]

static func _hunt_role_text(role: int) -> String:
	match role:
		CoordinationSystem.Role.MAIN:
			return "主追"
		CoordinationSystem.Role.LEFT:
			return "左侧包抄"
		CoordinationSystem.Role.RIGHT:
			return "右侧包抄"
	return "分工未知"

static func _append_wolf_cooperation(lines: PackedStringArray, context: AgentInspection, tick: int, dt: float, held: bool, memory_ticks: int) -> void:
	if held:
		lines.append("[b]协作分工[/b]  被提起，暂停协作")
		return
	var lease: CoordinationSystem.Lease = context.lease
	if lease == null or lease.kind != CoordinationSystem.Kind.HUNT:
		lines.append("[b]协作分工[/b]  尚无有效分工")
		return
	if tick >= lease.expires_tick:
		lines.append("[b]协作分工[/b]  分工已到期，等待重新判断")
		return
	lines.append("[b]协作分工[/b]  %s · 剩余 %.1f 模拟秒" % [_hunt_role_text(lease.role), (lease.expires_tick - tick) * dt])
	var sighting: LocalObservation = context.lease_observation_for(lease.target, tick)
	var target_text: String = "目标 #%d · 暂无有效观察" % (lease.target.slot + 1)
	if sighting != null:
		target_text = _observation_text(sighting, context.last_perception_tick, tick, dt, memory_ticks)
	lines.append("[b]协作目标[/b]  %s" % target_text)

static func _has_flock_evidence(context: AgentInspection, tick: int) -> bool:
	return context.flock_observed_tick >= 0 and tick < context.flock_expires_tick and context.flock_evidence_count > 0

static func _append_dog_protection(lines: PackedStringArray, context: AgentInspection, tick: int, dt: float, held: bool, has_intent: bool) -> void:
	if _has_flock_evidence(context, tick):
		var source: String = "亲眼看到的局部样本" if context.flock_is_direct_sample else "局部记忆汇总"
		lines.append("[b]局部保护[/b]  最近记录的 %d 只羊 · %s" % [context.flock_evidence_count, source])
		if context.flock_is_direct_sample:
			lines.append("[b]羊的线索[/b]  %s；局部观察，不是固定羊群" % _age_text(tick - context.flock_observed_tick, dt))
		else:
			lines.append("[b]羊的线索[/b]  按各条记忆的有效期汇总，不是固定羊群")
		return
	if context.flock_observed_tick < 0:
		lines.append("[b]局部保护[/b]  尚未观察到可守护的羊")
	elif tick >= context.flock_expires_tick:
		lines.append("[b]局部保护[/b]  暂无有效样本（上次记录已过期）")
	else:
		lines.append("[b]局部保护[/b]  最近扫描没有发现羊")
	if context.last_flock_seen_tick < 0:
		return
	lines.append("[b]历史线索[/b]  %s记录的保护区域" % _age_text(tick - context.last_flock_seen_tick, dt))
	lines.append("[b]寻找进度[/b]  %s" % _dog_search_text(context, tick, dt, held, has_intent))

static func _dog_search_text(context: AgentInspection, tick: int, dt: float, held: bool, has_intent: bool) -> String:
	if held:
		return "被提起，暂不执行寻找"
	if context.task_name == &"search_last_flock":
		if tick >= context.flock_search_deadline_tick:
			return "本轮寻找已到期，等待下一次判断"
		var phase: String
		match context.flock_search_phase:
			AgentContext.FlockSearchPhase.TO_ANCHOR:
				phase = "返回最后记录的位置"
			AgentContext.FlockSearchPhase.LOCAL_SWEEP:
				phase = "在旧位置附近寻找"
			AgentContext.FlockSearchPhase.FINISHED:
				return "这一轮寻找已经结束"
			_:
				push_error("Unknown flock search phase in inspection")
				return "寻找状态异常"
		var progress: String = "%s · 剩余 %.1f 模拟秒" % [phase, (context.flock_search_deadline_tick - tick) * dt]
		return progress if has_intent else "最近阶段：%s（等待新意图）" % progress
	if context.flock_search_observed_tick >= 0 and context.last_flock_searched_tick >= context.last_flock_seen_tick:
		return "旧线索已查找完，继续探索"
	return "保留历史线索，等待继续寻找"

static func _attack_text(attack: AttackRequest, tick: int, dt: float) -> String:
	var status: String = ["蓄力", "扑咬判定中", "已捕获", "未命中", "已取消"][attack.status]
	if tick < attack.cooldown_until_tick:
		status += " · 冷却 %.1f 秒" % ((attack.cooldown_until_tick - tick) * dt)
	return status

func _details_text(world: SimulationAccess, handle: AgentHandle, context: AgentInspection, intent: MotionIntent, attack: AttackRequest) -> String:
	var tick: int = world.tick
	var lines := PackedStringArray()
	lines.append("[b]完整身份[/b]  %s" % handle.key())
	if intent != null:
		lines.append("[b]运动意图[/b]")
		lines.append("模式  %s / %s" % [SimTypes.IntentMode.keys()[intent.mode], SimTypes.behavior_name(intent.behavior)])
		lines.append("标识  %d    剩余  %d tick" % [intent.owner_token, intent.expires_tick - tick])
		lines.append("原因  %s" % intent.reason)
	if context != null:
		lines.append("\n[b]行为与协作[/b]")
		lines.append("任务  %s" % context.task_name)
		var lease: CoordinationSystem.Lease = context.lease
		if lease != null:
			var role: String = BehaviorText.LEASE_ROLES[lease.role] if lease.kind == CoordinationSystem.Kind.HUNT else "防守"
			lines.append("协作 %s · 目标 %s · 至 %d" % [role, lease.target.key(), lease.expires_tick])
		lines.append("羊群样本 %d · 锚点 (%d, %d)" % [context.flock_count, roundi(context.protection_anchor.x), roundi(context.protection_anchor.y)])
		lines.append("\n[b]调度 · 当前 %d tick[/b]" % tick)
		lines.append("下次感知  %d    下次决策  %d" % [context.next_perception_tick, context.next_decision_tick])
		lines.append("排队  感知 %s · 决策 %s · 紧急 %s" % ["是" if context.perception_queued else "否", "是" if context.decision_queued else "否", "是" if context.urgent_queued else "否"])
	if attack != null:
		lines.append("\n[b]攻击窗口[/b]")
		lines.append("%s · 有效 %d–%d tick" % [AttackRequest.Status.keys()[attack.status], attack.active_start_tick, attack.active_end_tick])
	return "\n".join(lines)
