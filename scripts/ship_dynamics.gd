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
# 附连水质量：船动起来时周围的水也被拖着一起动，等效质量比船本身大。
# 这个系数只影响"换速有多快"，不影响稳态速度（极坐标仍然归 ship_physics 管）。
const SURGE_MASS_FACTOR := 1.25

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
var _sail_area_scale := 1.0         # 帆档：全帆 1.0 / 缩帆 0.55 / 收帆 0
var _anchored := false
var current_world := Vector2.ZERO   # 洋流（世界系 m/s），由海图每帧灌进来
# 损伤（docs/01：只做三处，每一处都要能在气动上看见效果）
var damage := { "hull": 0.0, "mast": 0.0, "rudder": 0.0 }
var _wind_world := Vector2.ZERO
var _t := 0.0
var _last := {}                     # 上一帧的受力细节（帆态面板要读）


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


func wind_from_dir_deg() -> float:
	"""真风来向（世界系，度）：风**从**哪个方向来（不是吹向）。"""
	if _wind_world.length() < 1e-6:
		return 0.0
	return fposmod(rad_to_deg(atan2(_wind_world.y, _wind_world.x)) + 180.0, 360.0)


func last_forces() -> Dictionary:
	"""上一帧的受力细节：帆态面板的矢量图直接画它。"""
	return _last


func sail_area_scale() -> float:
	return _sail_area_scale


func is_anchored() -> bool:
	return _anchored


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


func wind_side() -> float:
	"""风从哪一舷来：+1 右舷 / −1 左舷。

	帆的攻角必须按舷别取符号 —— 这是"左舷受风"最容易写错的地方：
	把攻角照抄给另一舷，帆会被收到迎风面（被风顶着），推力骤降甚至倒推。
	"""
	var t := twa_signed_deg()
	if is_zero_approx(t):
		return 1.0
	return 1.0 if t > 0.0 else -1.0


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


func set_sail_area_scale(scale: float) -> void:
	"""帆档：缩帆是真的少一块帆布，不是换个数字。"""
	_sail_area_scale = clampf(scale, 0.0, 1.0)


func set_anchored(flag: bool) -> void:
	"""抛锚：锚把船摁住。帆的力照样算（面板看得见），但推不动船。"""
	_anchored = flag


func apply_damage(part: String, amount: float) -> void:
	"""船体 / 桅杆 / 舵。三处损伤各自都能在操船上看出来：

	船体  -> 摩擦与兴波阻力变大（同样的风跑不快）
	桅杆  -> 能用帆面积变小（推力直接掉）
	舵    -> 转舵效率下降（换舷更慢）
	"""
	if not damage.has(part):
		push_warning("未知的损伤部位：" + part)
		return
	damage[part] = clampf(float(damage[part]) + amount, 0.0, 1.0)


func damage_of(part: String) -> float:
	return float(damage.get(part, 0.0))


func describe_damage() -> String:
	var parts := PackedStringArray()
	for k in ["hull", "mast", "rudder"]:
		var v := float(damage[k])
		if v > 0.01:
			parts.append("%s %.0f%%" % [{"hull": "船体", "mast": "桅杆", "rudder": "舵"}[k], v * 100.0])
	return "无损伤" if parts.is_empty() else "　".join(parts)


func trim_to_alpha(alpha_main: float, alpha_jib := INF) -> void:
	"""船员按当前视风把帆收到指定攻角（Day 3 版：瞬间完成；Day 4 才加耗时与技能）。"""
	var aw := apparent_wind_ship_frame()
	var ad := rad_to_deg(atan2(aw.y, aw.x))
	var aj := alpha_jib
	if is_inf(aj):
		aj = clampf(alpha_main + physics.jib_offset, 8.0, 90.0)
	var side := wind_side()
	set_sail_chords(ad - side * alpha_main, ad - side * aj)


