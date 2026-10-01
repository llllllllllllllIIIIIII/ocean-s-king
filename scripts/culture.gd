class_name Culture
extends RefCounted

# 当地文明（M6）：三档态度 + 态度怎么被玩家的行为改。
#
# docs/13 第 11 节把"势力外交全系统"划到了 v0.6+，这一期只做**最小可用的那一层**：
#   · 每个地方群体有一个态度值（−1 敌意 … +1 友善）与三档标签；
#   · 玩家的行为（贸易、开火、绑架、还人情）改这个值；
#   · 态度决定"上岸会不会打起来"，也决定港口收不收你的货（M7 的事件池会接着用）。
#
# 它是**世界的一部分**（同一个地方对所有船的态度是一样的）—— 但 v0.5 只有一艘
# 玩家的船会到处跑，所以先放在本船的字典里，M7 挪进 WorldState 时只要换个容器。

const FRIENDLY := "friendly"
const NEUTRAL := "neutral"
const HOSTILE := "hostile"

var groups: Dictionary = {}          # 地点 id -> {name, attitude, met}


func setup() -> void:
	groups = {
		"green_cape": {"name": "绿岬岛上的部落", "attitude": 0.0, "met": false},
	}


func ensure(id: String, name := "") -> Dictionary:
	if not groups.has(id):
		groups[id] = {"name": name if name != "" else id, "attitude": 0.0, "met": false}
	return groups[id]


func attitude(id: String) -> float:
	return float(ensure(id).get("attitude", 0.0))


func stance(id: String) -> String:
	var a := attitude(id)
	if a >= 0.35:
		return FRIENDLY
	if a <= -0.35:
		return HOSTILE
	return NEUTRAL


func stance_name(id: String) -> String:
	match stance(id):
		FRIENDLY: return "友善"
		HOSTILE: return "敌对"
	return "中立"


func shift(id: String, delta: float, reason := "") -> Dictionary:
	var g := ensure(id)
	var before := float(g["attitude"])
	g["attitude"] = clampf(before + delta, -1.0, 1.0)
	g["met"] = true
	return {"id": id, "before": before, "after": float(g["attitude"]),
		"stance": stance(id), "reason": reason}


func met(id: String) -> bool:
	return bool(ensure(id).get("met", false))


func describe(id: String) -> String:
	return "%s：%s（%+.2f）" % [str(ensure(id).get("name", id)), stance_name(id), attitude(id)]


# ------------------------------------------------------------ 行为 → 态度
# 一张表，和别的真源一样：数值只有这一处。M7 的事件池会直接读它。

const REACTIONS := {
	"trade": 0.30,
	"gift": 0.20,
	"leave_alone": 0.05,
	"fire": -0.60,
	"kidnap": -0.80,
	"kill": -0.90,
	"trespass": -0.10,
}


func react(id: String, action: String, reason := "") -> Dictionary:
	return shift(id, float(REACTIONS.get(action, 0.0)), reason if reason != "" else action)


func will_fight(id: String) -> bool:
	"""上岸会不会打起来：只有**敌对**才会主动上来。中立会看着你。"""
	return stance(id) == HOSTILE


# ------------------------------------------------------------ 存档（ShipState；M7 挪进 WorldState）

func capture_state() -> Dictionary:
	return {"groups": groups.duplicate(true)}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	groups = (d.get("groups", {}) as Dictionary).duplicate(true)
