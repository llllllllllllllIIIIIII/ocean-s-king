class_name Dilemma
extends RefCounted

# 三个高压抉择（M5）：缺粮 / 重伤病 / 部落冲突。
#
# 一条规矩：**每个选项的后果都必须是数**（船员状态、关系、纪律、结局分数），
# 而且"选 A 与选 B 之后状态确实不同"要能被断言 —— 不做只在文案上不同的选项。
#
# 触发条件也只写在 `data/defs/dilemmas.json` 里，代码里不重复一份：
# 不然改了数据、忘了改代码，就会出现"条件明明满足了却不弹"的鬼故事。

const DEFS_PATH := "res://data/defs/dilemmas.json"
# M15：逃亡类后果**不许把船走空**（同 `Society.MIN_CREW_ABOARD`，两边一个口径）
const MIN_ABOARD := 12

var defs: Dictionary = {}          # 静态
var dynamic: Array = []            # M17：临时塞进来的卡（叛乱处置）
var resolved: Dictionary = {}      # dilemma_id -> option_id（**会变的值**）
var pending: Array = []            # 已经弹出、等玩家回答的


func setup(path := DEFS_PATH) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("抉择表读不出来：" + path)
		return
	defs = d
	resolved.clear()
	pending.clear()


func ids() -> Array:
	var out := []
	for d in defs.get("dilemmas", []):
		out.append(str(d.get("id", "")))
	return out


func def_of(id: String) -> Dictionary:
	for d in defs.get("dilemmas", []):
		if str(d.get("id", "")) == id:
			return d
	for d in dynamic:
		if str((d as Dictionary).get("id", "")) == id:
			return d
	return {}


func option_of(id: String, option_id: String) -> Dictionary:
	for o in def_of(id).get("options", []):
		if str(o.get("id", "")) == option_id:
			return o
	return {}


func is_resolved(id: String) -> bool:
	return resolved.has(id)


func inject(def: Dictionary) -> void:
	"""临时塞一张卡进来（M17 的叛乱处置卡就是这么做出来的：它的后果不写在
	`dilemmas.json` 里，而是由 `Voyage.respond_to_mutiny()` 按真源结算）。"""
	var id := str(def.get("id", ""))
	if id == "":
		return
	var known := false
	for d in dynamic:
		if str(d.get("id", "")) == id:
			d.clear()
			d.merge(def, true)
			known = true
	if not known:
		dynamic.append(def.duplicate(true))
	if not pending.has(id):
		pending.append(id)


func clear_injected(id: String) -> void:
	resolved[id] = true
	dynamic = dynamic.filter(func(d): return str((d as Dictionary).get("id", "")) != id)


# ------------------------------------------------------------ 触发

func check(v: Voyage) -> void:
	"""每帧看一眼：有没有哪个抉择的条件成立了。已经答过的不再问。"""
	for d in defs.get("dilemmas", []):
		var id := str(d.get("id", ""))
		if is_resolved(id) or _is_pending(id):
			continue
		if _met(d.get("trigger", {}), v):
			pending.append(id)
	# M17：临时卡（叛乱处置）也要能被 `check()` 之后取到
	for d in dynamic:
		var did := str(d.get("id", ""))
		if not is_resolved(did) and not _is_pending(did):
			pending.append(did)


func _is_pending(id: String) -> bool:
	return pending.has(id)


func _met(tr: Dictionary, v: Voyage) -> bool:
	match str(tr.get("kind", "")):
		"starving":
			return v.cargo.starving or v.shortage_events > 0
		"wounded":
			return _injured(v) >= int(tr.get("min_injured", 2))
		"tribal":
			# 已经打起来了就别再摆"要不要谈"的卡 —— 子弹在飞的时候没人谈判
			return v.fired.has("village") and v.battle == null
		# M17：按**航程长度**与**紧张度**开卡 —— 四个阶段各至少两张
		# （出航 / 海峡 / 太平洋 / 归乡），条件只写在这里，代码里不重复一份。
		"days_min":
			return VoyageJournal.day_index(v.t) >= int(tr.get("days", 0))
		"tension_min":
			return v.society.tension >= float(tr.get("tension", 1.0))
	return false


func _injured(v: Voyage) -> int:
	var n := 0
	for m in v.roster.key_crew():
		if m.health < 0.75:
			n += 1
	for m in v.roster.hands():
		if m.health < 0.75:
			n += 1
	return n


func current() -> String:
	return str(pending[0]) if not pending.is_empty() else ""


func take_current() -> Dictionary:
	var id := current()
	return def_of(id) if id != "" else {}


# ------------------------------------------------------------ 回答

