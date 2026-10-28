class_name SimTypes
extends RefCounted

enum Species { SHEEP, WOLF, DOG }
enum Behavior { IDLE, GRAZE, FLEE, REGROUP, SEARCH, STALK, CHASE, FLANK, ATTACK, FEED, RETREAT, GUARD, INTERCEPT, RETURN }
enum IntentMode { STOP, MOVE, FLEE, GRAZE, ATTACK, PRESSURE }

static func species_name(value: int) -> String:
	return ["羊", "狼", "牧羊犬"][value]

static func behavior_name(value: int) -> String:
	return Behavior.keys()[value]
