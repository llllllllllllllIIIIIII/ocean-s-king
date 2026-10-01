class_name Crew
extends RefCounted

# 执行层：把航海官的目标航向、目标攻角变成**实际的**舵角与帆弦线。
#
# ⚠️ 这里必须是"慢且不完美"的 —— 这就是支柱 3（指挥链路）的全部意义：
#     耗时 = f(技能, 人数, 疲劳)      精度 = 实际攻角离最优差多少
#   帆的面积、舵角、收放速度全部由这里推着走；船的速度和位置仍然只有
#   ShipDynamics 能写。玩家的操作永远够不到船本身。
#
# Day 5 会把 skill / fatigue / hands 换成 12 名真实船员的需求与技能；
# 这里先用一组最小可用的数，把"船员好不好 → 船灵不灵"这条因果关系立起来。

const RUDDER_MAX := 35.0
const TRIM_TABLE_PATH := "res://data/defs/trim_table.json"

var ship: ShipDynamics

# --- 船员的状态（Day 5 会被真实船员表替换）---
var hands_on_sails := 6          # 派去操帆的人手
var skill := 0.75                # 0..1 操帆手艺（航海官/水手长的手艺）
var fatigue := 0.15              # 0..1 疲劳

# --- 命令（由航海官给）---
var commanded_heading_deg := 0.0
var has_heading_command := false
var alpha_target := 20.0         # 目标主帆攻角（查表得来）

# --- 执行结果（面板与测试要看的量）---
var trim_rate_dps := 0.0         # 当前收放速度（度/秒）
var alpha_error_deg := 0.0       # 实际攻角与目标的偏差（精度）
var trim_busy := false           # 帆还没收到位
var trim_period := 0.5           # 秒  多久重新想一次"帆该收到哪儿"

var _t := 0.0
var _trim_timer := 1e9
var _force_retrim := true
var _steer_integral := 0.0           # 舵的积分项：专门用来顶住持续的风压偏转
var _tw := PackedFloat64Array()      # 配平表：真风速轴
var _ta := PackedFloat64Array()      # 配平表：视风角轴
var _alpha_grid: Array = []          # [风速][视风角] -> 主帆攻角


func _init(ship_ref: ShipDynamics) -> void:
	ship = ship_ref
	_load_trim_table()


func _load_trim_table() -> void:
	"""船员手里的"操帆手册"：由 tools/aero_prototype.py --mode trim-table 生成。

	⚠️ 表的键必须是**视风角**，不是真风角（Day 3 现场踩到的坑）：
	按真风角配平等于假设"船正在航行"，船一停住视风退化成真风，
	同一个攻角会把帆收到背风侧，船就再也起不来了。详见 docs/08 第 4 节。
	"""
	if not FileAccess.file_exists(TRIM_TABLE_PATH):
		push_warning("缺少配平表 %s，船员将使用固定攻角" % TRIM_TABLE_PATH)
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(TRIM_TABLE_PATH))
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("配平表解析失败，船员将使用固定攻角")
		return
	for v in d.get("tws_ms", []):
		_tw.append(float(v))
	for v in d.get("awa_deg", []):
		_ta.append(float(v))
	_alpha_grid = d.get("alpha_deg", [])


# ------------------------------------------------------------ 命令入口

func set_target_heading(deg: float) -> void:
	var new_heading := fposmod(deg, 360.0)
	if has_heading_command and absf(ShipPhysics.normalize180(
			new_heading - commanded_heading_deg)) > 15.0:
		_steer_integral = 0.0        # 换了新航向，旧积分不能带过来（会甩头）
	commanded_heading_deg = new_heading
	has_heading_command = true


func retrim() -> void:
	"""重新决定**目标**攻角（查视风角）。注意这只是目标 —— 帆要靠人手收过去。"""
	var tws := ship.wind_ship_frame().length()
	if tws < 0.3:
		return
	alpha_target = lookup_alpha(tws, ship.awa_deg())
	_force_retrim = false


func lookup_alpha(tws: float, awa: float) -> float:
	"""双线性插值查配平表：真风速 × 视风角 -> 主帆攻角。"""
	if _tw.is_empty() or _ta.is_empty() or _alpha_grid.is_empty():
		return alpha_target
	var j := _axis_index(_ta, clampf(awa, _ta[0], _ta[_ta.size() - 1]))
	var i := _axis_index(_tw, clampf(tws, _tw[0], _tw[_tw.size() - 1]))
	var a00 := float(_alpha_grid[i][j])
	var a01 := float(_alpha_grid[i][j + 1])
	var a10 := float(_alpha_grid[i + 1][j])
	var a11 := float(_alpha_grid[i + 1][j + 1])
	var fx := _axis_frac(_ta, j, clampf(awa, _ta[0], _ta[_ta.size() - 1]))
	var fy := _axis_frac(_tw, i, clampf(tws, _tw[0], _tw[_tw.size() - 1]))
	return lerpf(lerpf(a00, a01, fx), lerpf(a10, a11, fx), fy)


func _axis_index(axis: PackedFloat64Array, v: float) -> int:
	var i := 0
	while i < axis.size() - 2 and v > axis[i + 1]:
		i += 1
	return i


