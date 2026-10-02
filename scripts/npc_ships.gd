class_name NpcShips
extends RefCounted

# 抽象 NPC 船（M11）：商人 / 海盗 / 其他航海者。
#
# 三条设计（docs/22 第 8、11 章 / docs/23 的 M11 卡片）：
#   1. **它们不是逐人模拟的船**：只有一条巡逻线 + 一个摘要。由**房主**推进
#      （它是世界状态的一部分，和 AI 船、港口价格同类）。
#   2. **海盗是海战的来源**：玩家的船靠近到 `encounter_range_m` 之内，
#      它就会咬上来（`Voyage._npc_contact_tick` 起那场 `NavalBattle`）——
#      M10 留下的"被截击"由此成立。
#   3. **巡逻线按世界比例写**：同一份数据在 8km 的迷你海域与 320km 的全球图上都成立。

const DEFS_PATH := "res://data/defs/npcs.json"

static var _defs_cache: Dictionary = {}


static func defs() -> Dictionary:
	if _defs_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DEFS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_defs_cache = d
		else:
			push_error("NPC 船表读不出来：" + DEFS_PATH)
	return _defs_cache


static func encounter_range_m() -> float:
	return float(defs().get("encounter_range_m", 1500.0))


static func cooldown_s() -> float:
	return float(defs().get("encounter_cooldown_s", 1800.0))


# ------------------------------------------------------------ 实例状态（世界状态）

var ships: Array = []


func setup(sea: Sea) -> void:
	ships.clear()
	var list := ships_data(sea)
	if list.is_empty():
		return
	var size := sea.size_m()
	for d in list:
		var patrol: Dictionary = d.get("patrol", {})
		var a := _ratio_to_pos(patrol.get("a", [0.5, 0.5]), size)
		var b := _ratio_to_pos(patrol.get("b", [0.5, 0.5]), size)
		ships.append({
			"id": str(d.get("id", "")),
			"name": str(d.get("name", "")),
			"kind": str(d.get("kind", "sailor")),
			"faction": str(d.get("faction", "sailors")),
			"crew": int(d.get("crew", 20)),
			"speed_ms": float(d.get("speed_ms", 2.0)),
			"text": str(d.get("text", "")),
			"pos": a,
			"heading": rad_to_deg(atan2(b.y - a.y, b.x - a.x)),
			"a": a,
			"b": b,
			"to_b": true,
			"cooldown": 0.0,
		})


static func ships_data(sea: Sea) -> Array:
	"""这个世界里有哪些船：读**世界文件的邻居** `npcs.json`（规则本身留在 defs 里）。

	迷你海域没有这张表 —— 所以那里一条别的船都没有（教程与回归用）。
	"""
	var p := sea.npcs_path() if sea != null else ""
	if p == "":
		return []
	var d = JSON.parse_string(FileAccess.get_file_as_string(p))
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("NPC 船表读不出来：" + p)
		return []
	return (d as Dictionary).get("ships", [])


func _ratio_to_pos(r, size: Vector2) -> Vector2:
	if typeof(r) != TYPE_ARRAY or (r as Array).size() < 2:
		return size * 0.5
	return Vector2(float(r[0]) * size.x, float(r[1]) * size.y)


func tick(delta: float, sea: Sea) -> void:
	"""巡逻：在两个点之间来回（海战打断不了它的巡逻，它只管走）。"""
	for s in ships:
		if float(s["cooldown"]) > 0.0:
			s["cooldown"] = maxf(0.0, float(s["cooldown"]) - delta)
			continue
		var target: Vector2 = s["b"] if bool(s["to_b"]) else s["a"]
		var step := sea.delta(s["pos"], target)
		var dist := step.length()
		if dist < 120.0:
			s["to_b"] = not bool(s["to_b"])
			continue
		var dir := step / dist
		s["heading"] = rad_to_deg(atan2(dir.y, dir.x))
		s["pos"] = sea.wrap_pos((s["pos"] as Vector2) + dir * float(s["speed_ms"]) * delta)


func is_hostile_to(s: Dictionary, factions: Factions) -> bool:
	"""谁算敌人：海盗永远是；别的船只有**态度翻到敌对**才算（你惹过他们）。"""
	if str(s["kind"]) == "pirate":
		return true
	if factions == null:
		return false
	return factions.stance(str(s["faction"])) == Culture.HOSTILE


func nearest_hostile(pos: Vector2, range_m: float, sea: Sea,
		factions: Factions = null) -> Dictionary:
	"""最近的一条**敌意**船（海盗，或者被你惹到翻脸的势力）—— 只在遭遇距离之内。"""
	var best: Dictionary = {}
	var best_d := range_m
	for s in ships:
		if float(s["cooldown"]) > 0.0:
			continue
		if not is_hostile_to(s, factions):
			continue
		var d := sea.dist(pos, s["pos"])
		if d <= best_d:
			best_d = d
			best = s
	return best


func nearest_any(pos: Vector2, range_m: float, sea: Sea) -> Dictionary:
	var best: Dictionary = {}
	var best_d := range_m
	for s in ships:
		var d := sea.dist(pos, s["pos"])
		if d <= best_d:
			best_d = d
			best = s
	return best


func mark_engaged(id: String, cooldown: float) -> void:
	for s in ships:
		if str(s["id"]) == id:
			s["cooldown"] = cooldown
			# 遭遇之后它换一个方向走开，免得又在原地等着
			s["to_b"] = not bool(s["to_b"])


func count_of(kind: String) -> int:
	var n := 0
	for s in ships:
		if str(s["kind"]) == kind:
			n += 1
	return n


func describe() -> String:
	return "%d 条别的船（海盗 %d、商人 %d）" % [ships.size(), count_of("pirate"), count_of("merchant")]


# ------------------------------------------------------------ 存档契约

func capture_state() -> Dictionary:
	var out := []
	for s in ships:
		out.append({
			"id": str(s["id"]), "pos": StateIO.v2(s["pos"]),
			"heading": float(s["heading"]), "to_b": bool(s["to_b"]),
			"cooldown": float(s["cooldown"]),
		})
	return {"ships": out}


func apply_state(d: Dictionary) -> void:
	var raw: Array = d.get("ships", [])
	for i in raw.size():
		if i >= ships.size():
			break
		var r: Dictionary = raw[i]
		# 按 id 配（不是按下标）—— 数据里加一条船不该把老存档的船全挪位
		for s in ships:
			if str(s["id"]) != str(r.get("id", "")):
				continue
			s["pos"] = StateIO.to_v2(r.get("pos", [0.0, 0.0]))
			s["heading"] = float(r.get("heading", 0.0))
			s["to_b"] = bool(r.get("to_b", true))
			s["cooldown"] = float(r.get("cooldown", 0.0))
			break
