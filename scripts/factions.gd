class_name Factions
extends RefCounted

# 势力与外交（M11）：六类势力各一条态度，外加王室命令的执行度。
#
# 三条设计（docs/22 第 8 章）：
#   1. **数值只有一份**：态度初值、反应表、阈值、王室命令全在
#      `data/defs/factions.json`（与 rules.json / weapons.json 同等地位）。
#   2. **态度必须"有后果"**：跨阈值换档之后，港口/贸易/遭遇的行为真的会变 ——
#      所以 `react()` 的每一次变化都能被断言（docs/23 的 M11 第 3 条硬指标）。
#   3. **当地文明不是一个势力**：每个群体自己一条记录（在 `Culture` 里），
#      这里只给"没打过交道的默认值"与汇总口径。
#
# 态度值 0..1：< hostile_max 敌对、> friendly_min 友善，中间中立。

const DEFS_PATH := "res://data/defs/factions.json"

static var _defs_cache: Dictionary = {}


static func defs() -> Dictionary:
	if _defs_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DEFS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_defs_cache = d
		else:
			push_error("势力表读不出来：" + DEFS_PATH)
	return _defs_cache


static func bands() -> Dictionary:
	return defs().get("attitude_bands", {})


static func ids() -> Array:
	var out := []
	for f in defs().get("factions", []):
		out.append(str(f.get("id", "")))
	return out


static func def_of(id: String) -> Dictionary:
	for f in defs().get("factions", []):
		if str(f.get("id", "")) == id:
			return f
	return {}


static func display_name(id: String) -> String:
	var d := def_of(id)
	return str(d.get("name", id)) if not d.is_empty() else id


static func kind_of(id: String) -> String:
	return str(def_of(id).get("kind", "neutral"))


static func default_attitude(id: String) -> float:
	var d := def_of(id)
	if d.is_empty():
		return float(bands().get("start", 0.5))
	return float(d.get("attitude", bands().get("start", 0.5)))


static func reaction(id: String, action: String) -> float:
	"""某个势力对某个行为的反应（0 = 不在乎）。"""
	var table: Dictionary = def_of(id).get("react", {})
	return float(table.get(action, 0.0))


static func band_of(attitude: float) -> String:
	if attitude < float(bands().get("hostile_max", 0.35)):
		return Culture.HOSTILE
	if attitude > float(bands().get("friendly_min", 0.65)):
		return Culture.FRIENDLY
	return Culture.NEUTRAL


static func orders() -> Array:
	return defs().get("royal_orders", [])


static func order_def(id: String) -> Dictionary:
	for o in orders():
		if str(o.get("id", "")) == id:
			return o
	return {}


static func order_name(id: String) -> String:
	return str(order_def(id).get("name", id))


# ------------------------------------------------------------ 实例状态（进 WorldState）

var attitude: Dictionary = {}          # faction id -> 0..1
var order_state: Dictionary = {}       # order id -> "open" / "done" / "broken"
var history: Array = []                # 最近几次态度变化（[势力, 行为, 变化后]），给面板与日志


func setup() -> void:
	attitude.clear()
	for id in Factions.ids():
		attitude[id] = Factions.default_attitude(id)
	order_state.clear()
	for o in Factions.orders():
		order_state[str(o.get("id", ""))] = "open"
	history.clear()


func value(id: String) -> float:
	return float(attitude.get(id, Factions.default_attitude(id)))


func stance(id: String) -> String:
	return Factions.band_of(value(id))


func react(id: String, action: String, times := 1) -> float:
	"""玩家做了一件事：所有势力按**各自的反应表**变态度。返回这个势力的变化量。"""
	if not attitude.has(id):
		attitude[id] = Factions.default_attitude(id)
	var delta := Factions.reaction(id, action) * float(times)
	if is_zero_approx(delta):
		return 0.0
	attitude[id] = clampf(value(id) + delta, 0.0, 1.0)
	history.append([id, action, value(id)])
	if history.size() > 40:
		history.pop_front()
	return delta


func react_all(action: String, times := 1) -> Array:
	"""一个行为**所有势力都会看见**（有的在乎、有的不在乎）—— 返回变了的那些。"""
	var out := []
	for id in Factions.ids():
		var d := react(id, action, times)
		if not is_zero_approx(d):
			out.append({"id": id, "delta": d, "value": value(id), "stance": stance(id)})
	return out


