class_name EventPool
extends RefCounted

# 事件池（M7）：三类池子（外部 / 船内 / 探险）+ 一条**因果链**。
#
# 三条设计：
#   1. **事件不是随机抽的**：每一条的 `requires` 都盯着**别的系统里的真实状态**
#      （culture 的态度、港口的服务、货舱的余量、天气、社会的紧张度）。
#      两个上限也由系统给：紧张度越高越容易出事、同一条事件只发生一次。
#   2. **链子比单条重要**：`chain.json` 那六条串起来就是一条四环以上的因果链
#      （部落冲突 → 敌意 → 港口拒绝 → 补给断 → 风暴带 → 损伤 → 绝望），
#      而每一环都是**上一个系统真的变了**才允许触发。
#   3. 判定用 (事件时刻, 池子) 的哈希取候选里的第几个 —— 无随机数，可复现。

const DIR := "res://data/defs/events"
const FILES := ["chain.json", "external.json", "ship.json", "expedition.json",
	"south_america.json", "pacific.json"]   # M12/M13：按海域发生的事件（海峡/太平洋）
const CHECK_STEP := 600.0            # 每 600 个游戏秒看一次（= 0.5 个航程小时）
const COOLDOWN := 900.0              # 两次事件之间至少隔这么久（游戏秒）

var defs: Array = []                 # 全部事件（静态）
var fired: Dictionary = {}           # id -> true（**会变的值**）
var order: Array = []                # 触发过的顺序（测试与日志要看）
var _acc := 0.0
var _cooldown := 0.0
var _pick := 0


func setup() -> void:
	defs.clear()
	fired.clear()
	order.clear()
	_acc = 0.0
	_cooldown = 0.0
	_pick = 0
	for f in FILES:
		var p := "%s/%s" % [DIR, f]
		var d = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(d) != TYPE_DICTIONARY:
			push_warning("事件池读不出来：" + p)
			continue
		var pool := str(d.get("pool", f))
		for raw in d.get("events", []):
			var e: Dictionary = raw.duplicate(true)
			e["pool"] = pool
			defs.append(e)
	# 优先级高的先判（链子 10、普通 1~3）—— 链子不能被杂事插队
	defs.sort_custom(func(a, b): return int(a.get("priority", 1)) > int(b.get("priority", 1)))


func ids() -> Array:
	var out := []
	for e in defs:
		out.append(str(e["id"]))
	return out


func pool_of(id: String) -> String:
	for e in defs:
		if str(e["id"]) == id:
			return str(e.get("pool", ""))
	return ""


func try_fire(id: String, v: Voyage) -> Dictionary:
	"""强制触发一条（测试与剧情用）。条件不满足时返回原因，不硬来。"""
	var e := def_of(id)
	if e.is_empty():
		return {"ok": false, "reason": "没有这条事件"}
	if fired.has(id):
		return {"ok": false, "reason": "已经发生过"}
	var why := unmet(e, v)
	if why != "":
		return {"ok": false, "reason": why}
	_apply(e, v)
	return {"ok": true, "id": id, "name": str(e.get("name", id))}


func def_of(id: String) -> Dictionary:
	for e in defs:
		if str(e["id"]) == id:
			return e
	return {}


# ------------------------------------------------------------ 每帧

func tick(delta: float, v: Voyage) -> void:
	_acc += delta
	_cooldown = maxf(0.0, _cooldown - delta)
	if _acc < CHECK_STEP:
		return
	_acc = 0.0
	if _cooldown > 0.0:
		return
	var ready: Array = []
	for e in defs:
		var id := str(e["id"])
		if fired.has(id):
			continue
		if unmet(e, v) == "":
			ready.append(e)
	if ready.is_empty():
		return
	# 确定性挑一条：优先级最高的那一批里，按 (事件时刻, 池子) 的哈希选
	var top := int((ready[0] as Dictionary).get("priority", 1))
	var best: Array = ready.filter(func(e): return int(e.get("priority", 1)) == top)
	var h := absi(hash(str(int(v.t)) + "|" + str(_pick)))
	_pick += 1
	_apply(best[h % best.size()], v)
	_cooldown = COOLDOWN


