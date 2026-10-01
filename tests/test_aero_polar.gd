extends SceneTree

# 第 3 层验证通道（docs/06）：逻辑/数值测试，无头、不渲染。
#
# 它守三件事：
#   1) 四项硬指标（docs/01 支柱 2）成立：死区边界、横风最快、顺风慢、最佳抢风角
#   2) GDScript 的实现与 Python 标定工具 tools/aero_prototype.py 算得一样
#      —— 两份实现会漂移，所以这里把 Python 的数值钉死成参考值
#   3) 运行时的 ShipDynamics 真的会动：横风能跑起来、顶风推不动
#
# 用法：
#   Godot.exe --headless --path . --script res://tests/test_aero_polar.gd
# 退出码 0 = 通过，1 = 有失败。

# tools/aero_prototype.py 在 2026-10-01 的输出（best-trim 稳态前进速度，m/s）
const PY_REF := {
	"6|45": 1.9434, "6|60": 2.3560, "6|90": 2.6266, "6|135": 2.2302, "6|180": 1.9671,
	"8|45": 2.4606, "8|60": 2.9631, "8|90": 3.3232, "8|135": 2.9021, "8|180": 2.5947,
	"10|45": 2.8627, "10|60": 3.4634, "10|90": 3.9195, "10|135": 3.5000, "10|180": 3.1686,
}
const KNOT := 0.514444

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_aero_polar ===")
	var phys := ShipPhysics.load_default()

	_criteria(phys)
	_parity_with_python(phys)
	_dynamics_smoke(phys)

	_finish()


# ---------------------------------------------------------------- 四项硬指标

func _criteria(phys: ShipPhysics) -> void:
	var tws := 8.0

	# ① 逆风死区：真风角 35-40 度以内无法推进
	var boundary := -1
	for twa in range(25, 61):
		if phys.speed_kn(tws, float(twa)) >= 0.5:
			boundary = twa
			break
	_check(boundary >= 35 and boundary <= 40,
		"① 死区边界落在 35-40 度（实测 %d 度）" % boundary)

	# ② 横风最快
	var fastest := 90
	var fastest_kn := phys.speed_kn(tws, 90.0)
	for twa in range(30, 181, 10):
		var s := phys.speed_kn(tws, float(twa))
		if s > fastest_kn:
			fastest = twa
			fastest_kn = s
	_check(fastest >= 75 and fastest <= 105,
		"② 横风最快（最快在 %d 度，%.2f 节）" % [fastest, fastest_kn])

	# ③ 顺风明显慢于横风
	var s90 := phys.speed_kn(tws, 90.0)
	var s180 := phys.speed_kn(tws, 180.0)
	_check(s180 < s90 * 0.9,
		"③ 顺风慢于横风（顺风 %.2f 节 vs 横风 %.2f 节）" % [s180, s90])

	# ④ 最佳抢风角：迎风速度分量最大的真风角
	var best_twa := 0
	var best_vmg := -1.0
	for twa in range(30, 61):
		var vmg := phys.speed_kn(tws, float(twa)) * cos(deg_to_rad(float(twa)))
		if vmg > best_vmg:
			best_vmg = vmg
			best_twa = twa
	_check(best_twa >= 40 and best_twa <= 45,
		"④ 最佳抢风角落在 40-45 度（实测 %d 度，迎风分量 %.2f 节）" % [best_twa, best_vmg])


# ---------------------------------------------------------------- 与 Python 一致

func _parity_with_python(phys: ShipPhysics) -> void:
	var worst := 0.0
	var worst_key := ""
	for key in PY_REF:
		var parts: PackedStringArray = str(key).split("|")
		var u: float = float(phys.best_trim(float(parts[0]), float(parts[1]))["u"])
		var ref: float = PY_REF[key]
		var rel: float = absf(u - ref) / ref
		if rel > worst:
			worst = rel
			worst_key = str(key)
	_check(worst < 0.02,
		"GDScript 与 Python 标定工具一致（最大偏差 %.2f%%，出现在 %s）" % [
			worst * 100.0, worst_key])


# ---------------------------------------------------------------- 运行时会动