func _axis_frac(axis: PackedFloat64Array, i: int, v: float) -> float:
	var span := axis[i + 1] - axis[i]
	return 0.0 if span <= 0.0 else clampf((v - axis[i]) / span, 0.0, 1.0)


# ------------------------------------------------------------ 每帧执行

func step(delta: float) -> void:
	_t += delta
	_trim_timer += delta
	if _force_retrim or _trim_timer >= trim_period:
		_trim_timer = 0.0
		retrim()
	trim_rate_dps = _trim_rate()
	_move_sails(delta)
	_steer(delta)
	_update_fatigue(delta)


func _trim_rate() -> float:
	"""收放帆的速度（度/秒）：手艺 × 人手，再被疲劳打折。

	这是"船员好不好 → 船灵不灵"最直接的那一条线：
	好船员满员时约 9 度/秒（一次换舷三十几秒），累垮的三个人只有 2 度/秒。
	"""
	var hands := clampf(float(hands_on_sails) / 6.0, 0.15, 1.6)
	var rate := (1.2 + 9.0 * skill * hands) * (1.0 - 0.55 * fatigue)
	if hands_on_sails <= 0:
		return 0.0
	return maxf(rate, 0.0)


func _alpha_bias() -> float:
	"""手艺差 + 疲劳 → 收放得不准。用一条慢摆的正弦表示"手在抖"，可复现、不是随机数。"""
	var amp := (1.0 - skill) * 9.0 + fatigue * 7.0
	return amp * sin(_t * 0.11)


func _move_sails(delta: float) -> void:
	"""把帆往目标位置收 —— 这里是整套指挥链路里唯一"慢"的地方。"""
	var aw := ship.apparent_wind_ship_frame()
	if aw.length() < 0.05:
		return
	var ad := rad_to_deg(atan2(aw.y, aw.x))
	var bias := _alpha_bias()
	# 攻角要按舷别取符号：左舷受风时整条帆镜像到另一边，
	# 否则帆会被收到迎风面（被风顶着），推力骤降 —— 这是最容易写错的一处。
	var side := ship.wind_side()
	var want_main := ad - side * (alpha_target + bias)
	var want_jib := ad - side * (alpha_target + bias + ship.physics.jib_offset)
	var snap := ship.snapshot()
	var cur_main := float(snap["sail_main_deg"])
	var cur_jib := float(snap["sail_jib_deg"])

	var step_max := trim_rate_dps * delta
	var new_main := _turn_toward(cur_main, want_main, step_max)
	var new_jib := _turn_toward(cur_jib, want_jib, step_max)
	ship.set_sail_chords(new_main, new_jib)
	alpha_error_deg = ship.sail_alpha_main_deg() - alpha_target
	trim_busy = absf(ShipPhysics.normalize180(want_main - new_main)) > 2.0


func _turn_toward(cur: float, want: float, step_max: float) -> float:
	"""按最大角速度把帆往目标转，注意角度要跨 ±180 正确回绕。"""
	var d := ShipPhysics.normalize180(want - cur)
	if absf(d) <= step_max:
		return want
	return cur + signf(d) * step_max


func _steer(delta: float) -> void:
	"""舵手：P 控制 + 打舵速度上限（累垮的舵手连舵都打得慢）。"""
	if not has_heading_command:
		ship.set_rudder(0.0)
		_steer_integral = 0.0
		return
	var err := ShipPhysics.normalize180(commanded_heading_deg - ship.heading_deg())
	# 增益要够大：船慢的时候舵效差、风压偏转又相对更强，
	# 增益小了会留下十几度的稳态误差 —— 那点误差足以把船按在逆风死区里。
	# 再加一点积分：风压偏转是**持续**的干扰，纯 P 控制必然留稳态误差。
	_steer_integral = clampf(_steer_integral + err * delta, -25.0, 25.0)
	var want := clampf(err * 2.5 + _steer_integral * 0.8, -RUDDER_MAX, RUDDER_MAX)
	var rate := (5.0 + 10.0 * skill) * (1.0 - 0.5 * fatigue)
	var cur := float(ship.snapshot()["rudder_deg"])
	ship.set_rudder(move_toward(cur, want, rate * delta))


func _update_fatigue(delta: float) -> void:
	"""干活会累、闲着会缓。数值很小 —— 一局游戏里应该是"慢慢显出来"的压力。"""
	var factor := 0.00012 * clampf(float(hands_on_sails) / 6.0, 0.4, 2.0)
	if trim_busy:
		fatigue += factor * delta
	else:
		fatigue -= factor * 0.5 * delta
	fatigue = clampf(fatigue, 0.0, 1.0)


# ------------------------------------------------------------ 面板用

func describe() -> String:
	var tgt := "%.0f°" % commanded_heading_deg if has_heading_command else "（无）"
	return "船员：舵手目标 %s　目标攻角 %.0f°　收放 %.1f°/s　疲劳 %.0f%%　偏差 %+.1f°" % [
		tgt, alpha_target, trim_rate_dps, fatigue * 100.0, alpha_error_deg]


func crew_quality() -> float:
	"""一句话概括船员现在有多能打：0 = 全废，1 = 满编精兵。面板上显示这个。"""
	var hands := clampf(float(hands_on_sails) / 6.0, 0.0, 1.5)
	return clampf(skill * hands * (1.0 - 0.7 * fatigue), 0.0, 1.2)
