class_name Navigator
extends RefCounted

# 航海官（船长在船上）/ 大副（船长离船）—— 同一套决策，两顶帽子。
#
# 它的工作（docs/01 支柱 3 的中间那一格）：
#   玩家的目标点 + 风向 + 当前航向  ──→  航法 + 给舵手的目标航向 + 给船员的目标攻角
#
# 它**不碰**船的速度、位置，也不碰帆和舵 —— 那些分别是 ShipDynamics 和 Crew 的事。
# 指挥链路因此是单向的：玩家 → 航海官 → 船员 → 帆 → 船 → 表现。

const KNOT := 0.514444

# 离逆风死区边界再让 8 度：贴着边界走会让船一直在"刚要失速"的刀尖上，
# 而且舵手实际会落在目标航向的下风侧几度（风压偏转），不留余量就会被按进死区。
# 标定出来的边界是 37 度（docs/08）。
const NO_GO_MARGIN := 8.0
const NO_GO_TWA := 37.0
# 换舷迟滞：另一舷要"明显更好"才换。没有它，目标点几乎正顶风时
# 两舷的优劣会在零点附近来回翻 —— 航海官一秒换一次舷，船就原地打转，
# 永远攒不起速度（Day 4 现场抓到的就是这个死循环）。
const TACK_HYSTERESIS := 12.0

# M13（自拍，可否决 —— 见 docs/07 待决问题）：**避岸**。
# 长跑扫描抓到：船被洋流按在背风岸上、速度掉光之后就再也出不来（巴塔哥尼亚外海卡了 50 天）。
# 现实里的水手不会一直往岸上顶，他们会"贴着风偏出去"（把船从背风岸上抢出来）。
# 所以航海官多一条规则：贴着岸又走不动的时候，选那一舷**离岸最远**的可走航向。
const SHOAL_TRIGGER_M := 250.0       # 离岸这么近、而且快停了，就算"贴岸"
const SHOAL_RELEASE_M := 600.0       # 离岸超过这个数才解除（迟滞，免得在岸边来回抖）
const SHOAL_INTO_DEG := 70.0         # 目标方位与"岸的方位"差这么多度以内 = 在往岸上顶

enum Method { HOLD, STEER, BEAT, RUN, STOP, AVOID }

var orders: ShipOrders
var method: Method = Method.HOLD
var target_heading_deg := 0.0
var tack_side := 1.0                 # 抢风时受风的一舷：+1 右舷 / −1 左舷
var bearing_deg := 0.0               # 目标点的方位
var tack_count := 0                  # 真的换过几次舷（受风舷翻到另一边）
var beat_count := 0                  # 抢风走了几段（从别的航法切进抢风算一段）
var _last_method: Method = Method.HOLD
var _last_tack_side := 1.0           # 上一轮抢风时受风的那一舷
# 圆柱世界（M9/M12）：> 0 时方位与距离都**走最短的一边**。
# 平面海域是 0（老海域一个数都不改）。由 `Voyage.setup()` 灌进来。
var wrap_width := 0.0
# 避岸（M13）的输入：由 `Voyage.tick()` 每帧灌进来（不存盘，是派生量）
var shore_distance_m := INF          # 离最近的岸多远
var shore_bearing_deg := 0.0         # 从船指向最近那点岸的方位
var blocked := false                 # 这一帧是不是正顶着干地（`ShipDynamics.last_blocked`）
var _avoiding := false               # 迟滞：进了避岸就走到离岸 600 米才解除


func _init(orders_ref: ShipOrders) -> void:
	orders = orders_ref


func no_go_twa_deg() -> float:
	return NO_GO_TWA + NO_GO_MARGIN


