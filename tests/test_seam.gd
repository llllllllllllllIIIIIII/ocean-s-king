extends SceneTree

# M12 的第一步：**让船真的能跨过接缝**（M9 欠的那笔账，docs/23 的 M12 卡片）。
#
# 全球图是**圆柱**：从西往东绕回来必然跨过 180°。M9 把"查询与索引"那一层卷起来了，
# 这一期把**船**这一层接上 —— 积分、方位、抵达判定、航程记账、远端插值
# 全部走"最短的一边"。这份测试就是那件事的护栏：
#
#   1. 船把接缝当**普通海面**开过去：位置会从 ~0 跳到 ~320km 那一侧，
#      但**一帧的位移始终是小量**（不是瞬移），总航程约等于两点间的直线距离
#      （不是"绕地球一圈"那 320 公里）。
#   2. 导航官的方位指**西**（最短那边），不是指东绕一圈。
#   3. 抵达判定与航线跟随跨得过接缝。
#   4. 平面海域（大西洋）**一个数都不变**（wrap_width = 0）。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_seam ===")
	_test_wrap_widths()
	_test_ship_crosses_seam()
	_test_ai_crosses_seam()
	_test_flat_world_unchanged()
	_finish()


func _global_voyage() -> Voyage:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false          # 这一条验的是几何，不是海盗
	return v


# ---------------------------------------------------------------- 1 世界是圆柱

func _test_wrap_widths() -> void:
	var v := _global_voyage()
	var w := v.sea.size_m().x
	_check(v.sea.wraps(), "全球图是圆柱（%s）" % str(v.sea.size_m()))
	_check(is_equal_approx(v.ship.wrap_width, w), "船知道世界的宽度（%.0f）" % v.ship.wrap_width)
	_check(is_equal_approx(v.nav.wrap_width, w), "导航官知道世界的宽度（%.0f）" % v.nav.wrap_width)
	_check(is_equal_approx(v.fleet.wrap_width, w), "船队插值也知道（%.0f）" % v.fleet.wrap_width)
	# 接缝两边是同一个地方：坐标加一整圈 → 同一个点
	var p := Vector2(3_000.0, 80_000.0)
	_check(v.sea.dist(p, p + Vector2(w, 0.0)) < 1.0, "加一整圈还是同一个点")
	_check(v.sea.dist(p, Vector2(w - 3_000.0, 80_000.0)) < 6_100.0,
		"跨缝的两点距离走最短一边（%.0f 米）" % v.sea.dist(p, Vector2(w - 3_000.0, 80_000.0)))


# ---------------------------------------------------------------- 2 玩家那条船开过去

func _test_ship_crosses_seam() -> void:
	var v := _global_voyage()
	var w := v.sea.size_m().x
	var start := Vector2(2_000.0, 80_000.0)          # 缝东 2 公里
	var goal := Vector2(w - 2_000.0, 80_000.0)       # 缝西 2 公里（最短 4 公里）
	v.ship.set_pose(start, 270.0)                    # 船头朝西
	v.orders.set_target_point(goal)
	var straight := v.sea.dist(start, goal)
	_check(straight < 5_000.0, "两点之间最短只有 %.0f 米（不是绕一圈的 %.0f 米）"
		% [straight, w])
	# 一帧一帧地开：记下"每一帧走了多远"（按最短一边算）与总路程
	var path := 0.0
	var max_step := 0.0
	var wrapped_once := false
	var was_east := true
	var t := 0.0
	var limit := 6_000.0
	while t < limit and v.orders.has_target_point:
		var before := v.ship.position_m()
		v.tick(DT)
		var after := v.ship.position_m()
		var d := v.sea.dist(before, after)
		path += d
		max_step = maxf(max_step, d)
		var east := after.x < w * 0.5
		if was_east and not east:
			wrapped_once = true
		was_east = east
		t += DT
	_check(wrapped_once, "船真的跨过了接缝（一帧还是小步，位置自己卷到了另一侧）")
	_check(max_step < 30.0, "没有任何一帧是瞬移（最大单帧位移 %.2f 米）" % max_step)
	_check(not v.orders.has_target_point, "跨过接缝之后到了目标点（用了 %.1f 个游戏分钟）" % (t / 60.0))
	_check(path < straight * 4.0, "总路程没有绕地球一圈（%.0f 米 vs 直线 %.0f 米）" % [path, straight])
	_check(v.journal.distance_m < straight * 4.0,
		"航程记的是最短那一边（%.0f 米）" % v.journal.distance_m)
	_check(v.journal.distance_m > straight * 0.5, "航程没有少记（%.0f 米）" % v.journal.distance_m)


# ---------------------------------------------------------------- 3 AI 船也开得过去

func _test_ai_crosses_seam() -> void:
	var v := _global_voyage()
	var w := v.sea.size_m().x
	var ai := AbstractShip.new()
	ai.setup("ai_test", "试航的船", Vector2(w - 1_500.0, 90_000.0), 90.0)
	ai.waypoints = [Vector2(1_500.0, 90_000.0)]      # 目标在缝的另一边
	ai.sail_level = 0
	var wrapped_once := false
	var was_west := true
	var max_step := 0.0
	var guard := 0
	while not ai.waypoints.is_empty() and guard < 20_000:
		var before := ai.pos
		ai.step(DT, v.sea)
		max_step = maxf(max_step, v.sea.dist(before, ai.pos))
		var west := ai.pos.x > w * 0.5
		if was_west and not west:
			wrapped_once = true
		was_west = west
		guard += 1
	_check(wrapped_once, "AI 船也跨过了接缝（%d 步）" % guard)
	_check(max_step < 30.0, "AI 也没有瞬移（最大单帧 %.2f 米）" % max_step)
	_check(ai.waypoints.is_empty(), "AI 到了那个航点（没被接缝卡住）")


# ---------------------------------------------------------------- 4 平面海域不变

func _test_flat_world_unchanged() -> void:
	var v := Voyage.new()
	v.setup(Sea.ATLANTIC_PATH)
	_check(not v.sea.wraps(), "大西洋还是平面（不是圆柱）")
	_check(is_zero_approx(v.ship.wrap_width), "船的 wrap_width 是 0（老海域一个数不变）")
	_check(is_zero_approx(v.nav.wrap_width), "导航官的 wrap_width 是 0")
	# 平面海域的距离就是普通欧氏距离：横跨 48 公里就是 48 公里
	var a := Vector2(1_000.0, 1_000.0)
	var b := Vector2(47_000.0, 1_000.0)
	_check(is_equal_approx(v.sea.dist(a, b), 46_000.0),
		"平面海域的距离照常（%.0f 米）" % v.sea.dist(a, b))


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
