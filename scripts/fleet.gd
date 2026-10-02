class_name Fleet
extends RefCounted

# 船队（M3）：世界里固定 4 艘远征船，**每台机器只细化自己那一条**。
#
# 一个船位在上面是什么样，取决于谁在开它：
#
#   kind = "local"   —— 本机细化：气动积分 + 40 人逐人名册（在 Voyage 里，不在这里）
#   kind = "ai"      —— 房主跑的抽象船：只有摘要，朝目标走（AbstractShip.step）
#   kind = "remote"  —— 别人的船：只收 20Hz 的摘要，**100ms 插值**后画出来，不做外推
#
# 三条规矩（docs/13 第 5.1 节、docs/14 第 5 节）：
#   1. 别人的船**没有**逐人细节，所以不许进入别人的船的内部视图；
#   2. 掉线的船**不消失**：房主把它转成 AI 船继续走（detach_player）；
#   3. 中途加入 = 抽象船升为细化（attach_player）：沿用同一份船员数据集，
#      并继承抽象数值（船体% / 人数 / 位置 / 艏向）。

const DATA_PATH := "res://data/defs/fleet.json"
const INTERP_DELAY := 0.1           # 远端船插值延迟（秒）—— 不外推
const BUF_KEEP := 0.6               # 插值缓冲保留多久

const KIND_LOCAL := "local"
const KIND_AI := "ai"
const KIND_REMOTE := "remote"
const ARRIVE_RADIUS_M := 900.0       # 进入这个圈就算"抵达终点"（和结算页同一把尺子）

var slots: Array = []               # [{id, name, captain, kind, owner_peer, owner_name, ship}]
var local_id := ""
var wrap_width := 0.0               # 圆柱世界（M12）：远端船的插值也要走最短的一边
var t := 0.0                        # 本机的真实时间（插值用真实时间，不用游戏时间）
# 客户端：AI 船的动态**只从房主发出**，本机不自己推它们，只照摘要插值
var mirror_world := false
var _buf: Dictionary = {}           # id -> [{t, pos, heading, ...}]
var _local_summary: Dictionary = {} # 本机那条船的摘要（由 Voyage 每帧灌进来）
var goal := Vector2.ZERO            # 这一程的终点港（抵达判定用它）
var arrived: Dictionary = {}        # id -> true（**抵达是个闩**：到过一次就一直算到过）
var _left_goal: Dictionary = {}     # id -> true（先离开过终点圈，回来才算"抵达"）
# M16：轻编队与旗舰
var formation := "free"             # free / follow_near / follow_mid / follow_far / hold
var flagship := ""                  # 旗舰（默认从 fleet.json 的 flagship: true 读）
var lost := {}                      # id -> {name, day, reason, summary}（沉掉的船）
var _held := {}                     # id -> Vector2（"保持阵位"那一刻记下的相对位置）
static var _formation_defs: Dictionary = {}


func setup(path := DATA_PATH) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("船队数据读不出来：" + path)
		return
	slots.clear()
	for raw in d.get("ships", []):
		slots.append({
			"id": str(raw.get("id", "")),
			"name": str(raw.get("name", "")),
			"captain": str(raw.get("captain", "")),
			"flagship": bool(raw.get("flagship", false)),
			"kind": KIND_AI,
			"owner_peer": 0,
			"owner_name": "",
			"ship": null,
		})
	_formation_defs = d.get("formations", {})
	formation = "free"
	lost.clear()
	_held.clear()
	for raw in d.get("ships", []):
		if bool(raw.get("flagship", false)):
			flagship = str(raw.get("id", ""))
	if flagship == "" and slots.size() > 0:
		flagship = str(slots[0]["id"])


# ------------------------------------------------------------ 轻编队（M16）

static func formation_def(mode: String) -> Dictionary:
	return _formation_defs.get(mode, {}) as Dictionary


static func formation_ids() -> Array:
	return _formation_defs.keys()


static func formation_name_of(mode: String) -> String:
	var f := formation_def(mode)
	return str(f.get("name", mode))


func formation_name() -> String:
	"""当前这条编队指令的名字（面板与消息条读它）。"""
	return formation_name_of(formation)


func set_formation(mode: String) -> bool:
	"""下达编队指令。`hold` 会把**此刻**的相对阵位记下来（之后就一直保持它）。

	返回 false = 不认识这条指令（前端别把状态改了）。
	"""
	if formation_def(mode).is_empty():
		return false
	formation = mode
	_held.clear()
	if mode == "hold" and flagship != "" and not lost.has(flagship):
		var lead := pose_of(flagship)
		for s in slots:
			var id := str(s["id"])
			if id == flagship:
				continue
			_held[id] = pose_of(id) - lead
	return true


