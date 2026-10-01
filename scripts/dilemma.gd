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

var defs: Dictionary = {}          # 静态
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
	return {}


func option_of(id: String, option_id: String) -> Dictionary:
	for o in def_of(id).get("options", []):
		if str(o.get("id", "")) == option_id:
			return o
	return {}


func is_resolved(id: String) -> bool:
	return resolved.has(id)


# ------------------------------------------------------------ 触发

func check(v: Voyage) -> void:
	"""每帧看一眼：有没有哪个抉择的条件成立了。已经答过的不再问。"""
	for d in defs.get("dilemmas", []):
		var id := str(d.get("id", ""))
		if is_resolved(id) or _is_pending(id):
			continue
		if _met(d.get("trigger", {}), v):
			pending.append(id)


func _is_pending(id: String) -> bool:
	return pending.has(id)


func _met(tr: Dictionary, v: Voyage) -> bool:
	match str(tr.get("kind", "")):
		"starving":
			return v.cargo.starving or v.shortage_events > 0
		"wounded":
			return _injured(v) >= int(tr.get("min_injured", 2))
		"tribal":
			return v.fired.has("village")
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
		var gone := 0
		for m in v.roster.members:
			if gone >= int(eff["deserters"]):
				break
			if m.ashore:
				continue
			m.ashore = true
			m.job = "left_behind"
			gone += 1
	# ⑤ 花掉的东西（药、火药…）
	for item in (eff.get("use_item", {}) as Dictionary).keys():
		v.cargo.remove(str(item), int(eff["use_item"][item]))
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
	pending = (d.get("pending", []) as Array).duplicate()
