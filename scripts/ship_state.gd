class_name ShipState
extends RefCounted

# 「某一条船的状态」这块边界的名字（docs/14 第 3 节）。
#
# 和 WorldState 一样：M1 阶段是容器 + 契约，内容由
# `Voyage.capture_ship_state()` / `apply_ship_state()` 产出与消费。
#
# 每条船的拥有者才是这份状态的唯一写入者（M3 起：客户端不接受别人对我这艘船的写入）。
# 抽象船（AI / 掉线的）只有 hull_pct / crew_count / cargo_summary / action 这几个字段 ——
# 那是 M3 的事，M1 先只放"细化船"的字段。

const FIELDS := [
	"id", "kind", "ship_name", "ship", "orders", "nav", "crew", "roster",
	"ashore", "captain_pos", "captain_target", "ashore_count", "landing_point",
	"landing_land_id", "party", "cargo", "docked_port",
]

var data := {}


func capture(v: Voyage) -> void:
	data = v.capture_ship_state()


func apply(v: Voyage) -> void:
	v.apply_ship_state(data)


func to_dict() -> Dictionary:
	return data


func from_dict(d: Dictionary) -> void:
	data = d.duplicate(true)


func field(name: String, default_value = null):
	return data.get(name, default_value)


func ship_id() -> String:
	return str(data.get("id", ""))


func is_detailed() -> bool:
	return str(data.get("kind", "")) == "detailed"