func resolve(v: Voyage, id: String, option_id: String) -> Dictionary:
	"""选一条后果。返回一份"这一选改了哪些数"的清单（测试与面板都用它）。"""
	var d := def_of(id)
	if d.is_empty():
		return {"ok": false, "reason": "没有这个抉择"}
	var o := option_of(id, option_id)
	if o.is_empty():
		return {"ok": false, "reason": "没有这个选项"}
	var eff: Dictionary = o.get("effects", {})
	var before := _snapshot(v)
	# ① 船员状态
	for m in v.roster.members:
		var mood_delta := float(eff.get("mood_all", 0.0))
		if m.is_key:
			mood_delta += float(eff.get("mood_key", 0.0))
		if not is_zero_approx(mood_delta):
			m.mood = clampf(m.mood + mood_delta, 0.0, 1.0)
		if eff.has("health_all"):
			m.health = clampf(m.health + float(eff["health_all"]), 0.05, 1.0)
		if eff.has("fatigue_all"):
			m.fatigue = clampf(m.fatigue + float(eff["fatigue_all"]), 0.0, 1.0)
	# ② 关系：推给"最不对付的那一对"
	if eff.has("affinity_pair"):
		var pair := _worst_pair(v)
		if pair.size() == 2:
			v.society.bump_relation(str(pair[0]), str(pair[1]), float(eff["affinity_pair"]),
				1 if float(eff["affinity_pair"]) < -0.1 else 0)
	# ③ 社会量
	if eff.has("tension"):
		v.society.tension = clampf(v.society.tension + float(eff["tension"]), 0.0, 1.0)
	if eff.has("discipline"):
		v.society.discipline = clampf(v.society.discipline + float(eff["discipline"]), 0.0, 1.0)
	# ④ 人命
	if eff.has("hurt"):
		for m in v.roster.members:
			if not m.ashore:
				m.health = clampf(m.health - float(eff["hurt"]), 0.05, 1.0)
				break
	if eff.has("deserters"):
		# ⚠️ M15：同 `Society` —— 船上至少留 `MIN_ABOARD` 个人，不许把船走空
		var aboard := 0
		for m in v.roster.members:
			if not m.ashore and not m.dead:
				aboard += 1
		var room := maxi(0, aboard - MIN_ABOARD)
		var want := mini(int(eff["deserters"]), room)
		var gone := 0
		for m in v.roster.members:
			if gone >= want:
				break
			if m.ashore:
				continue
			m.ashore = true
			m.job = "left_behind"
			gone += 1
	# ⑤ 花掉的东西（药、火药…）
	for item in (eff.get("use_item", {}) as Dictionary).keys():
		v.cargo.remove(str(item), int(eff["use_item"][item]))
	# ⑤.5 当地人的态度（M6 收尾）：选了"开火/抓人"就该真的翻脸 ——
	#     这一格原来没接，所以卡片上写着"开火吓退他们"，选完 culture 一点没变，
	#     下一段上岸也不会有人动手（陆战那一整层因此摸不到）。
	if eff.has("culture"):
		v.culture.react("green_cape", str(eff["culture"]), "抉择：%s" % str(o.get("name", id)))
	# ⑥ 结局分数与旗标
	for k in (eff.get("score", {}) as Dictionary).keys():
		var key := str(k)
		v.ending_score[key] = int(v.ending_score.get(key, 0)) + int(eff["score"][k])
	if eff.has("flag"):
		v.fired[str(eff["flag"])] = true
	# ⑦ 记账
	resolved[id] = option_id
	pending.erase(id)
	var line := str(o.get("journal", o.get("name", option_id)))
	v.journal.decide(line)
	v.journal.record(v.t, "dilemma", line)
	v.say("（抉择·%s）%s" % [str(d.get("name", id)), str(o.get("name", option_id))], true)
	return {"ok": true, "id": id, "option": option_id, "text": line,
		"before": before, "after": _snapshot(v), "effects": eff}


func _worst_pair(v: Voyage) -> Array:
	var keys: Array = v.roster.key_crew()
	var best := 0.0
	var out := []
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: CrewMember = keys[i]
			var b: CrewMember = keys[j]
			var aff := float(v.society.relation_between(a.id, b.id)["affinity"])
			if aff < best:
				best = aff
				out = [a.id, b.id]
	return out


func _snapshot(v: Voyage) -> Dictionary:
	var mood := 0.0
	var health := 0.0
	var n := 0
	for m in v.roster.members:
		mood += m.mood
		health += m.health
		n += 1
	return {
		"mood": mood / maxf(1.0, float(n)),
		"health": health / maxf(1.0, float(n)),
		"tension": v.society.tension,
		"discipline": v.society.discipline,
		"score": v.ending_score.duplicate(),
	}


# ------------------------------------------------------------ 存档（ShipState，docs/14 第 3 节）

func capture_state() -> Dictionary:
	return {"resolved": resolved.duplicate(), "pending": pending.duplicate()}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	resolved = (d.get("resolved", {}) as Dictionary).duplicate()
	dynamic.clear()                      # 临时卡不进存档：读档后由叛乱状态重新摆
	pending = (d.get("pending", []) as Array).duplicate()