func formation_offset(id: String, index: int) -> Vector2:
	"""这条船相对旗舰该在哪儿（旗舰艏向的局部坐标）。"""
	if formation == "free":
		return Vector2.ZERO
	if formation == "hold":
		return _held.get(id, Vector2.ZERO)
	var f := formation_def(formation)
	# 正后方 = 旗舰艏向的反方向；左右按序号分开（0 就在正后方）
	var astern := float(f.get("astern_m", 0.0))
	var abeam := float(f.get("abeam_m", 0.0)) * float(index)
	return Vector2(-astern, abeam)


func formation_target(id: String, index: int, lead: Vector2, lead_heading: float) -> Vector2:
	"""阵位点（世界坐标）。`hold` 用的是下达命令那一刻记下的**世界**相对位置，不跟着转。"""
	if formation == "hold":
		return lead + (_held.get(id, Vector2.ZERO) as Vector2)
	return lead + formation_offset(id, index).rotated(deg_to_rad(lead_heading))


func alive_ids() -> Array:
	var out := []
	for s in slots:
		out.append(str(s["id"]))
	return out


func nearest_alive(pos: Vector2) -> String:
	"""最近的一条**没人开的**船（M16 沉船接手只能拿没人开的 —— 别人的船不能抢）。"""
	var best := ""
	var best_d := INF
	for s in slots:
		if int(s.get("owner_peer", 0)) != 0 or str(s.get("kind", "")) != KIND_AI:
			continue
		var id := str(s["id"])
		var d := pose_of(id).distance_to(pos)
		if d < best_d:
			best_d = d
			best = id
	return best


func assign(id: String, peer: int, owner_name := "") -> bool:
	"""把一条船判给某个人开（M16 的旗舰转移 / 沉船接手）。

	房主广播这条判定（`NetProtocol.ASSIGN`），各机器照它改自己那份船位归属 ——
	于是"两边看到的是同一个人开着同一条船"。
	"""
	var s := slot_of(id)
	if s.is_empty():
		return false
	s["owner_peer"] = peer
	s["owner_name"] = owner_name
	if peer != 0:
		s["kind"] = KIND_REMOTE if peer != 1 else KIND_LOCAL
	elif s["ship"] == null:
		s["kind"] = KIND_AI
	return true


func sink(id: String, day := 0, reason := "沉没") -> Dictionary:
	"""一条船没了（M16）：记下来、从船位里移走；要是沉的正好是旗舰，就换一条当旗舰。

	返回那条船的记录（进航海日志与结算）。
	"""
	var s := slot_of(id)
	if s.is_empty():
		return {}
	var rec := {
		"id": id, "name": str(s.get("name", id)), "day": day, "reason": reason,
		"summary": summary_of(id),
		"was_flagship": id == flagship,
	}
	lost[id] = rec
	arrived.erase(id)
	_left_goal.erase(id)
	_buf.erase(id)
	slots = slots.filter(func(x): return str((x as Dictionary)["id"]) != id)
	if id == flagship:
		flagship = str(slots[0]["id"]) if slots.size() > 0 else ""
	return rec


func flagship_name() -> String:
	return name_of(flagship) if flagship != "" else "—"


func slot_of(id: String) -> Dictionary:
	for s in slots:
		if str(s["id"]) == id:
			return s
	return {}


func slot_of_peer(peer: int) -> Dictionary:
	if peer == 0:
		return {}
	for s in slots:
		if int(s["owner_peer"]) == peer:
			return s
	return {}


func peer_of(id: String) -> int:
	"""这条船归哪个 peer（0 = 没人开 / AI）。联机转"这一炮打给谁"要用它。"""
	for s in slots:
		if str(s["id"]) == id:
			return int(s["owner_peer"])
	return 0


func ids() -> Array:
	var out := []
	for s in slots:
		out.append(str(s["id"]))
	return out


func ids_of_kind(kind: String) -> Array:
	var out := []
	for s in slots:
		if str(s["kind"]) == kind:
			out.append(str(s["id"]))
	return out


func free_ids() -> Array:
	"""还没有主人的船位（加入房间时挑一个）。"""
	var out := []
	for s in slots:
		if str(s["kind"]) == KIND_AI and int(s["owner_peer"]) == 0:
			out.append(str(s["id"]))
	return out


func count() -> int:
	return slots.size()


# ------------------------------------------------------------ 船位的归属变化

