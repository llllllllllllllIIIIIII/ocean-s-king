class_name Story
extends RefCounted

# 三幕剧情（Day 7）：把 data/story/acts.json 里的"触发条件 + 文本 + 后果"演出来。
#
# docs/01 支柱 6：出港学操帆 → 发现岛并抉择是否登陆 → 返航结算。
# 三幕的顺序是**写死**的（一次只推进一幕），因为叙事顺序本身就是设计。
# 每一幕里能变的只有三样：什么时候触发、演出什么文本、触发什么后果。
#
# 它同样不碰船：后果只允许"写日志 / 弹消息 / 立旗标 / 改当前目标 / 宣布可以结算"。
# 想让剧情影响航行，只能通过已经存在的玩法入口（比如 voyage 里的风向突变），
# 绝不能在这里写船的速度或位置 —— tools/check_motion_ownership.py 会抓。

const DATA_PATH := "res://data/story/acts.json"
# 抉择做完之后的那个目标：把船开回出发港。写在这里是因为它是"第二幕答完之后"
# 的固定后续，不随剧本数据变 —— docs/01 支柱 6 的三幕最后一幕就是返航结算。
const RETURN_OBJECTIVE := "返航：把船开回出发港（按 . 快进）"

var ready := false
var title := ""
var subtitle := ""
var opening_heading := ""
var opening_body := ""
var opening_hint := ""

var acts: Array = []             # 原始数据，按顺序
var steps: Array = []            # 教学步骤 [{ id, act, text, seconds, done }]
var flags := {}                  # 剧情自己的旗标（和数据里的 flag 触发条件配对）
var head := -1                   # 演到第几幕的下标；-1 = 还没开始（标题卡阶段）
var objective := ""              # 当前这一幕给玩家的一句话目标
var ending_ready := false        # 后果里出现了 "ending" —— 场景层该摊开结算页了
var messages: Array = []         # 本次 tick 要弹出来的消息，场景层取走后清空

var _beat_time := 0.0            # 已经连续抢风多少游戏秒（教学第三步要靠它）


func load_data(path := DATA_PATH) -> bool:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("剧本读不出来：" + path)
		return false
	title = str(d.get("title", ""))
	subtitle = str(d.get("subtitle", ""))
	var op: Dictionary = d.get("opening", {})
	opening_heading = str(op.get("heading", ""))
	opening_body = str(op.get("body", ""))
	opening_hint = str(op.get("hint", "按任意键开始"))
	acts = d.get("acts", [])
	steps.clear()
	for raw in d.get("tutorial", []):
		steps.append({
			"id": str(raw.get("id", "")),
			"act": str(raw.get("act", "")),
			"text": str(raw.get("text", "")),
			"seconds": float(raw.get("seconds", 5.0)),
			"done": false,
		})
	ready = acts.size() > 0
	return ready


# ------------------------------------------------------------ 演出

func tick(v: Voyage, delta: float) -> void:
	if not ready:
		return
	_update_steps(v, delta)
	# 一次只推进一幕：叙事顺序是设计的一部分
	var nxt := head + 1
	if nxt < acts.size() and _met(acts[nxt], v):
		_fire(nxt, v)
	_update_objective(v)


func _update_objective(v: Voyage) -> void:
	"""第二幕的抉择一旦做完（上过岸又回船，或者干脆绕过去），目标就换成返航。

	没有这一步的话第三幕的"回出发港"目标永远不会显示 —— 它只在**到港那一刻**
	触发，而玩家在到港之前根本不知道要回港。这是第一版想当然写错的地方。
	"""
	if not fired("act2") or fired("act3") or v.ashore:
		return
	if v.fired.has("landed") or v.fired.has("passed_by"):
		objective = RETURN_OBJECTIVE


func note(action: String) -> void:
	"""玩家做了一件只有界面才知道的事（打开帆态面板…）。"""
	for s in steps:
		if str(s["id"]) == action:
			s["done"] = true


func current_act() -> Dictionary:
	return acts[head] if head >= 0 and head < acts.size() else {}


func act_name() -> String:
	return str(current_act().get("name", ""))


func act_text() -> String:
	return str(current_act().get("text", ""))


func fired(act_id: String) -> bool:
	for i in range(head + 1):
		if str(acts[i].get("id", "")) == act_id:
			return true
	return false


func take_messages() -> Array:
	var out := messages.duplicate()
	messages.clear()
	return out


