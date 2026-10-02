class_name LandingParty
extends RefCounted

# 登陆队（Day 6 试玩后重做）：
#   * 一个接一个下船（每条小船一趟，间隔 despatch_interval 秒）
#   * 上岸后每个人是**独立的点**，自动跟成一个队形（船长身后两列）
#   * 回船时同样是一个一个上船
#
# 之前是一簇装饰性的点：一次性"瞬移"上岸、永远抱成一团。
# 用户的原话：船员必须从船上一个一个走下来，下来后也要保持单独的点的形态，自动地保持一个队形。

const ROW_GAP := 2.4          # 队形：前后间距（米）
const COL_GAP := 1.7          # 队形：左右间距（米）
const WALK_SPEED := 12.0      # 岸上走路（米/秒）——比真人快，否则玩家要等很久
const ROW_SPEED := 18.0       # 从船划到岸上（米/秒）
const ROW_INTERVAL := 1.3     # 秒/人：一条小船一趟，一个一个来
const FOLLOW_SLACK := 1.2     # 站进队形就算到位（米）

var entries: Array = []       # [{crew: CrewMember|null, name, key, pos, state}]
var shore := Vector2.ZERO     # 下船点（船旁边最近的那段岸）
var ship_pos := Vector2.ZERO
var captain := Vector2.ZERO   # 船长（玩家的化身）
var captain_target := Vector2.ZERO
var facing := Vector2.RIGHT   # 队伍朝向（= 船长走的方向）
var boarding := false         # 回船中

var _next_to_go := 0          # 下一个下船的人的序号
var _timer := 0.0
var t := 0.0                  # 队伍自己的计时（用来验证"一个一个"）
var ashore_times: Array = []  # 每个人到达岸上的时刻


func start(crew_list: Array, p_shore: Vector2, p_ship: Vector2, hands: int) -> void:
	"""组队。船长先上岸，船员按名单顺序一个一个跟下来。"""
	entries.clear()
	shore = p_shore
	ship_pos = p_ship
	captain = p_shore
	captain_target = p_shore
	boarding = false
	_next_to_go = 0
	_timer = ROW_INTERVAL * 0.5
	for c in crew_list:
		entries.append({
			"crew": c, "name": c.label(), "key": true,
			"pos": p_ship, "state": "onboard",
		})
	for i in hands:
		entries.append({
			"crew": null, "name": "水手 #%d" % (i + 1), "key": false,
			"pos": p_ship, "state": "onboard",
		})


func tick(delta: float) -> void:
	if entries.is_empty():
		return
	t += delta
	if boarding:
		_tick_boarding(delta)
	else:
		_tick_disembark(delta)
	_tick_formation(delta)


func _tick_disembark(delta: float) -> void:
	_timer -= delta
	if _next_to_go < entries.size() and _timer <= 0.0:
		entries[_next_to_go]["state"] = "rowing"
		_next_to_go += 1
		_timer = ROW_INTERVAL
	for e in entries:
		if e["state"] != "rowing":
			continue
		var landing := shore_slot(entries.find(e))
		e["pos"] = _advance(e["pos"], landing, ROW_SPEED * delta)
		if (e["pos"] as Vector2).distance_to(landing) < 0.6:
			e["state"] = "ashore"
			ashore_times.append(t)


func _tick_boarding(delta: float) -> void:
	# 一个一个回到船上：靠岸最近的先上
	var remaining := []
	for e in entries:
		if e["state"] == "onboard":
			continue
		if e["state"] == "dead":
			continue          # 阵亡的留在岸上：不能让他自己走回小船（详见 count_lost）
		remaining.append(e)
	remaining.sort_custom(func(a, b):
		return (a["pos"] as Vector2).distance_to(shore) < (b["pos"] as Vector2).distance_to(shore))
	if remaining.is_empty():
		boarding = false
		return
	_timer -= delta
	if _timer <= 0.0:
		var e: Dictionary = remaining[0]
		e["state"] = "onboard"
		e["pos"] = ship_pos
		_timer = ROW_INTERVAL


func _tick_formation(delta: float) -> void:
	# 已经在岸上的人：向自己的队形位走（船长动，队形跟着动）
	var ashore_list := []
	for e in entries:
		if e["state"] == "ashore":
			ashore_list.append(e)
	if ashore_list.is_empty():
		return
	var d := captain_target - captain
	if d.length() > 1.0:
		facing = d.normalized()
		captain = _advance(captain, captain_target, WALK_SPEED * delta)
	for i in entries.size():
		var e: Dictionary = entries[i]
		if e["state"] != "ashore":
			continue
		var slot := formation_slot(i)
		e["pos"] = _advance(e["pos"], slot, WALK_SPEED * delta)


