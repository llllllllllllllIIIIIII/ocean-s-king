class_name Expedition
extends RefCounted

# 探索产出（M18）：沉船 / 海底遗迹 / 宝藏 / 新物种 / 新资源 / 未知民族。
#
# 三条设计：
#   1. **数值与文案只有一份真源**（`data/defs/expedition.json`），GDScript 只读它；
#   2. **可复现**：同一个地点只出一次，出哪一条由 (地点 id 的哈希) 决定 ——
#      候选按 id 排好序再取模，不用随机数（无头可测、联机可复现）；
#   3. **每条都落到看得见的地方**：知识一条（`Knowledge`）、捞到的东西（货舱/金币）、
#      五类结算的分数、以及"未知民族"要和 M11 的势力表对一次账。

const DATA_PATH := "res://data/defs/expedition.json"

static var _cache: Dictionary = {}


static func defs() -> Dictionary:
	if _cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_cache = d
		else:
			push_error("探索产出表读不出来：" + DATA_PATH)
	return _cache


static func kinds() -> Array:
	return defs().get("kinds", [])


static func kind_def(id: String) -> Dictionary:
	for k in kinds():
		if str((k as Dictionary).get("id", "")) == id:
			return k
	return {}


static func kind_name(id: String) -> String:
	return str(kind_def(id).get("name", id))


static func finds() -> Array:
	return defs().get("finds", [])


static func find_of(id: String) -> Dictionary:
	for f in finds():
		if str((f as Dictionary).get("id", "")) == id:
			return f
	return {}


static func finds_of_kind(kind: String) -> Array:
	var out := []
	for f in finds():
		if str((f as Dictionary).get("kind", "")) == kind:
			out.append(f)
	out.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	return out


static func pick(place_id: String, kind: String) -> Dictionary:
	"""这个地点出哪一样（**可复现**：地点 id 的哈希取模，候选先按 id 排序）。"""
	var pool := finds_of_kind(kind)
	if pool.is_empty():
		return {}
	var h := absi((place_id + "|" + kind).hash())
	return pool[h % pool.size()]


static func kind_for_where(where: String, seed_text := "") -> String:
	"""某个场合（礁石 / 上岸）该出哪一类：礁石 = 沉船；岛上按 seed 在其余五类里挑。"""
	if where == "reef":
		return "wreck"
	var island_kinds := ["ruins", "treasure", "species", "resource", "people"]
	if seed_text == "":
		return island_kinds[0]
	return str(island_kinds[absi(seed_text.hash()) % island_kinds.size()])
