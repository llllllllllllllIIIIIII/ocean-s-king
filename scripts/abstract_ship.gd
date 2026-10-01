class_name AbstractShip
extends RefCounted

# 抽象船（docs/13 第 5.1 节 / 原设定第二十一节）：世界里"没人细化"的船。
#
# 两种身份用的是同一个类：
#   ① **AI 船**：房主（单机就是本机）按这套粗糙模型往前走；
#   ② **别人的船**：我们只收到 20Hz 的摘要，把摘要塞进同一个壳里 ——
#      它没有气动、没有 40 个人的名册，也**不该有**（docs/14 的 UI 规矩：
#      不许进入别人的船的内部视图）。
#
# 所以它只有摘要：位姿 / 帆档 / 锚 / 船体% / 人数 / 在干什么。
# 这让"一台机器永远只细化一艘船"成立 —— 四艘船在同一个世界里，
# 单机负载和 v0.1 一模一样。

const CRUISE_MS := 2.2              # 巡航速度 m/s（约 4.3 节，比玩家亲手操的慢一点）
const TURN_DPS := 6.0               # 转舵速度 度/秒
const ARRIVE_M := 260.0
const KNOT := 0.514444

var id := ""
var name := ""
var pos := Vector2.ZERO
var heading_deg := 0.0
var sail_level := 0                 # ShipOrders.SailLevel.FULL
var anchored := false
var hull_pct := 1.0
var crew_count := 40
var action := "停泊"                 # 一句话概括它在干什么（海图上会写）
var hold_kg := 0.0                   # 装了多重（M4：别人的船只有这个汇总）
var money := 0
var target := Vector2.ZERO
var has_target := false
var speed_ms := 0.0
# M8：航线航点。AI 船照着**已经设计好的航段**走（routes.json 那条不穿干地的线），
# 而不是朝终点一路直线 —— 直线会撞上西非海岸，然后永久"受阻"在岸边。
var waypoints: Array = []
var _blocked_t := 0.0


func setup(ship_id: String, ship_name: String, at: Vector2, heading := 90.0) -> void:
	id = ship_id
	name = ship_name
	pos = at
	heading_deg = heading


func step(delta: float, sea: Sea) -> void:
	"""AI 的糙模型：朝目标走，遇到干地就停下。它不认识风，只认识"往哪儿开"。"""
	if not waypoints.is_empty():
		target = waypoints[0]
		has_target = true
	if anchored or sail_level == 2 or not has_target:
		speed_ms = move_toward(speed_ms, 0.0, 1.2 * delta)
		action = "抛锚" if anchored else ("漂着" if not has_target else "收帆")
		_drift(delta, sea)
		return
	var to_target := target - pos
	if to_target.length() < ARRIVE_M:
		speed_ms = move_toward(speed_ms, 0.0, 1.0 * delta)
		if not waypoints.is_empty():
			waypoints.pop_front()          # 到了这一个航点，接着去下一个
			action = "转向下一段"
		else:
			action = "抵达待命"
			has_target = false
		_drift(delta, sea)
		return
	var want := rad_to_deg(atan2(to_target.y, to_target.x))
	var diff := ShipPhysics.normalize180(want - heading_deg)
	heading_deg = fposmod(heading_deg + clampf(diff, -TURN_DPS * delta, TURN_DPS * delta), 360.0)
	var cruise := CRUISE_MS * (1.0 if sail_level == 0 else 0.55)
	speed_ms = move_toward(speed_ms, cruise, 0.8 * delta)
	action = "巡航" if absf(diff) < 30.0 else "转舵"
	var step_vec := Vector2(cos(deg_to_rad(heading_deg)), sin(deg_to_rad(heading_deg))) \
		* speed_ms * delta
	var next := pos + step_vec
	if sea.is_dry_land(next):
		# 干地：**贴着岸滑**（和玩家那条船的做法一致 —— 见 ShipDynamics 的沿轴滑动）。
		# 早先的版本是"停住"，结果是 AI 一路贴到岸边就不动了；后来改成"卡 30 秒就跳过
		# 这个航点"，结果它把航点全跳光、离终点还差 18 公里。滑动才对。
		var slid := Vector2.ZERO
		if not sea.is_dry_land(Vector2(next.x, pos.y)):
			slid = Vector2(step_vec.x, 0.0)
		elif not sea.is_dry_land(Vector2(pos.x, next.y)):
			slid = Vector2(0.0, step_vec.y)
		if slid == Vector2.ZERO:
			speed_ms = 0.0
			action = "受阻"
			_blocked_t += delta
		else:
			pos += slid
			action = "沿岸绕行"
			_blocked_t = 0.0
		_drift(delta, sea)
		return
	_blocked_t = 0.0
	pos = next
	_drift(delta, sea)


