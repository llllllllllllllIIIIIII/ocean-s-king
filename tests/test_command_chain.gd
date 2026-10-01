extends SceneTree

# Day 4 的验收测试：指挥链路（docs/01 支柱 3）。
#
# 它守的是这一条因果链：
#     玩家只下"目标点 / 帆档 / 抛锚 / 调人员"
#       → 航海官决定航法（保持/转向/抢风换舷）
#         → 船员收放帆与打舵（**耗时 = f(技能,人数,疲劳)，而且不完美**）
#           → 船在风力下自己动
#
# 四条验收（docs/02 Day 4）：
#   1. 点一个目标点，船员自己去调帆，船真的往那边走
#   2. 帆态面板能让你判断"船慢是因为风不对，还是船员没调好"（面板是画给人看的，
#      这里测的是它依赖的那几个量确实存在且会变）
#   3. 把主要船员调走（或让他们累垮），船明显变笨拙 —— 这套设计成立的核心证据
#   4. 船长离船后，船仍在按航向行驶（大副自动舵）
#
# 用法：
#   Godot.exe --headless --path . --script res://tests/test_command_chain.gd
# 退出码 0 = 通过，1 = 有失败。

const KNOT := 0.514444
const DT := 0.2

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_command_chain ===")
	_test_target_point()
	_test_beat_upwind()
	_test_trim_takes_time()
	_test_crew_quality_matters()
	_test_first_mate_autopilot()
	_test_anchor_and_sail_levels()
	_finish()


# ---------------------------------------------------------------- 工具

func _world() -> Array:
	"""一艘停在海中央的船 + 一场恒定不变的风（测试要可复现，所以没有阵风）。"""
	var phys := ShipPhysics.load_default()
	var ship := ShipDynamics.new(phys)
	var wind := WindField.new(8.0, 20.0)
	wind.time_scale = 0.0
	wind.gust_gain = 0.0
	var orders := ShipOrders.new()
	var nav := Navigator.new(orders)
	var crew := Crew.new(ship)
	ship.set_pose(Vector2.ZERO, 0.0)
	ship.step(0.0, wind.velocity_world())
	crew.retrim()
	return [ship, wind, orders, nav, crew]


func _tick(w: Array, seconds: float) -> void:
	"""走一遍和游戏里**同一条**指挥链路。"""
	_tick_watch(w, seconds, null)


func _tick_watch(w: Array, seconds: float, watch: Variant) -> float:
	"""同上，但顺便记录船离 watch 点的**最近距离**（用来判断"到底有没有走过去"）。

	为什么要记最近距离：船一到目标点，航海官就把目标点清掉了，
	之后它会保持航向继续往前开 —— 只看终点距离会以为它没走到。
	"""
	var ship: ShipDynamics = w[0]
	var wind: WindField = w[1]
	var orders: ShipOrders = w[2]
	var nav: Navigator = w[3]
	var crew: Crew = w[4]
	var wind_vec := wind.velocity_world()
	var closest := 1e12
	for _i in int(seconds / DT):
		nav.decide(ship)
		crew.set_target_heading(nav.target_heading_deg)
		crew.hands_on_sails = orders.hands_on_sails
		ship.set_sail_area_scale(orders.sail_area_scale())
		ship.set_anchored(orders.anchored)
		crew.step(DT)
		ship.step(DT, wind_vec)
		if watch != null:
			closest = minf(closest, ship.position_m().distance_to(watch as Vector2))
	return closest


# ---------------------------------------------------------------- 1 目标点

func _test_target_point() -> void:
	var w := _world()
	var ship: ShipDynamics = w[0]
	var orders: ShipOrders = w[2]
	var nav: Navigator = w[3]
	# 横风方向放一个 1200 米外的目标点（真风角 70 度，能走）
	var target := Vector2(cos(deg_to_rad(90.0)), sin(deg_to_rad(90.0))) * 1200.0
	orders.set_target_point(target)
	var d0 := ship.position_m().distance_to(target)
	var closest := _tick_watch(w, 600.0, target)
	_check(closest < 60.0,
		"点了目标点船就真的走过去（最近到过 %.0f m，出发时 %.0f m）" % [closest, d0])
	_check(not orders.has_target_point,
		"到点之后航海官自己收工（目标点已清空）")
	_check(nav.method == Navigator.Method.STEER or nav.method == Navigator.Method.HOLD,
		"航海官按目标点决定航法（%s）" % nav.method_name())
	_check(ship.speed_kn() > 3.0, "路上有速度（%.2f 节）" % ship.speed_kn())


# ---------------------------------------------------------------- 2 抢风换舷

func _test_beat_upwind() -> void:
	var w := _world()
	var ship: ShipDynamics = w[0]
	var orders: ShipOrders = w[2]
	var nav: Navigator = w[3]
	# 目标点在风的来向上（正顶风）—— 直接走是走不到的，必须抢风
	var target := Vector2(cos(deg_to_rad(20.0)), sin(deg_to_rad(20.0))) * 700.0
	orders.set_target_point(target)
	_tick(w, 240.0)
	_check(nav.method == Navigator.Method.BEAT,
		"顶风目标触发抢风航法（%s）" % nav.method_name())
	var twa := ship.twa_deg()
	_check(twa > 32.0 and twa < 60.0,
		"抢风时船贴着死区边界外侧走，不会硬顶（真风角 %.0f°）" % twa)
	var d0 := ship.position_m().distance_to(target)
	var closest := _tick_watch(w, 1500.0, target)
	_check(closest < d0 * 0.6,
		"抢风真的能把船一点点顶上去（出发 %.0f m → 最近 %.0f m）" % [d0, closest])