func decide(ship: ShipDynamics) -> void:
	"""每次配平前决策一次：这一步决定了"船往哪儿走"。"""
	if not orders.allow_sailing():
		method = Method.STOP
		target_heading_deg = ship.heading_deg()
		_remember()
		return

	if not orders.has_target_point:
		method = Method.HOLD
		_remember()
		return

	var to_target := delta_to(orders.target_point, ship.position_m())
	if to_target.length() < 8.0:                 # 到了：转成保持航向
		method = Method.HOLD
		orders.clear_target_point()
		_remember()
		return

	bearing_deg = fposmod(rad_to_deg(atan2(to_target.y, to_target.x)), 360.0)
	var wind_from := ship.wind_from_dir_deg()

	# --- M13：避岸（见上面那段注释）---
	if _avoiding and shore_distance_m > SHOAL_RELEASE_M and not blocked:
		_avoiding = false
	if not _avoiding:
		var rel_shore := absf(ShipPhysics.normalize180(bearing_deg - shore_bearing_deg))
		if blocked or (shore_distance_m < SHOAL_TRIGGER_M and ship.speed_ms() < 0.7
				and rel_shore < SHOAL_INTO_DEG):
			_avoiding = true
	if _avoiding:
		# 从两条"贴着死区边界"的航向里，挑**离岸更远**的那一舷 ——
		# 这就是"贴着风把船从背风岸上抢出来"，而不是硬往岸上顶。
		method = Method.AVOID
		var beat := no_go_twa_deg()
		var cand_a := fposmod(wind_from + beat, 360.0)
		var cand_b := fposmod(wind_from - beat, 360.0)
		var err_a := absf(ShipPhysics.normalize180(cand_a - shore_bearing_deg))
		var err_b := absf(ShipPhysics.normalize180(cand_b - shore_bearing_deg))
		target_heading_deg = cand_a if err_a > err_b else cand_b
		_remember()
		return

	var off_wind := absf(ShipPhysics.normalize180(bearing_deg - wind_from))

	if off_wind >= no_go_twa_deg():
		# 目标不在死区里：直接朝目标走。
		# 真风角大于 140 度时这叫顺风跑，面板上分开显示。
		method = Method.RUN if off_wind > 140.0 else Method.STEER
		target_heading_deg = bearing_deg
	else:
		# 目标在死区里：抢风。选离目标更近的那一舷，贴着死区边界走。
		# 船一旦越过目标的"正横"，方位角自己就会转出死区，
		# 于是上一条分支接管、船直接朝目标走 —— 换舷是这么自然发生的。
		# 起步 / 失速之后要先走得宽一点：船速不够时贴不住风，
		# 横着漂的代价（诱导阻力）大得可怕，船会一直在一节上下打转。
		# 真实水手也是这么干的：先松帆偏开风，把速度攒起来再往上顶。
		var beat := no_go_twa_deg()
		if ship.speed_ms() < 2.0:
			beat = minf(75.0, beat + 30.0)
		var cand_a := 1.0
		var cand_b := -1.0
		var err_a := absf(ShipPhysics.normalize180(
			bearing_deg - (wind_from + beat)))
		var err_b := absf(ShipPhysics.normalize180(
			bearing_deg - (wind_from - beat)))
		if err_a + TACK_HYSTERESIS < err_b:
			tack_side = cand_a
		elif err_b + TACK_HYSTERESIS < err_a:
			tack_side = cand_b
		# 两舷差不多好 -> 保持当前舷（这就是迟滞）
		method = Method.BEAT
		target_heading_deg = fposmod(wind_from + tack_side * beat, 360.0)
	_remember()


func delta_to(to: Vector2, from: Vector2) -> Vector2:
	"""从 from 到 to 的位移：圆柱世界里走**最短的一边**（跨接缝不是"绕地球一圈"）。"""
	var d := to - from
	if wrap_width > 0.0:
		d.x = fposmod(d.x + wrap_width * 0.5, wrap_width) - wrap_width * 0.5
	return d


func _remember() -> void:
	# 换舷 = **一直在抢风**，但受风的那一舷翻到了另一边（船头真的转过来了）。
	# 这里曾经写成一个永远进不去的分支（外层已经要求 method != _last_method），
	# 于是 tack_count 永远是 0 —— 帆态面板上的"换舷 N 次"从来没动过。
	if method == Method.BEAT and _last_method != Method.BEAT:
		beat_count += 1
	if method == Method.BEAT and _last_method == Method.BEAT and tack_side != _last_tack_side:
		tack_count += 1
	_last_tack_side = tack_side
	_last_method = method


func method_name() -> String:
	match method:
		Method.HOLD: return "保持航向"
		Method.STEER: return "转向目标"
		Method.BEAT: return "抢风（%s受风）" % ("右舷" if tack_side > 0.0 else "左舷")
		Method.RUN: return "顺风跑"
		Method.STOP: return "停船"
		Method.AVOID: return "避岸（抢出背风岸）"
	return "?"


func describe() -> String:
	var tgt := "%.0f°" % target_heading_deg
	return "航海官：%s，舵手目标 %s，抢风 %d 段 / 换舷 %d 次" % [
		method_name(), tgt, beat_count, tack_count]


# ------------------------------------------------------------ 存档（docs/14）
# 迟滞状态（_last_method / _last_tack_side / tack_side）必须存：
# 不存的话读档后第一帧就可能换到另一舷，船头立刻拧一下 —— 玩家看得出来。

func capture_state() -> Dictionary:
	return {
		"method": int(method),
		"target_heading_deg": target_heading_deg,
		"tack_side": tack_side,
		"bearing_deg": bearing_deg,
		"tack_count": tack_count,
		"beat_count": beat_count,
		"_last_method": int(_last_method),
		"_last_tack_side": _last_tack_side,
		# M13 避岸的迟滞：不存的话读档后可能立刻又往岸上顶
		"_avoiding": _avoiding,
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	method = int(d.get("method", Method.HOLD)) as Method
	target_heading_deg = float(d.get("target_heading_deg", 0.0))
	tack_side = float(d.get("tack_side", 1.0))
	bearing_deg = float(d.get("bearing_deg", 0.0))
	tack_count = int(d.get("tack_count", 0))
	beat_count = int(d.get("beat_count", 0))
	_last_method = int(d.get("_last_method", Method.HOLD)) as Method
	_last_tack_side = float(d.get("_last_tack_side", 1.0))
	_avoiding = bool(d.get("_avoiding", false))
