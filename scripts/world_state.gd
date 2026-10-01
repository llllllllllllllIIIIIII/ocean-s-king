class_name WorldState
extends RefCounted

# 「所有人共用的状态」这块边界的名字（docs/14 第 2 节）。
#
# M1 阶段它主要是一个**容器 + 契约**：字段清单在 FIELDS 里写死一份，
# 实际内容由 `Voyage.capture_world_state()` 产出、由 `apply_world_state()` 吃回去；
# 各子对象的字段由它们自己的 `capture_state()` 负责（Story / VoyageJournal / WindField）。
#
# M3 会在这个类上加逐字段 diff（房主只广播变了的字段），所以先把边界立在这里。

const FIELDS := [
	"t", "day", "wind", "fired", "island_known", "visited", "reef_hit",
	"last_message", "message_timer", "log_lines", "pending_reports",
	"_shore_cooldown", "story", "journal",
]

var data := {}


func capture(v: Voyage) -> void:
	data = v.capture_world_state()


func apply(v: Voyage) -> void:
	v.apply_world_state(data)


func to_dict() -> Dictionary:
	return data


func from_dict(d: Dictionary) -> void:
	data = d.duplicate(true)


func field(name: String, default_value = null):
	"""给 M3 的增量广播用：按名字取一块状态。"""
	return data.get(name, default_value)