func claim_local(id: String) -> void:
	"""本机细化这条船：它的运行时在 Voyage 里，这里只记身份。"""
	var s := slot_of(id)
	if s.is_empty():
		return
	local_id = id
	s["kind"] = KIND_LOCAL
	s["owner_peer"] = 1
	s["owner_name"] = "我"
	s["ship"] = null


func attach_player(id: String, peer: int, owner_name := "") -> Dictionary:
	"""抽象 → 细化：某个人接手这条船（房主调用；接手的那台机器自己 claim_local）。

	返回被接手那条船的**摘要**，接手方照它把新船生出来（船体% / 人数 / 位置 / 艏向）。
	"""
	var s := slot_of(id)
	if s.is_empty():
		return {}
	var summary := summary_of(id)
	s["kind"] = KIND_REMOTE
	s["owner_peer"] = peer
	s["owner_name"] = owner_name
	_buf[id] = []
	if s["ship"] == null:
		var a := AbstractShip.new()
		a.apply_summary(summary)
		s["ship"] = a
	return summary


func detach_player(id: String, target := Vector2.ZERO) -> void:
	"""掉线/离开：**这条船不消失**，就地转成 AI 继续走（房主的活）。

	目标点特意留了个参数：房主知道船队这一程往哪儿去，就把那儿的坐标传进来，
	没人开的那条船会自己跟上去；不传的话它就照着当前艏向继续往前 ——
	总之不会在海上停下来（"掉线 = 船停了"是最容易写出的错）。
	"""
	var s := slot_of(id)
	if s.is_empty():
		return
	var summary := summary_of(id)
	var a := AbstractShip.new()
	a.apply_summary(summary)
	var ahead := target
	if ahead == Vector2.ZERO:
		ahead = a.pos + Vector2(cos(deg_to_rad(a.heading_deg)), sin(deg_to_rad(a.heading_deg))) * 40000.0
	a.target = ahead
	a.has_target = not a.anchored
	s["ship"] = a
	s["kind"] = KIND_AI
	s["owner_peer"] = 0
	s["owner_name"] = ""
	_buf[id] = []


func set_ai_target(id: String, target: Vector2) -> void:
	var s := slot_of(id)
	if s.is_empty() or s["ship"] == null:
		return
	(s["ship"] as AbstractShip).target = target
	(s["ship"] as AbstractShip).has_target = true


func set_ai_waypoints(id: String, points: Array) -> void:
	var s := slot_of(id)
	if s.is_empty() or s["ship"] == null:
		return
	var a := s["ship"] as AbstractShip
	a.waypoints = points.duplicate()
	a.has_target = not points.is_empty()


func place_ai(id: String, pos: Vector2, heading := 90.0) -> void:
	"""把一条 AI 船摆到某处（测试与"接管/交还"时用）。"""
	var s := slot_of(id)
	if s.is_empty() or s["ship"] == null:
		return
	var a := s["ship"] as AbstractShip
	a.pos = pos
	a.heading_deg = heading
	a.waypoints = []
	a.has_target = false
	a.speed_ms = 0.0
	a.action = "抵达待命"


# ------------------------------------------------------------ 每帧

func advance_clock(real_delta: float) -> void:
	"""插值用的是**真实时间**：游戏里的 ×36 是快进，网络与插值不该跟着快进 36 倍。"""
	t += real_delta


func step_game(delta: float, sea: Sea) -> void:
	"""一步游戏时间：AI 船往前走，远端船按真实时间轴插值出新位姿。"""
	# M16：**轻编队** —— 有指令时，AI 船的目标点由"相对旗舰的阵位"决定
	# （指令是共享约定，执行在各机器上：这里就是房主/单机这一侧的执行）。
	if formation != "free" and flagship != "" and not lost.has(flagship):
		var lead := pose_of(flagship)
		var lead_h := heading_of(flagship)
		var idx := 0
		for s in slots:
			var sid := str(s["id"])
			if sid == flagship:
				continue
			idx += 1
			if str(s["kind"]) != KIND_AI or s["ship"] == null or mirror_world:
				continue
			var tgt := formation_target(sid, idx, lead, lead_h)
			# **别把阵位点摆到干地上**（否则那条船会一头顶住岸）：先收一半，再退到旗舰处
			if sea.is_dry_land(tgt):
				tgt = lead + (tgt - lead) * 0.5
			if sea.is_dry_land(tgt):
				tgt = lead
			var ai := s["ship"] as AbstractShip
			ai.waypoints = []
			ai.target = tgt
			ai.has_target = true
	for s in slots:
		match str(s["kind"]):
			KIND_AI:
				if mirror_world:
					_sample_remote(s)
				elif s["ship"] != null:
					(s["ship"] as AbstractShip).step(delta, sea)
			KIND_REMOTE:
				_sample_remote(s)
			_:
				pass                      # 本机那条由 Voyage 的细化运行时推进
	# 抵达判定：AI 与远端都算（本机那条由 Voyage 自己灌摘要，位置一样从这里读）
	if goal != Vector2.ZERO:
		for s in slots:
			var id := str(s["id"])
			if arrived.has(id):
				continue
			var p := pose_of(id)
			if p == Vector2.ZERO:
				continue
			# 开局本来就停在出发港里 —— 得**先离开**再回来，才算"抵达"，
			# 不然第一帧就会宣布"全队抵达"（在只有一座港的迷你海域里尤其荒唐）
			if p.distance_to(goal) > ARRIVE_RADIUS_M:
				_left_goal[id] = true
			elif bool(_left_goal.get(id, false)):
				arrived[id] = true