func locals_overall(culture: Culture) -> float:
	"""当地文明的"总体印象"：各群体态度的平均（一个友好一个敌对 = 中立）。

	⚠️ 两个刻度：`Culture` 的态度是 **-1..1**（±0.35 分档），本类的是 **0..1**。
	这里把前者换算过来，免得同一件事在两张表上写着差不多的数却不是一回事。
	"""
	if culture == null or culture.groups.is_empty():
		return value("locals")
	var sum := 0.0
	var n := 0
	for gid in culture.groups.keys():
		sum += (culture.attitude(str(gid)) + 1.0) * 0.5
		n += 1
	return sum / float(maxi(1, n))


# ------------------------------------------------------------ 王室命令

func check_order(spec: Dictionary, ctx: Dictionary) -> bool:
	"""一条命令完成了没有。条件类型写在真源里，这里只是那个求值器。"""
	match str(spec.get("type", "")):
		"reached_port":
			var ports: Array = ctx.get("visited_ports", [])
			return ports.has(str(spec.get("port", "")))
		"goods_value":
			return float(ctx.get("goods_value", 0.0)) >= float(spec.get("ducats", 0.0))
		"no_friendly_kill":
			return int(ctx.get("friendly_kills", 0)) == 0
	return false


func evaluate_orders(ctx: Dictionary) -> Array:
	"""逐条判：完成 / 违抗 / 还开着。**同样的 ctx 必得同样的答案**（无随机）。"""
	var out := []
	for o in Factions.orders():
		var id := str(o.get("id", ""))
		var spec: Dictionary = o.get("check", {})
		var done := check_order(spec, ctx)
		# 违抗：只有"不得私自改变远征目的"会因为行为被记成 broken（其它两条是"没做到"）
		var broken := false
		if str(spec.get("type", "")) == "no_friendly_kill" and int(ctx.get("friendly_kills", 0)) > 0:
			broken = true
		out.append({"id": id, "name": str(o.get("name", id)), "done": done, "broken": broken,
			"reward": float(o.get("reward", 0.0)), "penalty": float(o.get("penalty", 0.0))})
	return out


func settle_orders(ctx: Dictionary, ending_score: Dictionary) -> Dictionary:
	"""结算：完成的加、违抗的扣，写进历史与政治成果。只结算一次（已结算的不再动）。"""
	var gained := 0.0
	var lost := 0.0
	var done_list := []
	var broken_list := []
	for r in evaluate_orders(ctx):
		var id := str(r["id"])
		if str(order_state.get(id, "open")) != "open":
			continue
		if bool(r["broken"]):
			order_state[id] = "broken"
			lost += float(r["penalty"])
			broken_list.append(str(r["name"]))
		elif bool(r["done"]):
			order_state[id] = "done"
			gained += float(r["reward"])
			done_list.append(str(r["name"]))
	var delta := gained + lost
	if not is_zero_approx(delta):
		ending_score["history"] = float(ending_score.get("history", 0.0)) + delta
	return {"delta": delta, "done": done_list, "broken": broken_list,
		"open": order_state.duplicate()}


func describe_orders() -> String:
	var parts := PackedStringArray()
	for o in Factions.orders():
		var id := str(o.get("id", ""))
		var st := str(order_state.get(id, "open"))
		parts.append("%s %s" % ["✔" if st == "done" else ("✘" if st == "broken" else "○"),
			str(o.get("name", id))])
	return "　".join(parts)


# ------------------------------------------------------------ 存档契约

func capture_state() -> Dictionary:
	return {
		"attitude": attitude.duplicate(),
		"order_state": order_state.duplicate(),
		"history": history.duplicate(true),
	}


func apply_state(d: Dictionary) -> void:
	attitude = (d.get("attitude", {}) as Dictionary).duplicate()
	order_state = (d.get("order_state", {}) as Dictionary).duplicate()
	history = (d.get("history", []) as Array).duplicate(true)
	# 老存档里缺哪一家就补上默认值（不因为是旧档就让它没有这家势力）
	for id in Factions.ids():
		if not attitude.has(id):
			attitude[id] = Factions.default_attitude(id)