func _drift(delta: float, sea: Sea) -> void:
	"""洋流：不挂帆也会被带走 —— 和玩家那条船是同一条物理常识，只是这里算得糙。"""
	var cur := sea.current_at(pos)
	if cur.length() < 1e-6:
		return
	var next := pos + cur * delta
	if not sea.is_dry_land(next):
		pos = next


func apply_damage(part: String, amount: float) -> void:
	if part == "hull":
		hull_pct = clampf(hull_pct - amount, 0.0, 1.0)


func sort_short() -> String:
	return "%s　%s　船体 %.0f%%" % [name, action, hull_pct * 100.0]


# ------------------------------------------------------------ 摘要（上网的就是这一份）

func to_summary() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"pos": [pos.x, pos.y],
		"heading": heading_deg,
		"sail_level": int(sail_level),
		"anchored": anchored,
		"hull_pct": hull_pct,
		"crew_count": crew_count,
		"action": action,
		"hold_kg": hold_kg,
		"money": money,
	}


func apply_summary(d: Dictionary) -> void:
	if d.is_empty():
		return
	id = str(d.get("id", id))
	name = str(d.get("name", name))
	var p: Array = d.get("pos", [pos.x, pos.y])
	pos = Vector2(float(p[0]), float(p[1]))
	heading_deg = float(d.get("heading", heading_deg))
	sail_level = int(d.get("sail_level", sail_level))
	anchored = bool(d.get("anchored", anchored))
	hull_pct = float(d.get("hull_pct", hull_pct))
	crew_count = int(d.get("crew_count", crew_count))
	action = str(d.get("action", action))
	hold_kg = float(d.get("hold_kg", hold_kg))
	money = int(d.get("money", money))


# ------------------------------------------------------------ 存档（docs/14 第 3 节：抽象船专用）

func capture_state() -> Dictionary:
	var d := to_summary()
	d["target"] = StateIO.v2(target)
	d["has_target"] = has_target
	d["speed_ms"] = speed_ms
	# 航点也要摊成 [x, y]：Vector2 直接丢进 JSON.stringify 会变成字符串 "(x, y)"，
	# 读档回来 waypoints[0] 就成了 String，step() 里赋给 Vector2 当场报错。
	d["waypoints"] = _points_to_arrays(waypoints)
	return d


func apply_state(d: Dictionary) -> void:
	apply_summary(d)
	target = StateIO.to_v2(d.get("target", StateIO.v2(pos)))
	has_target = bool(d.get("has_target", false))
	speed_ms = float(d.get("speed_ms", 0.0))
	waypoints = _parse_points(d.get("waypoints", []))


static func _points_to_arrays(points: Array) -> Array:
	"""落盘用的形态：一律 [x, y] —— 走 StateIO，和别的类一个口径。"""
	var out := []
	for p in points:
		if typeof(p) == TYPE_VECTOR2 or typeof(p) == TYPE_ARRAY:
			out.append(StateIO.v2(p))
	return out


static func _parse_points(raw: Variant) -> Array:
	"""读档：三种形态都要认 —— ①Vector2（内存里）②[x, y]（现存档）
	③"(x, y)"（Vector2 被直接 stringify 出来的那种档，得救回来）。"""
	var out := []
	if typeof(raw) == TYPE_PACKED_VECTOR2_ARRAY:
		for p in (raw as PackedVector2Array):
			out.append(p)
		return out
	if typeof(raw) != TYPE_ARRAY:
		return out
	for p in raw:
		if typeof(p) == TYPE_VECTOR2:
			out.append(p)
		elif typeof(p) == TYPE_ARRAY:
			out.append(StateIO.to_v2(p))
		elif typeof(p) == TYPE_STRING:
			var bits := str(p).strip_edges().trim_prefix("(").trim_suffix(")").split(",")
			if bits.size() >= 2:
				out.append(Vector2(String(bits[0]).strip_edges().to_float(),
					String(bits[1]).strip_edges().to_float()))
	return out
