extends SceneTree

# M15 的验收：整条环球航线接通（docs/23 的 M15 卡片）。
#
# 五件事：
#   1. **闭环**：全球图的 13 段航段首尾相接，最后一段回到出发港（圣卢卡尔）；
#   2. **连通性**（验收第 1 条的字面版）：每一段航线的折线按 400 米采样，
#      没有一处落在干地上 —— 所以"全程没有必须穿陆地的段"；
#   3. **大西洋那趟不动**（v0.5 的验收不许回退）：单程航线仍然以巴西为终点；
#   4. **终点闩**（验收第 3 条）：四条船都回到圣卢卡尔 → `ending_ready`，
#      而且**是个闩**：之后船被洋流带走，旗标也不掉；
#   5. **真的开得动**：从圣卢卡尔按航线走完第一段（到加那利）——动力学那一路。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_circumnavigation ===")
	_test_loop_closure()
	_test_no_dry_legs()
	_test_atlantic_unchanged()
	_test_ending_latch()
	_test_first_leg_dynamic()
	_finish()


func _global() -> Voyage:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	return v


# ---------------------------------------------------------------- 1 闭环

func _test_loop_closure() -> void:
	var v := _global()
	var routes := v.sea.routes()
	_check(routes.size() == 13, "全球图有十三段航段（%d）" % routes.size())
	var chained := 0
	for i in routes.size() - 1:
		if str((routes[i] as Dictionary).get("to", "")) \
				== str((routes[i + 1] as Dictionary).get("from", "")):
			chained += 1
	_check(chained == routes.size() - 1, "十三段首尾相接（%d/%d）" % [chained, routes.size() - 1])
	_check(str((routes[routes.size() - 1] as Dictionary).get("to", ""))
		== str((routes[0] as Dictionary).get("from", "")),
		"最后一段回到第一段的起点（闭环）")
	_check(v.home_port_id() == "sanlucar", "归乡港 = 圣卢卡尔（%s）" % v.home_port_id())
	_check(v.goal_port_name().contains("圣卢卡尔"), "终点港名字从数据里来（%s）" % v.goal_port_name())
	# AI 与"掉线接管"用的目标点也应该指向归乡港
	var home := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sanlucar":
			home = Geom2D.centroid(p["shape"])
	_check(v.default_destination().distance_to(home) < 1.0,
		"默认目的地就是归乡港（相距 %.1f 米）" % v.default_destination().distance_to(home))


# ---------------------------------------------------------------- 2 连通性

func _test_no_dry_legs() -> void:
	"""每一段航线的折线按 400 米采样 —— 一处干地都不许有。"""
	var v := _global()
	var dry := 0
	var samples := 0
	var total_m := 0.0
	var bad_leg := ""
	for r in v.sea.routes():
		var pts := v.sea.route_points(r)
		for i in pts.size() - 1:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var d := v.sea.delta(a, b)
			total_m += d.length()
			var n := maxi(1, int(ceil(d.length() / 400.0)))
			for k in n + 1:
				var p := v.sea.wrap_pos(a + d * (float(k) / float(n)))
				samples += 1
				if v.sea.world.is_dry_land(p):
					dry += 1
					if bad_leg == "":
						bad_leg = str(r.get("id", "?"))
	_check(dry == 0, "十三段航线上一处干地都没有（采样 %d 点，%s）"
		% [samples, "第一处：" + bad_leg if bad_leg != "" else "全通过"])
	# 全程里程：史实约 56,000 真实公里（地图 ×125 的压缩系数）
	var real_km := total_m / 1000.0 * v.sea.real_time_scale()
	_check(real_km > 45000.0 and real_km < 70000.0,
		"全程里程合理（真实 %.0f 公里）" % real_km)


# ---------------------------------------------------------------- 3 大西洋不动

func _test_atlantic_unchanged() -> void:
	var v := Voyage.new()
	v.setup(Sea.ATLANTIC_PATH)
	_check(v.home_port_id() == "", "大西洋是单程航线 —— 没有归乡港（%s）" % v.home_port_id())
	_check(v.goal_port_name() == "圣阿莱克索", "大西洋那趟仍然以巴西为终点（%s）" % v.goal_port_name())
	var brazil := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sao_aleixo":
			brazil = Geom2D.centroid(p["shape"])
	_check(v.default_destination().distance_to(brazil) < 1.0, "默认目的地仍是圣阿莱克索")


# ---------------------------------------------------------------- 4 终点闩

func _test_ending_latch() -> void:
	var v := _global()
	var home := v.default_destination()
	v.fleet.goal = home
	# 四条船先都离开终点圈（闩要求"先离开过"）
	_place_all(v, home + Vector2(9000.0, 0.0))
	v.fleet.step_game(1.0, v.sea)
	_check(v.fleet.arrived.is_empty(), "刚出发时没人算抵达（离开过才算）")
	_check(not v.reached_destination, "还没到就不该宣布走完")
	# 四条船都回到圣卢卡尔的锚地圈
	_place_all(v, home + Vector2(120.0, 0.0))
	v.fleet.step_game(1.0, v.sea)
	v._check_fleet_arrival()
	_check(v.fleet.arrived.size() == v.fleet.count(), "四条船都算抵达（%d/%d）"
		% [v.fleet.arrived.size(), v.fleet.count()])
	_check(v.reached_destination and v.story.ending_ready, "触发 `ending_ready`（结算页的出口）")
	# 闩：船再被洋流带走，旗标也不掉
	_place_all(v, home + Vector2(25000.0, 0.0))
	v.fleet.step_game(1.0, v.sea)
	v._check_fleet_arrival()
	_check(v.reached_destination and v.story.ending_ready, "抵达是个闩：船被带走也不回退")
	# 结算页真的排得出来，而且不再写死"圣阿莱克索"
	var text := Settlement.text(v, v.journal, v.story)
	_check(text.contains("圣卢卡尔"), "结算页写的是归乡港（找了「圣卢卡尔」）")
	_check(not text.contains("圣阿莱克索"), "结算页不再写死巴西那个终点")


func _place_all(v: Voyage, pos: Vector2) -> void:
	"""把四条船都摆到同一个位置：AI 那三条走 `place_ai`，**本机那条**要先摆船
	再把摘要灌进船队（`Fleet.pose_of()` 对本机读的就是那份摘要）。"""
	for id in v.fleet.ids():
		if id == v.fleet.local_id:
			v.ship.set_pose(pos, 90.0)
			v._publish_local_summary()
		else:
			v.fleet.place_ai(id, pos, 90.0)


# ---------------------------------------------------------------- 5 第一段真的开得动

func _test_first_leg_dynamic() -> void:
	"""从圣卢卡尔按航线走到加那利（3.8 地图公里）—— 动力学那一路的第一段。"""
	var v := _global()
	v.encounters_enabled = false
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.start_route_follow()
	_check(v.following_route, "跟上了航线")
	var canary := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "santa_cruz":
			canary = Geom2D.centroid(p["shape"])
	var t := 0.0
	var closest := v.sea.dist(v.ship.position_m(), canary)
	var budget := 20000.0
	while t < budget and closest > 600.0:
		v.tick(DT)
		t += DT
		closest = minf(closest, v.sea.dist(v.ship.position_m(), canary))
		if v.sea.world.is_dry_land(v.ship.position_m()):
			break
	_check(closest <= 600.0, "第一段开到了加那利锚地（最近 %.0f 米，用了 %.1f 个游戏小时）"
		% [closest, t / 3600.0])
	_check(not v.sea.world.is_dry_land(v.ship.position_m()), "这一路没有开上干地")


# ---------------------------------------------------------------- 收尾

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
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
