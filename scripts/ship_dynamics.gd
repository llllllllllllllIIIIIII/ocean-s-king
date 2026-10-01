class_name ShipDynamics
extends RefCounted

# 船的运动：位置、艏向、前进速度 u、侧滑 w、横倾、舵角、帆的实际收放角。
#
# ⚠️ **全项目唯一允许写船的位置/速度的地方**（AGENTS.md 铁律 5）：
#     任何系统都不允许直接改船的速度或位置，包括剧情事件和调试工具。
#     数据流严格单向：玩家 → 船员 → 帆 → 船 → 表现。
#     别人只能读 snapshot()，或者用 set_rudder() / set_sail_chords()
#     这种"下指令"的入口间接影响它。tools/check_motion_ownership.py 会查这条。
#
# 坐标系（AGENTS.md 铁律 7）：船体系 +x 船首、+y 右舷；
# 世界系 0 度 = +x，顺时针为正（屏幕 y 向下），heading 就是"船首指向"。

const KNOT := 0.514444
const RUDDER_MAX := 35.0            # 度
const YAW_PER_RUDDER := 0.12        # 度/秒 每度舵角（满舵时约 4.2 度/秒）
const WEATHER_HELM := 0.6           # 度/秒 风压偏转（船会自己往风里顶）
const RELAX_TAU := 0.33             # 秒   速度/横倾追上目标的时间常数

var physics: ShipPhysics

var _pos_m := Vector2.ZERO          # 世界坐标（米）
var _heading_deg := 180.0           # 航向（度）
var _u := 0.0                       # 前进速度 m/s
var _w := 0.0                       # 侧滑速度 m/s（+ = 向右舷滑）
var _heel_deg := 0.0                # 横倾（+ = 向右舷倾）
var _yaw_rate_dps := 0.0
var _rudder_deg := 0.0
var _sail_main_deg := -90.0         # 帆弦线（船体系，度）
var _sail_jib_deg := -90.0
var _wind_world := Vector2.ZERO
var _t := 0.0


func _init(phys: ShipPhysics) -> void:
	physics = phys


# ------------------------------------------------------------ 只读快照

func snapshot() -> Dictionary:
	return {
		"pos_m": _pos_m,
		"heading_deg": _heading_deg,
		"u_ms": _u,
		"u_kn": _u / KNOT,
		"w_ms": _w,
		"heel_deg": _heel_deg,
		"rudder_deg": _rudder_deg,
		"yaw_rate_dps": _yaw_rate_dps,
		"sail_main_deg": _sail_main_deg,
		"sail_jib_deg": _sail_jib_deg,
	}


func position_m() -> Vector2:
	return _pos_m


func heading_deg() -> float:
	return _heading_deg


func speed_ms() -> float:
	return _u


func speed_kn() -> float:
	return _u / KNOT


func heel_deg() -> float:
	return _heel_deg


func leeway_deg() -> float:
	"""实际侧滑角（度）。顶上失速时它会明显变大 —— 这是玩家看得见的线索。"""
	return rad_to_deg(atan2(_w, maxf(_u, 0.05)))


func wind_ship_frame() -> Vector2:
	"""真风在船体系里的速度矢量。"""
	return _to_ship(_wind_world)


func apparent_wind_ship_frame() -> Vector2:
	"""视风 = 真风 − 船速（船体系）。"""
	var v := wind_ship_frame()
	return Vector2(v.x - _u, v.y - _w)


func twa_deg() -> float:
	"""真风角：0 = 风从船首正前方来，180 = 正顺风。"""
	var v := wind_ship_frame()
	if v.length() < 1e-6:
		return 0.0
	return absf(ShipPhysics.normalize180(rad_to_deg(atan2(v.y, v.x)) + 180.0))


func twa_signed_deg() -> float:
	"""带符号的真风角：+ = 风从右舷来，− = 从左舷来。

	船员要靠这个决定帆收在哪一舷（配平表只存右舷来风的那一半，另一半取反）。
	"""
	var v := wind_ship_frame()
	if v.length() < 1e-6:
		return 0.0
	return ShipPhysics.normalize180(rad_to_deg(atan2(v.y, v.x)) + 180.0)


func awa_deg() -> float:
	var v := apparent_wind_ship_frame()
	if v.length() < 1e-6:
		return 0.0
	return absf(ShipPhysics.normalize180(rad_to_deg(atan2(v.y, v.x)) + 180.0))