func _dynamics_smoke(phys: ShipPhysics) -> void:
	# 横风：风从右舷打来，船员守住航向，船应该跑起来并且位置真的变了
	var ship := ShipDynamics.new(phys)
	var crew := Crew.new(ship)
	ship.set_pose(Vector2.ZERO, 0.0)          # 船首指向 +x
	crew.set_target_heading(0.0)
	var wind_beam := Vector2(0.0, -8.0)       # 空气朝 -y 走 = 风从右舷来
	_run(ship, crew, wind_beam, 200.0, 0.1)
	_check(ship.speed_kn() > 4.5 and ship.speed_kn() < 8.0,
		"横风跑起来（%.2f 节）" % ship.speed_kn())
	_check(ship.position_m().length() > 500.0,
		"位置由积分得到（200 秒走了 %.0f 米）" % ship.position_m().length())
	_check(absf(ship.heel_deg()) > 1.0 and absf(ship.heel_deg()) < 25.0,
		"横倾在合理区间（%.1f 度）" % ship.heel_deg())
	_check(absf(ship.leeway_deg()) < 12.0,
		"侧滑在合理区间（%.1f 度）" % ship.leeway_deg())

	# 顶风：风从船首正前方来，推不动 —— 这是死区在运行时的样子
	var irons := ShipDynamics.new(phys)
	var irons_crew := Crew.new(irons)
	irons.set_pose(Vector2.ZERO, 0.0)
	irons_crew.set_target_heading(0.0)
	var wind_head := Vector2(-8.0, 0.0)       # 空气朝 -x 走 = 风从船首正前方来
	_run(irons, irons_crew, wind_head, 120.0, 0.1)
	_check(irons.speed_kn() < 0.5,
		"顶风推不动（%.2f 节）" % irons.speed_kn())
	_check(irons.position_m().length() < 60.0,
		"顶风原地打转而不是硬走（位移 %.1f 米）" % irons.position_m().length())

	# 风越大越快：这是"船的运动来自风"的最直接证据
	var light := ShipDynamics.new(phys)
	var light_crew := Crew.new(light)
	light.set_pose(Vector2.ZERO, 0.0)
	light_crew.set_target_heading(0.0)
	_run(light, light_crew, Vector2(0.0, -4.0), 200.0, 0.1)
	var fresh := ShipDynamics.new(phys)
	var fresh_crew := Crew.new(fresh)
	fresh.set_pose(Vector2.ZERO, 0.0)
	fresh_crew.set_target_heading(0.0)
	_run(fresh, fresh_crew, Vector2(0.0, -10.0), 200.0, 0.1)
	_check(fresh.speed_kn() > light.speed_kn() * 1.2,
		"风大跑得快（4 m/s 风 %.2f 节 -> 10 m/s 风 %.2f 节）" % [
			light.speed_kn(), fresh.speed_kn()])

	# 从静止起步：不只是横风，**所有能走的真风角**都必须能自己起来。
	# 现场 bug 就出在这里：按"攻角"配平，船停住时视风退化成真风，
	# 同一个攻角会把帆收到背风侧（侧滑 84.7°、船速永远 0）。
	var stuck: PackedStringArray = []
	for twa in [45, 60, 90, 120, 148, 160, 180]:
		var s2 := ShipDynamics.new(phys)
		var c2 := Crew.new(s2)
		s2.set_pose(Vector2.ZERO, 0.0)
		var blow := deg_to_rad(float(twa) + 180.0)          # 风从船首起 twa 度来
		var w2 := Vector2(cos(blow), sin(blow)) * 8.0
		c2.set_target_heading(0.0)
		s2.step(0.0, w2)
		c2.retrim()
		_run(s2, c2, w2, 120.0, 0.1)
		if s2.speed_kn() < 3.0:
			stuck.append("%d°(%.2f 节)" % [twa, s2.speed_kn()])
	_check(stuck.is_empty(), "从静止起步：各真风角都能跑起来（卡住的：%s）"
		% ("无" if stuck.is_empty() else ", ".join(stuck)))

	# 失速之后能不能自己恢复：先把船顶进死区停住，再转出来必须重新跑起来。
	# 用户报的"我不管如何操纵船速一直显示为 0"就是这个场景。
	var rec := ShipDynamics.new(phys)
	var rec_crew := Crew.new(rec)
	rec.set_pose(Vector2.ZERO, 0.0)
	var w_fixed := Vector2(0.0, -8.0)          # 风从 +y（右舷）来
	rec_crew.set_target_heading(0.0)
	_run(rec, rec_crew, w_fixed, 60.0, 0.1)
	var running := rec.speed_kn()
	rec_crew.set_target_heading(90.0)          # 船首转向风来的方向 -> 顶进死区
	_run(rec, rec_crew, w_fixed, 150.0, 0.1)
	var luffed := rec.speed_kn()
	rec_crew.set_target_heading(0.0)           # 再转出来
	_run(rec, rec_crew, w_fixed, 150.0, 0.1)
	_check(running > 4.0 and luffed < 1.0 and rec.speed_kn() > 4.0,
		"失速后能自己恢复（跑 %.1f → 顶风停 %.1f → 转回来 %.2f 节）" % [
			running, luffed, rec.speed_kn()])


func _run(ship: ShipDynamics, crew: Crew, wind: Vector2, seconds: float, dt: float) -> void:
	"""驱动一艘船跑一段时间：船员下指令（调帆、打舵），船在风力下自己动。"""
	var steps := int(seconds / dt)
	for _i in steps:
		crew.step(dt)
		ship.step(dt, wind)


# ---------------------------------------------------------------- 断言框架

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] " + msg)
	else:
		_fails.append(msg)
		print("  [FAIL] " + msg)


func _finish() -> void:
	var ms := Time.get_ticks_msec() - _t0
	if _fails.is_empty():
		print("全部通过：%d 项断言，耗时 %.0f ms" % [_checks, ms])
		quit(0)
	else:
		print("失败 %d / %d 项：" % [_fails.size(), _checks])
		for f in _fails:
			print("  - " + f)
		quit(1)
