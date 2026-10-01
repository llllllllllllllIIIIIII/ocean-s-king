class_name Crew
extends RefCounted

# Day 3 的"临时船员"：把玩家的意图（目标航向 / 目标点）翻译成**帆与舵的指令**。
#
# 它只有一个合法的影响通道：ShipDynamics.set_rudder() / trim_to_alpha()。
# 它碰不到船的速度和位置 —— 这正是"玩家不直接操船、船员执行调帆"这条
# 支柱（docs/01 支柱 3）在代码里的最小形态。
#
# Day 4 会把它换掉：真正的指挥链路要有技能、疲劳、执行耗时和抢风换舷的决策。
# Day 3 允许"瞬间且完美"，只求把风力→帆→船这条链子跑通。

const RUDDER_MAX := 35.0
const TRIM_TABLE_PATH := "res://data/defs/trim_table.json"

var ship: ShipDynamics
var target_heading_deg := 0.0
var has_target_heading := false
var target_point := Vector2.ZERO
var has_target_point := false
var trim_period := 0.5          # 秒  多久重新配平一次
var steer_gain := 1.2           # 度舵角 / 度航向误差

var alpha_main := 20.0          # 当前主帆攻角（度）
var _trim_timer := 1e9          # 第一帧就配平一次
var _tw: PackedFloat64Array = PackedFloat64Array()      # 查表：真风速轴
var _ta: PackedFloat64Array = PackedFloat64Array()      # 查表：视风角轴
var _alpha_grid: Array = []                             # [风速][视风角] -> 主帆攻角


func _init(ship_ref: ShipDynamics) -> void:
	ship = ship_ref
	_load_trim_table()


func _load_trim_table() -> void:
	"""船员手里的"操帆手册"：由 tools/aero_prototype.py --mode trim-table 生成。

	运行时插值查表，比现场搜索便宜三个数量级。表不在就退回一个保守的固定攻角。
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


func set_target_heading(deg: float) -> void:
	target_heading_deg = fposmod(deg, 360.0)
	has_target_heading = true
	has_target_point = false


func set_target_point(p: Vector2) -> void:
	target_point = p
	has_target_point = true


func step(delta: float) -> void:
	_update_target_heading()
	_trim_timer += delta
	if _trim_timer >= trim_period:
		_trim_timer = 0.0
		retrim()
	steer()


func _update_target_heading() -> void:
	if not has_target_point:
		return
	var d := target_point - ship.position_m()
	if d.length() > 1.0:
		target_heading_deg = fposmod(rad_to_deg(atan2(d.y, d.x)), 360.0)


func retrim() -> void:
	"""按**视风角**查表决定攻角 —— 水手看的就是帆上吃到的风。

	⚠️ 这里必须用视风角，不能用真风角（Day 3 现场踩到的坑）：
	按真风角查表意味着"配平"建立在"船正以某个速度航行"这个前提上。
	船一旦停住，视风退化成真风，同一个攻角会把帆收到背风侧 ——
	船侧滑 84.7°、船速永远是 0，而且再也起不来。
	按视风角查表，停着的时候查到的是"让帆吃上力"的收放，跑起来视风前移，
	自动收敛到最佳配平。配平表由 tools/aero_prototype.py --mode trim-table 生成。
	"""
	var tws := ship.wind_ship_frame().length()
	if tws < 0.3:
		return
	alpha_main = lookup_alpha(tws, ship.awa_deg())
	ship.trim_to_alpha(alpha_main)


func lookup_alpha(tws: float, awa: float) -> float:
	"""双线性插值查配平表：真风速 × 视风角 -> 主帆攻角。"""
	if _tw.is_empty() or _ta.is_empty() or _alpha_grid.is_empty():
		return alpha_main
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


func steer() -> void:
	"""最简单的舵手：P 控制。有目标点就追目标点，只给航向就守航向。"""
	if not has_target_heading and not has_target_point:
		ship.set_rudder(0.0)
		return
	var err := ShipPhysics.normalize180(target_heading_deg - ship.heading_deg())
	ship.set_rudder(clampf(err * steer_gain, -RUDDER_MAX, RUDDER_MAX))


func describe() -> String:
	var tgt := "%.0f°" % target_heading_deg if (has_target_heading or has_target_point) else "（无）"
	return "船员：目标航向 %s，主帆攻角 %.0f°，舵 %.0f°" % [
		tgt, alpha_main, float(ship.snapshot()["rudder_deg"])]