func _advance(pos: Vector2, target: Vector2, step: float) -> Vector2:
	var d := target - pos
	if d.length() <= step:
		return target
	return pos + d.normalized() * step


func formation_slot(i: int) -> Vector2:
	"""队形：船长打头，后面两列纵队（i=0 是船长本人）。"""
	if i <= 0:
		return captain
	var row := int((i + 1) / 2)
	var side := 1.0 if i % 2 == 1 else -1.0
	var back := -facing
	var right := Vector2(-back.y, back.x)
	return captain + back * (float(row) * ROW_GAP) + right * (side * COL_GAP)


func shore_slot(i: int) -> Vector2:
	"""刚下船时站的位置：沿沙滩排开，免得全挤在一个点上。"""
	var n := maxi(entries.size(), 1)
	var t := (float(i) / float(n) - 0.5) * 2.0      # -1..1
	var tangent := Vector2(-( shore - captain ).normalized().y, (shore - captain).normalized().x)
	if tangent.length() < 0.5:
		tangent = Vector2(0, 1)
	return shore + tangent * (t * COL_GAP * 1.6)


func move_to(pos: Vector2) -> void:
	captain_target = pos


func count_ashore() -> int:
	var n := 0
	for e in entries:
		if e["state"] == "ashore":
			n += 1
	return n


func count_lost() -> int:
	"""阵亡、留在岸上的人（M6 收尾：战斗结果写回队形之后，他们不该再挡着"收工上船"）。"""
	var n := 0
	for e in entries:
		if e["state"] == "dead":
			n += 1
	return n


func count_onboard() -> int:
	var n := 0
	for e in entries:
		if e["state"] == "onboard":
			n += 1
	return n


func boarded_all() -> bool:
	return entries.is_empty() or count_onboard() + count_lost() == entries.size()


func all_ashore() -> bool:
	return count_ashore() == entries.size()


func begin_boarding() -> void:
	boarding = true
	_timer = 0.0


func size() -> int:
	return entries.size() + 1        # 加上船长


func describe() -> String:
	var lost := count_lost()
	var base := "队伍 %d 人（岸上 %d、还在船上 %d" % [size(), count_ashore(), count_onboard()]
	return base + ("、阵亡 %d）" % lost if lost > 0 else "）")


# ------------------------------------------------------------ 存档（docs/14）
# entries 里的 crew 是 CrewMember 引用 —— 存档里换成 id（null 表示普通水手），
# 回填时再从名册里按 id 找回来。找不到就当成普通水手（宁可丢一个人，不要崩）。

func capture_state() -> Dictionary:
	var out := []
	for e in entries:
		var c = e.get("crew", null)
		out.append({
			"crew_id": (c.id if c != null else ""),
			"name": str(e.get("name", "")),
			"key": bool(e.get("key", false)),
			"pos": StateIO.v2(e.get("pos", Vector2.ZERO)),
			"state": str(e.get("state", "onboard")),
		})
	return {
		"entries": out,
		"shore": StateIO.v2(shore),
		"ship_pos": StateIO.v2(ship_pos),
		"captain": StateIO.v2(captain),
		"captain_target": StateIO.v2(captain_target),
		"facing": StateIO.v2(facing),
		"boarding": boarding,
		"_next_to_go": _next_to_go,
		"_timer": _timer,
		"t": t,
		"ashore_times": ashore_times.duplicate(),
	}


func apply_state(d: Dictionary, roster: CrewRoster = null) -> void:
	if d.is_empty():
		return
	shore = StateIO.to_v2(d.get("shore", [0.0, 0.0]))
	ship_pos = StateIO.to_v2(d.get("ship_pos", [0.0, 0.0]))
	captain = StateIO.to_v2(d.get("captain", [0.0, 0.0]))
	captain_target = StateIO.to_v2(d.get("captain_target", [0.0, 0.0]))
	facing = StateIO.to_v2(d.get("facing", [1.0, 0.0]))
	boarding = bool(d.get("boarding", false))
	_next_to_go = int(d.get("_next_to_go", 0))
	_timer = float(d.get("_timer", 0.0))
	t = float(d.get("t", 0.0))
	ashore_times = (d.get("ashore_times", []) as Array).duplicate()
	var by_id := {}
	if roster != null:
		for m in roster.members:
			by_id[m.id] = m
	entries.clear()
	var raw_list: Array = d.get("entries", [])
	for raw in raw_list:
		var cid := str(raw.get("crew_id", ""))
		entries.append({
			"crew": (by_id.get(cid) if by_id.has(cid) else null),
			"name": str(raw.get("name", "")),
			"key": bool(raw.get("key", false)),
			"pos": StateIO.to_v2(raw.get("pos", [0.0, 0.0])),
			"state": str(raw.get("state", "onboard")),
		})