func visible_steps() -> Array:
	"""当前这一幕的教学步骤 + 之前还没做完的（做完的老步骤不再占地方）。"""
	var out := []
	var cur := str(current_act().get("id", ""))
	for s in steps:
		var act_id := str(s["act"])
		if _act_index(act_id) < 0 or _act_index(act_id) > head:
			continue
		if bool(s["done"]) and act_id != cur:
			continue
		out.append(s)
	return out


func describe() -> String:
	return "%s（第 %d/%d 幕）目标：%s" % [
		act_name(), head + 1, acts.size(), objective if objective != "" else "——"]


# ------------------------------------------------------------ 触发

func _met(act: Dictionary, v: Voyage) -> bool:
	var tr: Dictionary = act.get("trigger", {})
	match str(tr.get("kind", "")):
		"start":
			return true
		"flag":
			return _flag_set(str(tr.get("flag", "")), v)
		"elapsed":
			return v.t >= float(tr.get("seconds", 0.0))
		"returned_home":
			# 见过岛之后，再把船开回出发港 —— 这就是"返航结算"的触发条件
			if not v.island_known:
				return false
			var port: Dictionary = v.sea.port()
			var p: Array = port.get("pos", [0, 0])
			var reach := float(port.get("radius_m", 0.0)) + float(tr.get("radius_m", 0.0))
			return v.ship.position_m().distance_to(
				Vector2(float(p[0]), float(p[1]))) <= reach
	return false


func _flag_set(name: String, v: Voyage) -> bool:
	if name == "island_known":
		return v.island_known
	if flags.has(name):
		return bool(flags[name])
	return v.fired.has(name)


func _fire(i: int, v: Voyage) -> void:
	head = i
	var act: Dictionary = acts[i]
	objective = str(act.get("objective", ""))
	# 幕落下来的时候，正文自己进航海日志（文书记的就是这些）
	v.journal.record(v.t, "act", "%s：%s" % [str(act.get("name", "")), str(act.get("text", ""))])
	for e in act.get("effects", []):
		_apply(e, v)


func _apply(e: Variant, v: Voyage) -> void:
	if typeof(e) != TYPE_DICTIONARY:
		return
	var d: Dictionary = e
	match str(d.get("kind", "")):
		"journal":
			v.journal.record(v.t, "story", str(d.get("text", "")))
		"last_line":
			v.journal.set_last_line(str(d.get("text", "")))
		"message":
			messages.append(str(d.get("text", "")))
		"flag":
			flags[str(d.get("name", ""))] = d.get("value", true)
		"objective":
			objective = str(d.get("text", ""))
		"ending":
			ending_ready = true
		_:
			push_warning("剧本里有个看不懂的后果：" + str(d.get("kind", "")))


# ------------------------------------------------------------ 教学

func _update_steps(v: Voyage, delta: float) -> void:
	if v.nav != null and v.nav.method == Navigator.Method.BEAT:
		_beat_time += delta
	else:
		_beat_time = 0.0
	for s in steps:
		if bool(s["done"]):
			continue
		var act_id := str(s["act"])
		if _act_index(act_id) < 0 or _act_index(act_id) > head:
			continue
		match str(s["id"]):
			"click_target":
				s["done"] = v.orders.has_target_point
			"open_sail_panel":
				pass                                  # 只能由 note() 完成
			"tack":
				s["done"] = _beat_time >= float(s["seconds"])
			"land":
				s["done"] = v.ashore or v.fired.has("landed")
			_:
				pass


func _act_index(act_id: String) -> int:
	for i in acts.size():
		if str(acts[i].get("id", "")) == act_id:
			return i
	return -1


# ------------------------------------------------------------ 存档（docs/14）
# 存的是"演到哪儿了"：第几幕、当前目标、旗标、教学做到第几步、抢风累计秒数。
# 剧本正文（acts / opening / title）是静态数据，读档时重新 load_data()，不进存档。
# messages 是"这一帧要弹的消息"，每帧都会被取走，属于瞬时量，不存。

func capture_state() -> Dictionary:
	var done := {}
	for s in steps:
		done[str(s["id"])] = bool(s["done"])
	return {
		"head": head,
		"objective": objective,
		"ending_ready": ending_ready,
		"flags": flags.duplicate(),
		"steps_done": done,
		"_beat_time": _beat_time,
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	head = int(d.get("head", -1))
	objective = str(d.get("objective", ""))
	ending_ready = bool(d.get("ending_ready", false))
	flags = (d.get("flags", {}) as Dictionary).duplicate()
	_beat_time = float(d.get("_beat_time", 0.0))
	var done: Dictionary = d.get("steps_done", {})
	for s in steps:
		var sid := str(s["id"])
		s["done"] = bool(done.get(sid, false))
	messages.clear()
