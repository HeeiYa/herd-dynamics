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
	_card._title.text = "%s · %s" % [BehaviorText.species(species), handle.key()]
	_card._hunger.value = world.store.hunger[dense]
	var lines := PackedStringArray()
	if held:
		lines.append("[b]状态[/b]  被提起（暂停自主行为与互动）")
	elif intent != null:
		lines.append("[b]状态[/b]  [color=#%s]%s[/color]" % [UiStyle.ACCENT.to_html(false), BehaviorText.behavior(intent.behavior)])
	else:
		lines.append("[b]状态[/b]  等待决策")
	if context != null:
		lines.append("[b]原因[/b]  %s" % BehaviorText.explain(context.task_name))
	if not held and intent != null:
		lines.append("[b]行动目的地[/b]  %s" % _destination_text(world, dense, intent))
		lines.append("[b]AI 目标[/b]  %s" % _target_text(world, context, intent))
	if context != null:
		var perception_age: int = tick - context.last_perception_tick
		var freshness: String = "尚未感知" if context.last_perception_tick < 0 else BehaviorText.age_text(perception_age, dt)
		lines.append("[b]信息新鲜度[/b]  上次扫描 %s · 记忆 %d 条" % [freshness, context.observation_count])
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
	var store_dense: int = world.store.resolve(intent.target)
	var species_text: String = "角色"
	if context == null:
		return species_text
	var sighting: LocalObservation = context.observation_for(intent.target, world.tick)
	if sighting == null:
		return "已失效（目标消失或记忆过期），等待重新决策"
	species_text = BehaviorText.species(sighting.species)
	var age: int = world.tick - sighting.observed_tick
	var source: String = "同伴转告"
	var line_style: String = "短虚线"
	if sighting.source == LocalObservation.Source.DIRECT:
		var visible_at_scan: bool = sighting.was_visible_at_scan(context.last_perception_tick, world.tick, world.config.memory_ticks)
		source = "最近扫描看到" if visible_at_scan else "记忆（亲眼见过）"
		line_style = "实线" if visible_at_scan else "长虚线"
	if store_dense < 0:
		return "%s · %s %s（%s）" % [species_text, source, BehaviorText.age_text(age, world.config.fixed_dt), line_style]
	return "%s %s · %s %s（%s，终点为记忆位置）" % [species_text, intent.target.key(), source, BehaviorText.age_text(age, world.config.fixed_dt), line_style]

static func _attack_text(attack: AttackRequest, tick: int, dt: float) -> String:
	var status: String = ["蓄力", "扑咬判定中", "已捕获", "未命中", "已取消"][attack.status]
	if tick < attack.cooldown_until_tick:
		status += " · 冷却 %.1f 秒" % ((attack.cooldown_until_tick - tick) * dt)
	return status

func _details_text(world: SimulationAccess, handle: AgentHandle, context: AgentInspection, intent: MotionIntent, attack: AttackRequest) -> String:
	var tick: int = world.tick
	var lines := PackedStringArray()
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
