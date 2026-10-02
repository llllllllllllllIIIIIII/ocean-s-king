class_name Pursuit
extends RefCounted

# 葡萄牙追捕（M11）：六环状态机 —— 被发现 → 被跟踪 → 被警告 → 被驱逐 → 被拦截 → 被攻击。
#
# 三条设计（docs/22 第 9 章、docs/23 的 M11 硬指标）：
#   1. **每一环都要能进、也要能出**：进下一环的条件是"在葡萄牙水域里待够 N 天"，
#      甩掉的条件是"离开水域够 escape_days 天"。两个条件都是数，都可断言。
#   2. **玩家有四种手段**：改线 / 伪装 / 谈判 / 战斗 —— 前三种各退几环、各要付什么，
#      全在真源里；"战斗"返回 `battle = true`，交给 `NavalBattle`。
#   3. **追捕是世界状态**：它进 `WorldState`（房主权威），因为"世界对我们做了什么"
#      对所有人必须是同一件事。

const DEFS_PATH := "res://data/defs/factions.json"

static var _defs_cache: Dictionary = {}


static func defs() -> Dictionary:
	if _defs_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DEFS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_defs_cache = d
		else:
			push_error("追捕表读不出来：" + DEFS_PATH)
	return _defs_cache


static func config() -> Dictionary:
	return defs().get("pursuit", {})


static func rings() -> Array:
	return config().get("rings", [])


static func ring_count() -> int:
	return rings().size()


static func ring_id(i: int) -> String:
	var rs := rings()
	if i <= 0 or i > rs.size():
		return ""
	return str((rs[i - 1] as Dictionary).get("id", ""))


static func ring_name(i: int) -> String:
	var rs := rings()
	if i <= 0 or i > rs.size():
		return "没被盯上"
	return str((rs[i - 1] as Dictionary).get("name", ring_id(i)))


static func actions() -> Dictionary:
	return config().get("actions", {})


static func waters() -> Array:
	return config().get("waters", [])


static func water_radius_m() -> float:
	return float(config().get("water_radius_m", 14000.0))


static func outposts() -> Array:
	"""葡萄牙在东方的据点（M14）：`mozambique` / `malacca` / `tidore`。"""
	return defs().get("outposts", [])


static func outpost_for(port_id: String) -> Dictionary:
	for o in outposts():
		if str((o as Dictionary).get("port", "")) == port_id:
			return o
	return {}


static func permit_days() -> float:
	return float(config().get("permit_days", 30.0))


# ------------------------------------------------------------ 实例状态（进 WorldState）

var ring := 0                  # 0 = 没被盯上；1..6 = 六环
var days_in_ring := 0.0        # 在这一环里待了多久（在葡萄牙水域里的日子）
var days_out := 0.0            # 离开水域多久（够 escape_days 就甩掉）
var last_event := ""
var times_escaped := 0
var times_attacked := 0
var permit_days_left := 0.0    # 通行许可还剩几天（M14，> 0 时巡逻不拦、环数不推进）


func setup() -> void:
	ring = 0
	days_in_ring = 0.0
	days_out = 0.0
	last_event = ""
	times_escaped = 0
	times_attacked = 0
	permit_days_left = 0.0


func active() -> bool:
	return ring > 0


func has_permit() -> bool:
	return permit_days_left > 0.0


func grant_permit() -> float:
	"""买下一张通行许可（M14）。返回给了多少天。"""
	permit_days_left = Pursuit.permit_days()
	last_event = "permit"
	return permit_days_left


func describe() -> String:
	if ring <= 0:
		return "没被盯上" if not has_permit() \
			else "没被盯上（通行许可还剩 %.0f 天）" % permit_days_left
	return "%s（第 %d 天%s）" % [Pursuit.ring_name(ring), int(days_in_ring),
		"，通行许可还剩 %.0f 天" % permit_days_left if has_permit() else ""]


