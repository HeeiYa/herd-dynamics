class_name BehaviorText
extends RefCounted
## Chinese labels for the observer. Keys are the enum values and the BT leaf
## identifiers recorded by ContextAction; English reasons stay in details.

const BEHAVIOR_NAMES: Dictionary[int, String] = {
	SimTypes.Behavior.IDLE: "休息",
	SimTypes.Behavior.GRAZE: "吃草",
	SimTypes.Behavior.FLEE: "逃跑",
	SimTypes.Behavior.REGROUP: "归群",
	SimTypes.Behavior.SEARCH: "搜索",
	SimTypes.Behavior.STALK: "潜近",
	SimTypes.Behavior.CHASE: "追击",
	SimTypes.Behavior.FLANK: "包抄",
	SimTypes.Behavior.ATTACK: "扑咬",
	SimTypes.Behavior.FEED: "进食",
	SimTypes.Behavior.RETREAT: "撤退",
	SimTypes.Behavior.GUARD: "守护",
	SimTypes.Behavior.INTERCEPT: "拦截",
	SimTypes.Behavior.RETURN: "回防",
}

const TASK_EXPLANATIONS: Dictionary[StringName, String] = {
	&"flee_threat": "看到附近有威胁，正在选择能远离所有已知威胁的方向。",
	&"graze_grass": "饿了，前往附近草量较多的地块吃草。",
	&"regroup_flock": "离羊群太远，正向它记得的同伴位置靠拢。",
	&"rest_satiated": "已经吃饱，原地休息，直到饿了或出现更重要的事。",
	&"search_area": "附近没有需要处理的目标，沿较长路线探索没去过的区域。",
	&"hunt_prey": "看到了羊，正在申请狩猎分工并追向它的预测位置。",
	&"request_attack": "猎物进入扑咬距离，攻击请求交给交互结算。",
	&"feed_capture": "刚捕获猎物，停下进食。",
	&"search_memory": "猎物离开视线，按记忆中的位置分段搜索。",
	&"guard_flock": "在自己守护的羊群附近巡视。",
	&"intercept_wolf": "有狼靠近守护的羊群，前去拦截并施压。",
	&"return_to_flock": "追击超时或离羊群太远，返回羊群。",
	&"search_last_flock": "看不见羊群，前往最后看到它的位置。",
	&"Waiting for first perception": "刚加入或刚被放下，等待第一次感知扫描。",
	&"Held by observer": "被观察者提起，暂停自主行为与互动。",
}

const LEASE_ROLES: Array[String] = ["主攻", "左翼", "右翼"]

static func behavior(value: int) -> String:
	return BEHAVIOR_NAMES.get(value, SimTypes.behavior_name(value))

static func explain(task_name: StringName) -> String:
	return TASK_EXPLANATIONS.get(task_name, "正在执行 %s。" % task_name)

static func species(value: int) -> String:
	return SimTypes.species_name(value)

## Seconds since an observation, for freshness labels.
static func age_text(age_ticks: int, fixed_dt: float) -> String:
	return "%.1f 秒前" % (maxf(0.0, age_ticks) * fixed_dt)