func receive_summary(d: Dictionary) -> void:
	"""收到别人那条船的摘要（20Hz）。"""
	var id := str(d.get("id", ""))
	if id == "" or id == local_id:
		return
	var s := slot_of(id)
	if s.is_empty():
		return
	var p: Array = d.get("pos", [0.0, 0.0])
	var sample := {
		"t": t,
		"pos": Vector2(float(p[0]), float(p[1])),
		"heading": float(d.get("heading", 0.0)),
		"sail_level": int(d.get("sail_level", 0)),
		"anchored": bool(d.get("anchored", false)),
		"hull_pct": float(d.get("hull_pct", 1.0)),
		"crew_count": int(d.get("crew_count", 40)),
		"action": str(d.get("action", "")),
		"hold_kg": float(d.get("hold_kg", 0.0)),
		"money": int(d.get("money", 0)),
	}
	if not _buf.has(id):
		_buf[id] = []
	(_buf[id] as Array).append(sample)
	while (_buf[id] as Array).size() > 2 and t - float((_buf[id] as Array)[0]["t"]) > BUF_KEEP:
		(_buf[id] as Array).pop_front()
	_apply_sample(s, sample)


func _sample_remote(s: Dictionary) -> void:
	"""远端船：按 100ms 延迟在最近两个摘要之间插值（**不外推**）。

	不外推是刻意的：外推在丢包时会画出"船自己飞出去"，而且和权威状态越差越远；
	宁可让别人的船慢 100ms —— 反正你看不见他的舵。
	"""
	var id := str(s["id"])
	var buf: Array = _buf.get(id, [])
	if buf.is_empty():
		return
	var want := t - INTERP_DELAY
	if buf.size() == 1 or want <= float(buf[0]["t"]):
		_apply_sample(s, buf[0])
		return
	for i in range(buf.size() - 1):
		var a: Dictionary = buf[i]
		var b: Dictionary = buf[i + 1]
		if want >= float(a["t"]) and want <= float(b["t"]):
			var span := maxf(float(b["t"]) - float(a["t"]), 1e-6)
			var k := clampf((want - float(a["t"])) / span, 0.0, 1.0)
			var out: Dictionary = b.duplicate()
			out["pos"] = _lerp_pos(a["pos"] as Vector2, b["pos"] as Vector2, k)
			out["heading"] = _lerp_angle(float(a["heading"]), float(b["heading"]), k)
			_apply_sample(s, out)
			return
	_apply_sample(s, buf[buf.size() - 1])


static func _lerp_angle(a: float, b: float, k: float) -> float:
	return fposmod(a + ShipPhysics.normalize180(b - a) * k, 360.0)


func _lerp_pos(a: Vector2, b: Vector2, k: float) -> Vector2:
	"""两端之间插值。圆柱世界里走**最短的一边** ——
	否则别人跨接缝那一包会让他的船"横穿整张地图飞过去"（M12）。"""
	var d := b - a
	if wrap_width > 0.0:
		d.x = fposmod(d.x + wrap_width * 0.5, wrap_width) - wrap_width * 0.5
	var p := a + d * k
	if wrap_width > 0.0:
		p.x = fposmod(p.x, wrap_width)
	return p


func _apply_sample(s: Dictionary, sample: Dictionary) -> void:
	var a: AbstractShip = s["ship"] as AbstractShip
	if a == null:
		a = AbstractShip.new()
		a.id = str(s["id"])
		a.name = str(s["name"])
		s["ship"] = a
	a.pos = sample["pos"]
	a.heading_deg = float(sample["heading"])
	a.sail_level = int(sample["sail_level"])
	a.anchored = bool(sample["anchored"])
	a.hull_pct = float(sample["hull_pct"])
	a.crew_count = int(sample["crew_count"])
	a.action = str(sample["action"])
	a.hold_kg = float(sample.get("hold_kg", 0.0))
	a.money = int(sample.get("money", 0))