func unmet(e: Dictionary, v: Voyage) -> String:
	"""条件检查。返回空串 = 可以发生；否则是一句人话的原因（测试直接读它）。"""
	var r: Dictionary = e.get("requires", {})
	for f in r.get("flags_all", []):
		if not v.fired.has(str(f)):
			return "缺少旗标 " + str(f)
	for f in r.get("flags_none", []):
		if v.fired.has(str(f)):
			return "该旗标不该出现：" + str(f)
	for id in r.get("culture_hostile", []):
		if v.culture.stance(str(id)) != Culture.HOSTILE:
			return "%s 还不是敌对" % str(id)
	var stance_req: Dictionary = r.get("culture_stance", {})
	for id in stance_req.keys():
		if v.culture.stance(str(id)) != str(stance_req[id]):
			return "%s 不是%s" % [str(id), str(stance_req[id])]
	if r.has("weather_is"):
		var want: Array = r["weather_is"]
		if not want.has(v.weather.state_id):
			return "天气不对（现在是 %s）" % v.weather.state_name()
	if r.has("days_min") and VoyageJournal.day_index(v.t) < int(r["days_min"]):
		return "航程还不够长"
	if r.has("ashore") and bool(r["ashore"]) != v.ashore:
		return "该上岸的时候才发生"
	if r.has("tension_min") and v.society.tension < float(r["tension_min"]):
		return "紧张度不够（%.2f）" % v.society.tension
	for it in (r.get("supplies_below", {}) as Dictionary).keys():
		if v.cargo.qty(str(it)) >= int(r["supplies_below"][it]):
			return "%s 还剩得够多" % str(it)
	if r.has("memory_min"):
		for k in (r["memory_min"] as Dictionary).keys():
			if int(v.memory.get(str(k), 0)) < int(r["memory_min"][k]):
				return "世界还没记住这件事：" + str(k)
	# M12：**按海域**发生的事件（"海峡里的狂风""太平洋上的第一眼"这种）。
	# 用的是世界数据里的分区图幅（M9 加的 `regions`），不是另写一张坐标表。
	if r.has("region"):
		var want := str(r["region"])
		var here := v.sea.world.region_of_tile(v.sea.tile_of(v.ship.position_m()))
		if str(here.get("id", "")) != want:
			return "不在这片海域（要 %s）" % want
	return ""


func _apply(e: Dictionary, v: Voyage) -> void:
	var id := str(e["id"])
	fired[id] = true
	order.append(id)
	var eff: Dictionary = e.get("effects", {})
	if eff.has("flag"):
		v.fired[str(eff["flag"])] = true
	for part in (eff.get("damage", {}) as Dictionary).keys():
		v.ship.apply_damage(str(part), float(eff["damage"][part]))
	if eff.has("mood"):
		for m in v.roster.members:
			m.mood = clampf(m.mood + float(eff["mood"]), 0.0, 1.0)
	if eff.has("health"):
		for m in v.roster.key_crew():
			m.health = clampf(m.health + float(eff["health"]), 0.05, 1.0)
	if eff.has("tension"):
		v.society.tension = clampf(v.society.tension + float(eff["tension"]), 0.0, 1.0)
	if eff.has("discipline"):
		v.society.discipline = clampf(v.society.discipline + float(eff["discipline"]), 0.0, 1.0)
	for item in (eff.get("supplies", {}) as Dictionary).keys():
		var n := int(eff["supplies"][item])
		if n >= 0:
			v.cargo.add(str(item), n)
		else:
			v.cargo.remove(str(item), mini(-n, v.cargo.qty(str(item))))
	for k in (eff.get("memory_add", {}) as Dictionary).keys():
		v.memory[str(k)] = int(v.memory.get(str(k), 0)) + int(eff["memory_add"][k])
	if eff.has("weather"):
		var w: Dictionary = eff["weather"]
		v.weather.force(str(w.get("id", "squall")), float(w.get("hours", 6.0)))
	if e.has("knowledge"):
		var k: Dictionary = e["knowledge"]
		v.knowledge.note(str(k.get("category", "chart")), str(k.get("id", id)),
			str(k.get("title", e.get("name", id))), str(k.get("text", "")), v.t)
	var msg := str(eff.get("message", e.get("text", "")))
	if msg != "":
		v.say("【%s】%s" % [str(e.get("name", id)), msg], true)
	v.journal.record(v.t, "event", "%s：%s" % [str(e.get("name", id)), str(e.get("text", ""))])


# ------------------------------------------------------------ 存档（WorldState：全局事件旗标）

func capture_state() -> Dictionary:
	return { "fired": fired.duplicate(), "order": order.duplicate(), "_acc": _acc,
		"_cooldown": _cooldown, "_pick": _pick }


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	fired = (d.get("fired", {}) as Dictionary).duplicate()
	order = (d.get("order", []) as Array).duplicate()
	_acc = float(d.get("_acc", 0.0))
	_cooldown = float(d.get("_cooldown", 0.0))
	_pick = int(d.get("_pick", 0))