# ---------------------------------------------------------------- 3 换舷要花时间

func _time_to_retrim(w: Array, shift_deg: float, max_seconds: float) -> Array:
	"""量"手上功夫"：风向突然转了 shift_deg，船员要多久才能把帆重新收好。

	返回 [耗时秒, 帆实际摆动角度]。这一步是纯执行器 —— 量它才能把
	"航海官想得快" 和 "船员干得慢" 分开。
	"""
	var ship: ShipDynamics = w[0]
	var wind := w[1] as WindField
	var crew: Crew = w[4]
	var before := float(ship.snapshot()["sail_main_deg"])
	wind.base_from_dir += shift_deg              # 风向突变（Day 6 会有这个事件）
	wind.from_dir_deg = wind.base_from_dir       # time_scale=0，直接把新风向落生效
	var t := 0.0
	var settled_for := 0.0
	var wind_vec := wind.velocity_world()
	while t < max_seconds:
		crew.step(DT)
		ship.step(DT, wind_vec)
		t += DT
		if not crew.trim_busy and absf(ShipPhysics.normalize180(
				float(ship.snapshot()["sail_main_deg"]) - before)) > 5.0:
			settled_for += DT
			if settled_for > 2.0:                # 稳定两秒才算真的收好
				break
		else:
			settled_for = 0.0
	var swung := absf(ShipPhysics.normalize180(
		float(ship.snapshot()["sail_main_deg"]) - before))
	return [t, swung]


func _test_trim_takes_time() -> void:
	var w := _world()
	# 先跑稳（横风）
	_tick(w, 120.0)
	var res := _time_to_retrim(w, 100.0, 300.0)
	_check(float(res[0]) > 8.0, "风向突变后重新配平不是瞬间完成的（耗时 %.1f 秒）" % res[0])
	_check(float(res[1]) > 45.0, "帆真的被收放了 %.0f°" % res[1])


# ---------------------------------------------------------------- 4 船员好不好

func _test_crew_quality_matters() -> void:
	var results := []
	for setup in [{"skill": 0.9, "fatigue": 0.1, "hands": 6},
			{"skill": 0.35, "fatigue": 0.7, "hands": 2}]:
		var w := _world()
		var crew: Crew = w[4]
		var orders: ShipOrders = w[2]
		crew.skill = float(setup["skill"])
		crew.fatigue = float(setup["fatigue"])
		orders.set_hands(int(setup["hands"]))
		var ship: ShipDynamics = w[0]
		_tick(w, 120.0)                                  # 先在横风上跑稳
		var rate := crew.trim_rate_dps
		var res := _time_to_retrim(w, 100.0, 400.0)
		results.append({"rate": rate, "time": float(res[0]), "name": setup})

	var good: Dictionary = results[0]
	var bad: Dictionary = results[1]
	_check(float(good["rate"]) > float(bad["rate"]) * 2.5,
		"好船员收放快得多（%.1f°/s vs %.1f°/s）" % [good["rate"], bad["rate"]])
	_check(float(bad["time"]) > float(good["time"]) * 2.0,
		"累垮的三个人换舷明显更慢（%.1f 秒 vs %.1f 秒）" % [good["time"], bad["time"]])


# ---------------------------------------------------------------- 5 大副自动舵

func _test_first_mate_autopilot() -> void:
	var w := _world()
	var ship: ShipDynamics = w[0]
	var orders: ShipOrders = w[2]
	var nav: Navigator = w[3]
	# 船长离船 = 之后不再有任何人为输入，只剩航海官（大副）与船员
	var target := Vector2(cos(deg_to_rad(120.0)), sin(deg_to_rad(120.0))) * 4000.0
	orders.set_target_point(target)
	_tick(w, 300.0)
	var heading_err := absf(ShipPhysics.normalize180(
		nav.target_heading_deg - ship.heading_deg()))
	_check(heading_err < 15.0,
		"大副自动舵能把航向稳在目标上（偏差 %.1f°）" % heading_err)
	_check(ship.speed_kn() > 2.0, "大副接管时船照常在走（%.2f 节）" % ship.speed_kn())


# ---------------------------------------------------------------- 6 锚与帆档

func _test_anchor_and_sail_levels() -> void:
	var w := _world()
	var ship: ShipDynamics = w[0]
	var orders: ShipOrders = w[2]
	orders.set_target_point(Vector2(0.0, 1200.0))
	_tick(w, 400.0)
	var cruising := ship.speed_kn()
	_check(cruising > 3.0, "全帆横风巡航（%.2f 节）" % cruising)

	orders.set_sail_level(ShipOrders.SailLevel.REEF)
	_tick(w, 400.0)
	var reefed := ship.speed_kn()
	_check(reefed < cruising * 0.85, "缩帆明显变慢（%.2f 节 → %.2f 节）" % [cruising, reefed])

	orders.anchored = true
	orders.set_sail_level(ShipOrders.SailLevel.FURLED)
	_tick(w, 60.0)
	_check(ship.speed_kn() < 0.2, "抛锚后船停住（%.2f 节）" % ship.speed_kn())
	var drift := ship.position_m().length()
	_tick(w, 60.0)
	_check(absf(ship.position_m().length() - drift) < 20.0,
		"抛锚后不再漂走（位置变化 %.1f 米）" % absf(ship.position_m().length() - drift))


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
