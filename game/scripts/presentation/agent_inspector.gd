class_name AgentInspector
extends VBoxContainer
## Read-only character card: a plain-language summary first, details on demand.
## Reads intents, the AI context (via AICoordinator.inspect) and attack records;
## it never writes simulation state.

signal follow_requested
signal remove_requested

var _title: Label
var _summary: RichTextLabel
var _hunger: ProgressBar
var _hunger_row: HBoxContainer
var _details_toggle: Button
var _details: Label
var _actions: HBoxContainer
var _empty: Label

func _init() -> void:
	add_theme_constant_override("separation", 8)
	_empty = Label.new()
	_empty.text = "点击牧场中的角色查看它在做什么、为什么这样做。\n\n快捷键：F 跟随 · Home 总览 · Esc 取消"
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.modulate = UiStyle.INK_SOFT
	add_child(_empty)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	add_child(_title)
	_summary = RichTextLabel.new()
	_summary.bbcode_enabled = true
	_summary.fit_content = true
	_summary.scroll_active = false
	_summary.add_theme_color_override("default_color", UiStyle.INK)
	add_child(_summary)
	_hunger_row = HBoxContainer.new()
	var hunger_label := Label.new()
	hunger_label.text = "饥饿"
	_hunger_row.add_child(hunger_label)
	_hunger = ProgressBar.new()
	_hunger.max_value = 1.0
	_hunger.step = 0.01
	_hunger.show_percentage = false
	_hunger.custom_minimum_size = Vector2(0, 12)
	_hunger.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hunger.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill := StyleBoxFlat.new()
	fill.bg_color = UiStyle.ACCENT
	fill.set_corner_radius_all(4)
	var back := StyleBoxFlat.new()
	back.bg_color = UiStyle.PAPER_DEEP
	back.set_corner_radius_all(4)
	_hunger.add_theme_stylebox_override("fill", fill)
	_hunger.add_theme_stylebox_override("background", back)
	_hunger_row.add_child(_hunger)
	add_child(_hunger_row)
	_actions = HBoxContainer.new()
	_actions.add_child(_button("跟随 (F)", func() -> void: follow_requested.emit()))
	_actions.add_child(_button("移除角色", func() -> void: remove_requested.emit()))
	add_child(_actions)
	_details_toggle = _button("详细调试 ▸", _toggle_details)
	_details_toggle.toggle_mode = true
	add_child(_details_toggle)
	_details = Label.new()
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.add_theme_font_size_override("font_size", 12)
	_details.modulate = UiStyle.INK_SOFT
	_details.visible = false
	add_child(_details)
	_show_empty(true)

