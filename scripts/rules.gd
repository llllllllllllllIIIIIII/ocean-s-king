class_name Rules
extends RefCounted

# 规则制度（M5）：玩家定的规矩 —— 口粮、饮水、值班、酒、宵禁、处罚。
#
# 这一层刻意做得很薄：**它只是一张"档位 → 数值"的表**（真源在
# `data/defs/rules.json`）。理由是验收第 1 条要的是"改规则 → 数值真的变"：
# 那就必须让规则直接给出乘数与偏移，而不是把影响散在事件里 ——
# 散着写的话，改一条规矩会牵动多少个系统，谁也说不清。
#
# 它属于**本船状态**（每个船长有自己的规矩），所以进 ShipState、不上网。

const DEFS_PATH := "res://data/defs/rules.json"

var defs: Dictionary = {}          # 静态：规则表
var choice: Dictionary = {}        # rule_id -> option_id（**会变的值**）
var changed: int = 0               # 改过几次规矩（结算页会写）


func setup(path := DEFS_PATH) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("规则表读不出来：" + path)
		return
	defs = d
	choice.clear()
	for r in d.get("rules", []):
		choice[str(r.get("id", ""))] = str(r.get("default", ""))
	changed = 0


func rule_ids() -> Array:
	var out := []
	for r in defs.get("rules", []):
		out.append(str(r.get("id", "")))
	return out


func rule_def(rule_id: String) -> Dictionary:
	for r in defs.get("rules", []):
		if str(r.get("id", "")) == rule_id:
			return r
	return {}


func option_of(rule_id: String) -> Dictionary:
	var r := rule_def(rule_id)
	var want := str(choice.get(rule_id, r.get("default", "")))
	for o in r.get("options", []):
		if str(o.get("id", "")) == want:
			return o
	return {}


func option_name(rule_id: String) -> String:
	return str(option_of(rule_id).get("name", "?"))


func set_rule(rule_id: String, option_id: String) -> bool:
	var r := rule_def(rule_id)
	if r.is_empty():
		return false
	var ok := false
	for o in r.get("options", []):
		if str(o.get("id", "")) == option_id:
			ok = true
	if not ok:
		return false
	if str(choice.get(rule_id, "")) == option_id:
		return true                    # 没变就不算改
	choice[rule_id] = option_id
	changed += 1
	return true


func cycle(rule_id: String, dir: int) -> void:
	var r := rule_def(rule_id)
	var opts: Array = r.get("options", [])
	if opts.is_empty():
		return
	var idx := 0
	for i in opts.size():
		if str(opts[i].get("id", "")) == str(choice.get(rule_id, "")):
			idx = i
	idx = posmod(idx + dir, opts.size())
	set_rule(rule_id, str(opts[idx].get("id", "")))


# ------------------------------------------------------------ 规则 → 数值

func _f(rule_id: String, field: String, fallback: float) -> float:
	return float(option_of(rule_id).get(field, fallback))


func food_mult() -> float:
	return _f("ration", "food_mult", 1.0)


func water_mult() -> float:
	return _f("water", "water_mult", 1.0)


func fatigue_mult() -> float:
	"""值班 + 口粮 + 饮水一起决定疲劳攒得多快（相乘）。"""
	return _f("watch", "fatigue_mult", 1.0) * _f("ration", "fatigue_mult", 1.0) \
		* _f("water", "fatigue_mult", 1.0)


func mood_bias() -> float:
	"""六条规矩的心情偏移**相加**：一天下来人是被这一堆规矩一起压着的。"""
	var total := 0.0
	for rid in rule_ids():
		total += _f(rid, "mood_bias", 0.0)
	return total


func tension_mult() -> float:
	return _f("liquor", "tension_mult", 1.0) * _f("curfew", "tension_mult", 1.0) \
		* _f("punish", "tension_mult", 1.0)


func discipline_bonus() -> float:
	return _f("punish", "discipline_bonus", 0.0) + _f("curfew", "discipline_bonus", 0.0)


func efficiency() -> float:
	return _f("watch", "efficiency", 1.0)


func key_first() -> bool:
	return bool(option_of("ration").get("key_bonus", false))


# --- M17：四条新规矩（战利品 / 贸易 / 探险所得 / 赌博）---

func crew_share_of(rule_id: String) -> float:
	"""这一项收益里**船员拿几成**（分配时用；剩下的归远征队/王室）。"""
	return clampf(_f(rule_id, "crew_share", 1.0), 0.0, 1.0)


func share_rule_for(kind: String) -> String:
	match kind:
		"prize", "spoils":
			return "spoils"
		"trade":
			return "trade_share"
		"discovery", "explore":
			return "discovery_share"
	return ""


func gambling_allowed() -> bool:
	return bool(option_of("gambling").get("gambling_allowed", false))


# --- M17：叛乱的玩家手段（处罚 / 配给 / 上岸 / 谈判 / 镇压）---

func mutiny_responses() -> Array:
	return defs.get("mutiny_responses", [])


func mutiny_response(id: String) -> Dictionary:
	for r in mutiny_responses():
		if str(r.get("id", "")) == id:
			return r
	return {}


# ------------------------------------------------------------ 给界面用

func lines() -> Array:
	var out := []
	for r in defs.get("rules", []):
		out.append("%s：%s" % [str(r.get("name", "")), option_name(str(r.get("id", "")))])
	return out


func describe() -> String:
	return "　".join(lines())


# ------------------------------------------------------------ 存档（ShipState，docs/14 第 3 节）

func capture_state() -> Dictionary:
	return {"choice": choice.duplicate(), "changed": changed}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	var c: Dictionary = d.get("choice", {})
	for k in c.keys():
		choice[str(k)] = str(c[k])
	changed = int(d.get("changed", changed))