# ------------------------------------------------------------ 给视图与 UI 的读数

func pose_of(id: String) -> Vector2:
	var s := slot_of(id)
	if s.get("ship") != null:
		return (s["ship"] as AbstractShip).pos
	# 本机那条船的运行时在 Voyage 里（`s["ship"]` 是 null），位置从它灌进来的摘要读 ——
	# 少了这一步，本地船在船队这一层看起来永远停在原点（抵达判定就永远不成立）
	var p: Array = _local_summary.get("pos", [])
	return Vector2(float(p[0]), float(p[1])) if p.size() >= 2 else Vector2.ZERO


func heading_of(id: String) -> float:
	var s := slot_of(id)
	if s.get("ship") != null:
		return (s["ship"] as AbstractShip).heading_deg
	return float(_local_summary.get("heading", 0.0))


func summary_of(id: String) -> Dictionary:
	var s := slot_of(id)
	if s.is_empty():
		return {}
	if s["ship"] != null:
		return (s["ship"] as AbstractShip).to_summary()
	return _local_summary.duplicate() if str(s["id"]) == local_id else {}


func set_local_summary(d: Dictionary) -> void:
	_local_summary = d


func name_of(id: String) -> String:
	var s := slot_of(id)
	return str(s.get("name", id))


func owner_name_of(id: String) -> String:
	var s := slot_of(id)
	return str(s.get("owner_name", ""))


func owner_peer_of(id: String) -> int:
	var s := slot_of(id)
	return int(s.get("owner_peer", 0))


func kind_of(id: String) -> String:
	var s := slot_of(id)
	return str(s.get("kind", ""))


func others() -> Array:
	"""除本机以外的船（视图要画的）。"""
	var out := []
	for s in slots:
		if str(s["id"]) != local_id:
			out.append(str(s["id"]))
	return out


func remote_summaries() -> Array:
	"""除本机以外所有船的摘要（房主每 0.5 秒广播一次，客户端照它摆别人的船）。"""
	var out := []
	for id in others():
		var sm := summary_of(id)
		if not sm.is_empty():
			out.append(sm)
	return out


func describe() -> String:
	var parts := PackedStringArray()
	for s in slots:
		var mark := "★" if str(s["kind"]) == KIND_LOCAL else \
			("AI" if str(s["kind"]) == KIND_AI else str(s["owner_name"]))
		parts.append("%s %s" % [str(s["name"]), mark])
	return "　".join(parts)


func describe_short() -> String:
	"""HUD 用的一行：本机那条写名字，别人写名字（玩家名），AI 合并计数。"""
	var parts := PackedStringArray()
	var ai := 0
	for s in slots:
		match str(s["kind"]):
			KIND_LOCAL:
				parts.append("★" + str(s["name"]))
			KIND_AI:
				ai += 1
			_:
				parts.append("%s（%s）" % [str(s["name"]), str(s["owner_name"])])
	if ai > 0:
		parts.append("AI×%d" % ai)
	return "　".join(parts)


# ------------------------------------------------------------ 存档（docs/14 第 3 节）

func capture_state() -> Array:
	"""非本机的船位（AI 与远端）—— 本机那条由 Voyage 的细化存档负责。"""
	var out := []
	for s in slots:
		var id := str(s["id"])
		if id == local_id:
			continue
		var a: AbstractShip = s["ship"] as AbstractShip
		out.append({
			"id": id,
			"kind": "abstract",
			"owner_peer": int(s["owner_peer"]),
			"owner_name": str(s["owner_name"]),
			"fleet_kind": str(s["kind"]),
			"summary": a.capture_state() if a != null else {},
			"arrived": bool(arrived.has(id)),
		})
	return out


func apply_state(arr: Array) -> void:
	for raw in arr:
		var d: Dictionary = raw
		var id := str(d.get("id", ""))
		var s := slot_of(id)
		if s.is_empty() or id == local_id:
			continue
		var a := AbstractShip.new()
		a.id = id
		a.name = str(s["name"])
		a.apply_state(d.get("summary", {}))
		s["ship"] = a
		var fk := str(d.get("fleet_kind", KIND_AI))
		s["kind"] = KIND_REMOTE if fk == KIND_REMOTE else KIND_AI
		s["owner_peer"] = int(d.get("owner_peer", 0))
		s["owner_name"] = str(d.get("owner_name", ""))
		if bool(d.get("arrived", false)):
			arrived[id] = true