func tick(days: float, in_waters: bool) -> Dictionary:
	"""推进：**只看"在不在葡萄牙水域里"**（与世界记忆、态度无关 —— 那些改的是别的东西）。"""
	var ev := {"ring": ring, "advanced": false, "escaped": false, "entered": false}
	# M14：通行许可还没到期 —— 巡逻当没看见你：环不推进，已经在追的也会慢慢松掉
	if has_permit():
		permit_days_left = maxf(0.0, permit_days_left - days)
		if ring > 0:
			days_out += days
			if days_out >= float(config().get("escape_days", 3.0)):
				ring = 0
				days_in_ring = 0.0
				days_out = 0.0
				times_escaped += 1
				last_event = "permit_clear"
				ev["escaped"] = true
		ev["ring"] = ring
		ev["permit_days_left"] = permit_days_left
		return ev
	# "进水域"这件事不花时间：被看见就是被看见（所以 0 天也要能进第一环）
	if ring == 0:
		if not in_waters:
			return ev
		ring = 1
		days_in_ring = 0.0
		days_out = 0.0
		last_event = Pursuit.ring_id(1)
		ev["ring"] = ring
		ev["advanced"] = true
		ev["entered"] = true
		return ev
	if days <= 0.0:
		return ev
	if not in_waters:
		days_out += days
		if days_out >= float(config().get("escape_days", 3.0)):
			ring = 0
			days_in_ring = 0.0
			days_out = 0.0
			times_escaped += 1
			last_event = "escaped"
			ev["escaped"] = true
		ev["ring"] = ring
		return ev
	days_out = 0.0
	days_in_ring += days
	var nxt := ring + 1
	if nxt <= Pursuit.ring_count():
		# `after_days` 读的是**当前这一环**的：在这一环里待够这么多天才进下一环
		var need := float((Pursuit.rings()[ring - 1] as Dictionary).get("after_days", 1.0))
		if need <= 0.0:
			need = 0.0
		if days_in_ring >= need:
			ring = nxt
			days_in_ring = 0.0
			last_event = Pursuit.ring_id(ring)
			ev["advanced"] = true
			if ring == Pursuit.ring_count():
				times_attacked += 1
	ev["ring"] = ring
	return ev


func act(action: String, cargo: Cargo) -> Dictionary:
	"""玩家的手段。付不起代价就不生效（一点不扣）。"""
	var a: Dictionary = actions().get(action, {})
	if a.is_empty():
		return {"ok": false, "reason": "没有这个手段"}
	if ring <= 0 and action != "fight":
		return {"ok": false, "reason": "现在没人在追你"}
	var cost: Dictionary = a.get("cost", {})
	if cargo == null and not cost.is_empty():
		return {"ok": false, "reason": "没有货舱，付不起"}
	if not cost.is_empty():
		# ⚠️ 金币不是货：`ducats` 走 `Cargo.money`（用 Cargo.pay 那一个入口）
		var c := cargo.can_pay(cost)
		if not bool(c["ok"]):
			return {"ok": false, "reason": "付不起：" + ", ".join(c["lack"])}
		if not cargo.pay(cost):
			return {"ok": false, "reason": "付不起"}
	var before := ring
	ring = clampi(ring + int(a.get("ring_delta", 0)), 0, Pursuit.ring_count())
	days_in_ring = 0.0
	last_event = action
	return {
		"ok": true, "before": before, "ring": ring,
		"name": Pursuit.ring_name(ring),
		"battle": bool(a.get("battle", false)),
		"text": str(a.get("text", "")),
		"days": float(a.get("days", 0.0)),
	}


# ------------------------------------------------------------ 存档契约

func capture_state() -> Dictionary:
	return {
		"ring": ring, "days_in_ring": days_in_ring, "days_out": days_out,
		"last_event": last_event, "times_escaped": times_escaped,
		"times_attacked": times_attacked,
		"permit_days_left": permit_days_left,
	}


func apply_state(d: Dictionary) -> void:
	ring = int(d.get("ring", 0))
	days_in_ring = float(d.get("days_in_ring", 0.0))
	days_out = float(d.get("days_out", 0.0))
	last_event = str(d.get("last_event", ""))
	times_escaped = int(d.get("times_escaped", 0))
	times_attacked = int(d.get("times_attacked", 0))
	permit_days_left = float(d.get("permit_days_left", 0.0))