func _button(caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	return button

func _toggle_details() -> void:
	_details.visible = _details_toggle.button_pressed
	_details_toggle.text = "详细调试 ▾" if _details.visible else "详细调试 ▸"

func _show_empty(empty: bool) -> void:
	_empty.visible = empty
	for node: Control in [_title, _summary, _hunger_row, _actions, _details_toggle]:
		node.visible = not empty
	_details.visible = not empty and _details_toggle.button_pressed

func refresh(world: SimulationWorld, handle: AgentHandle) -> void:
	var dense: int = world.store.resolve(handle)
	if dense < 0:
		_show_empty(true)
		return
	_show_empty(false)
	var tick: int = world.tick
	var dt: float = world.config.fixed_dt
	var species: int = world.store.species[dense]
	var held: bool = world.store.held[dense] != 0
	var context: AgentContext = world.ai.inspect(handle)
	var intent: MotionIntent = world.intents.get_intent(handle, tick)
	_title.text = "%s · %s" % [BehaviorText.species(species), handle.key()]
	_hunger.value = world.store.hunger[dense]
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
		lines.append("[b]信息新鲜度[/b]  上次扫描 %s · 记忆 %d 条" % [freshness, context.observations.size()])
	var attack: AttackRequest = world.interaction.get_attack(handle)
	if attack != null and species == SimTypes.Species.WOLF:
		lines.append("[b]攻击[/b]  %s" % _attack_text(attack, tick, dt))
	_summary.text = "\n".join(lines)
	if _details.visible:
		_details.text = _details_text(world, handle, context, intent, attack)

func _destination_text(world: SimulationWorld, dense: int, intent: MotionIntent) -> String:
	if intent.mode == SimTypes.IntentMode.STOP:
		return "原地停留"
	if intent.mode == SimTypes.IntentMode.GRAZE:
		return "在当前草地吃草"
	var distance: float = world.store.position_current[dense].distance_to(intent.destination)
	return "约 %d px 外（黄色虚线）" % roundi(distance)

## Explains the AI's own knowledge of the target, never the live position.
func _target_text(world: SimulationWorld, context: AgentContext, intent: MotionIntent) -> String:
	if intent.target == null:
		return "无"
	var store_dense: int = world.store.resolve(intent.target)
	var species_text: String = "角色"
	if context == null:
		return species_text
	var sighting: LocalObservation = context.observation_for(intent.target)
	if sighting == null:
		return "已失效（目标消失或记忆过期），等待重新决策"
	species_text = BehaviorText.species(sighting.species)
	var age: int = world.tick - sighting.observed_tick
	var source: String = "亲眼看到" if sighting.source == LocalObservation.Source.DIRECT else "同伴转告"
	var line_style: String = "实线" if sighting.source == LocalObservation.Source.DIRECT else "虚线"
	if store_dense < 0:
		return "%s · %s %s（%s）" % [species_text, source, BehaviorText.age_text(age, world.config.fixed_dt), line_style]
	return "%s %s · %s %s（%s，终点为记忆位置）" % [species_text, intent.target.key(), source, BehaviorText.age_text(age, world.config.fixed_dt), line_style]

static func _attack_text(attack: AttackRequest, tick: int, dt: float) -> String:
	var status: String = ["蓄力", "扑咬判定中", "已捕获", "未命中", "已取消"][attack.status]
	if tick < attack.cooldown_until_tick:
		status += " · 冷却 %.1f 秒" % ((attack.cooldown_until_tick - tick) * dt)
	return status

func _details_text(world: SimulationWorld, handle: AgentHandle, context: AgentContext, intent: MotionIntent, attack: AttackRequest) -> String:
	var tick: int = world.tick
	var lines := PackedStringArray()
	if intent != null:
		lines.append("意图 %s / %s · token %d · 剩余 %d tick" % [SimTypes.IntentMode.keys()[intent.mode], SimTypes.behavior_name(intent.behavior), intent.owner_token, intent.expires_tick - tick])
		lines.append("reason: %s" % intent.reason)
	if context != null:
		lines.append("任务 %s" % context.task_name)
		var lease: CoordinationSystem.Lease = world.ai.coordination.get_lease(handle, tick)
		if lease != null:
			var role: String = BehaviorText.LEASE_ROLES[lease.role] if lease.kind == CoordinationSystem.Kind.HUNT else "防守"
			lines.append("协作 %s · 目标 %s · 至 %d" % [role, lease.target.key(), lease.expires_tick])
		lines.append("下次感知 %d · 下次决策 %d（当前 %d）" % [context.next_perception_tick, context.next_decision_tick, tick])
		lines.append("排队 感知 %s · 决策 %s · 紧急 %s" % [context.perception_queued, context.decision_queued, context.urgent_queued])
		lines.append("羊群样本 %d · 锚点 (%d, %d)" % [context.flock_count, roundi(context.protection_anchor.x), roundi(context.protection_anchor.y)])
	if attack != null:
		lines.append("攻击 %s · 有效 %d–%d" % [AttackRequest.Status.keys()[attack.status], attack.active_start_tick, attack.active_end_tick])
	return "\n".join(lines)