func sail_alpha_main_deg() -> float:
	"""当前主帆攻角的**大小**（度）——帆态面板要用（舷别不影响读数）。"""
	var aw := apparent_wind_ship_frame()
	if aw.length() < 1e-6:
		return 0.0
	return absf(ShipPhysics.normalize180(
		rad_to_deg(atan2(aw.y, aw.x)) - _sail_main_deg))


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
	# 帆档（缩帆/收帆）在这里生效：帆布少了，力和横倾一起小下去
	# 桅杆损伤 = 还能挂的帆面积变小
	var mast_ok := 1.0 - 0.5 * damage_of("mast")
	var fm := physics.sail_force(app_speed, app_dir, _sail_main_deg,
		physics.area_main * _sail_area_scale * mast_ok)
	var fj := physics.sail_force(app_speed, app_dir, _sail_jib_deg,
		physics.area_jib * _sail_area_scale * mast_ok)
	var fx := fm.x + fj.x
	var fy := fm.y + fj.y
	var cp := cos(deg_to_rad(_heel_deg))
	fx *= cp
	fy *= cp
	# 帆态面板的矢量图就是照这个画的
	_last = {
		"app_speed": app_speed, "app_dir": app_dir,
		"q": 0.5 * ShipPhysics.RHO_AIR * app_speed * app_speed,
		"fx": fx, "fy": fy, "main": fm, "jib": fj, "area_scale": _sail_area_scale,
	}

	# 船体：侧滑由龙骨抵挡，前进被船体阻力 + 龙骨诱导阻力拖住
	# 洋流：船是泡在水里的，水自己在动 —— 受力看的是**相对水的速度**，
	# 位置积分用的是相对地面的速度。所以不挂帆也会被流带着走。
	var cur_ship := _to_ship(current_world)
	var u_rel := _u - cur_ship.x
	var w_rel := _w - cur_ship.y
	# 抛锚：锚把船摁住 —— 帆的力照样算（面板能看见），但它推不动船。
	var w_target := physics.side_slip(fy, u_rel, w_rel)
	var phi_target := rad_to_deg(asin(clampf(
		fy * physics.h_ce / (physics.mass * ShipPhysics.GRAVITY * physics.gm),
		-1.0, 1.0)))

	if _anchored:
		# 锚把船摁住：速度很快归零，而且不再漂走
		_u = move_toward(_u, 0.0, 2.0 * delta)
		_w = move_toward(_w, 0.0, 1.0 * delta)
	else:
		# ⚠️ 前进方向必须**按质量积分**，不能瞬时跳到稳态。
		# 60 吨的船换速要几十秒 —— 这点惯性是"换舷能不能过顶"的关键：
		# 抢风时要带着余速穿过死区，瞬时求解的话一顶风速度立刻归零，船就卡死在风里。
		# 船体损伤 = 阻力变大（船底蹭过礁石之后就跑不动了）
		var hull_bad := 1.0 + 0.9 * damage_of("hull")
		# 阻力永远**对抗相对水流**：水比船快（u_rel<0）时它就是**推**船。
		# 少了这个符号，洋流就带不动船（Day 6 现场抓到的）。
		var drag_axial := physics.hull_drag(absf(u_rel)) * hull_bad * signf(u_rel) \
			+ physics.induced_drag(fy, u_rel, w_rel) * signf(u_rel)
		_u += (fx - drag_axial) / (physics.mass * SURGE_MASS_FACTOR) * delta
		# 侧滑与横倾的惯性小得多，维持一阶松弛就够了
		_w += minf(1.0, delta / 2.0) * (w_target - _w)
	_heel_deg += minf(1.0, delta / 1.5) * (phi_target - _heel_deg)

	# 艏向：舵效（要有速度才转得动）+ 风压偏转
	# 舵效与速度有关，但不能归零：真有速度才转得动，可是停住的船也能靠舵慢慢
	# 转出去（水流、涌浪、船体本身的惯性都会给舵一点力）。这个下限很关键 ——
	# 船在死区里停住时，全靠它才能把头转出来。
	var speed_factor := clampf(_u / 2.0, 0.35, 1.2)
	var weather := WEATHER_HELM * sin(deg_to_rad(app_dir + 180.0))
	# 舵损伤 = 转舵效率下降
	var rudder_ok := 1.0 - 0.6 * damage_of("rudder")
	var yaw_target := _rudder_deg * YAW_PER_RUDDER * speed_factor * rudder_ok + weather
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