# ------------------------------------------------------------ 指令入口
# 玩家/船员只能从这些口子影响船；它们改的是"帆和舵"，不是速度和位置。

func set_rudder(deg: float) -> void:
	_rudder_deg = clampf(deg, -RUDDER_MAX, RUDDER_MAX)


func set_sail_chords(main_deg: float, jib_deg: float) -> void:
	_sail_main_deg = main_deg
	_sail_jib_deg = jib_deg


func trim_to_alpha(alpha_main: float, alpha_jib := INF) -> void:
	"""船员按当前视风把帆收到指定攻角（Day 3 版：瞬间完成；Day 4 才加耗时与技能）。"""
	var aw := apparent_wind_ship_frame()
	var ad := rad_to_deg(atan2(aw.y, aw.x))
	var aj := alpha_jib
	if is_inf(aj):
		aj = clampf(alpha_main + physics.jib_offset, 8.0, 90.0)
	set_sail_chords(ad - alpha_main, ad - aj)


func sail_alpha_main_deg() -> float:
	"""当前主帆的攻角（度）——帆态面板要用。"""
	var aw := apparent_wind_ship_frame()
	if aw.length() < 1e-6:
		return 0.0
	return ShipPhysics.normalize180(rad_to_deg(atan2(aw.y, aw.x)) - _sail_main_deg)


func set_pose(pos_m: Vector2, heading_deg_value: float) -> void:
	"""只给测试与重置用：把船摆到某个位置。运行时的运动必须由 step() 积分出来。"""
	_pos_m = pos_m
	_heading_deg = fposmod(heading_deg_value, 360.0)


# ------------------------------------------------------------ 积分

func step(delta: float, wind_world: Vector2) -> void:
	"""一个物理步。这是**唯一**会改变船的位置与速度的地方。"""
	_wind_world = wind_world
	var h := deg_to_rad(_heading_deg)
	var cs := cos(h)
	var sn := sin(h)

	# 世界风 -> 船体系
	var v := _to_ship(wind_world)
	var ax := v.x - _u
	var ay := v.y - _w
	var app_speed := sqrt(ax * ax + ay * ay)
	var app_dir := rad_to_deg(atan2(ay, ax)) if app_speed > 1e-6 else rad_to_deg(atan2(v.y, v.x))

	# 帆的力（主帆 + 前帆），横倾后桅杆倾斜 -> 水平分量乘 cos(phi)
	var fm := physics.sail_force(app_speed, app_dir, _sail_main_deg, physics.area_main)
	var fj := physics.sail_force(app_speed, app_dir, _sail_jib_deg, physics.area_jib)
	var fx := fm.x + fj.x
	var fy := fm.y + fj.y
	var cp := cos(deg_to_rad(_heel_deg))
	fx *= cp
	fy *= cp

	# 船体：侧滑由龙骨抵挡，前进被船体阻力 + 龙骨诱导阻力拖住
	var w_target := physics.side_slip(fy, _u, _w)
	var u_target := physics.solve_surge(fx, fy, w_target)
	var phi_target := rad_to_deg(asin(clampf(
		fy * physics.h_ce / (physics.mass * ShipPhysics.GRAVITY * physics.gm),
		-1.0, 1.0)))

	var k := minf(1.0, delta / RELAX_TAU)
	_u += k * (u_target - _u)
	_w += k * (w_target - _w)
	_heel_deg += k * (phi_target - _heel_deg)

	# 艏向：舵效（要有速度才转得动）+ 风压偏转
	var speed_factor := clampf(_u / 2.0, 0.15, 1.2)
	var weather := WEATHER_HELM * sin(deg_to_rad(app_dir + 180.0))
	var yaw_target := _rudder_deg * YAW_PER_RUDDER * speed_factor + weather
	_yaw_rate_dps += minf(1.0, delta / 1.5) * (yaw_target - _yaw_rate_dps)
	_heading_deg = fposmod(_heading_deg + _yaw_rate_dps * delta, 360.0)

	# 位置：世界速度 = R(heading) · (u, w)
	_pos_m += Vector2(_u * cs - _w * sn, _u * sn + _w * cs) * delta
	_t += delta


func _to_ship(v: Vector2) -> Vector2:
	var h := deg_to_rad(_heading_deg)
	var cs := cos(h)
	var sn := sin(h)
	return Vector2(v.x * cs + v.y * sn, -v.x * sn + v.y * cs)
