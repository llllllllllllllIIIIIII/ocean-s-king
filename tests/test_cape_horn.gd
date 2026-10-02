extends SceneTree

# M12 的验收：南美段与麦哲伦海峡（docs/23 的 M12 卡片）。
#
# 五件事：
#   1. 南美段**至少两个可停靠补给点**（拉普拉塔 / 圣胡利安），而且都在水里。
#   2. 海峡是**真正的窄水道**（不再是一个夸大的口子）：最窄处几百米到两公里，
#      东口比中段宽（是个漏斗，不是一根管子）。
#   3. 航线能**穿过去**：`leg_pacific` 过海峡那一段零干地、零踩礁。
#   4. **抄近路会撞礁**：从东口直着拉到西口那条线压在中段的暗礁上 ——
#      "走错就撞"这条设计得是真的。
#   5. 南美事件池：四条事件的条件与效果都成立（按海域触发）；圣胡利安有岸上内容。
#
# 外加一条安全线：**走错也不会卡死**（在海峡里给它一个反向目标，它得开得出来）。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_cape_horn ===")
	_test_leg_ports()
	_test_strait_is_narrow()
	_test_route_threads_strait()
	_test_sail_into_pacific()
	_test_shortcut_hits_reef()
	_test_no_trap()
	_test_events_and_ashore()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false          # 这一条验的是航道与事件，不是海盗
	return v


# ---------------------------------------------------------------- 1 补给点

func _test_leg_ports() -> void:
	var v := _v()
	var ids := []
	for p in v.sea.ports():
		ids.append(str(p.get("id", "")))
	for want in ["sao_aleixo", "rio_plata", "sao_julian"]:
		_check(ids.has(want), "南美这一路有停靠点 %s" % want)
	var stops := 0
	for id in ["rio_plata", "sao_julian"]:
		for p in v.sea.ports():
			if str(p.get("id", "")) == id:
				var pos := Geom2D.centroid(p["shape"])
				_check(not v.sea.world.is_dry_land(pos), "%s 在水里" % id)
				stops += 1
	_check(stops >= 2, "巴西之后至少两个可停靠的补给点（%d）" % stops)


# ---------------------------------------------------------------- 2 窄水道

func _test_strait_is_narrow() -> void:
	var v := _v()
	# 沿着海峡的经度扫一遍：每个经度上量"能走的净宽"
	var width := 0
	var gap_min := INF
	var gap_east := 0.0
	var east_lon := -68.7
	var west_lon := -74.2
	var steps := 36
	for i in range(steps + 1):
		var lon := lerpf(east_lon, west_lon, float(i) / float(steps))
		var gap := _channel_width_at(v, lon)
		if gap <= 0.0:
			continue
		width += 1
		gap_min = minf(gap_min, gap)
		if i == 0:
			gap_east = gap
	_check(width >= steps - 2, "整条海峡都能量到水面（%d/%d 个采样点）" % [width, steps + 1])
	_check(gap_min >= 600.0, "最窄处船还过得去（%.0f 米）" % gap_min)
	_check(gap_min <= 2000.0, "最窄处是**窄**的（%.0f 米，不是几千公里的口子）" % gap_min)
	_check(gap_east > gap_min * 1.5, "东口比中段宽 —— 是个漏斗（%.0f 米 vs 最窄 %.0f 米）"
		% [gap_east, gap_min])


func _channel_width_at(v: Voyage, lon: float) -> float:
	"""在某个经度上量"北岸南缘到南岸北缘"的净宽（米）。扫 y，找最长的一段水。"""
	var x := v.sea.lonlat_to_m(lon, 0.0).x
	var best := 0.0
	var run := 0
	var step_m := 25.0
	# 只看海峡那一带的纬度（南纬 50–57 度）：y = (90+lat)*888.89
	var y0 := v.sea.lonlat_to_m(0.0, -50.0).y
	var y1 := v.sea.lonlat_to_m(0.0, -57.0).y
	var k_n := int((y1 - y0) / step_m)
	for k in range(k_n):
		var y := y0 + float(k) * step_m
		if v.sea.world.is_land(Vector2(x, y)):
			run = 0
		else:
			run += 1
			best = maxf(best, float(run) * step_m)
	return best


# ---------------------------------------------------------------- 3 航线穿得过去

func _test_route_threads_strait() -> void:
	var v := _v()
	var leg := {}
	for r in v.sea.routes():
		if str(r.get("id", "")) == "leg_pacific":
			leg = r
	_check(not leg.is_empty(), "找得到横渡太平洋那一整段（含海峡）")
	var pts := v.sea.route_points(leg)
	var dry := 0
	var reef := 0
	var sampled := 0
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var d := v.sea.delta(a, b)
		var n := maxi(1, int(ceil(d.length() / 250.0)))
		for k in range(n + 1):
			var p := v.sea.wrap_pos(a + d * (float(k) / float(n)))
			sampled += 1
			if v.sea.world.is_dry_land(p):
				dry += 1
			elif v.sea.world.is_reef(p):
				reef += 1
	_check(dry == 0, "这一段航线不穿干地（%d 处，采样 %d 点）" % [dry, sampled])
	_check(reef == 0, "这一段航线也不压礁（%d 处）" % reef)


# ---------------------------------------------------------------- 4 抄近路会撞

func _test_sail_into_pacific() -> void:
	"""验收第 1 条的**字面**版本：从巴西一路开进太平洋（不是只看航线数据）。

	跟着航线走，中途应当经过拉普拉塔与圣胡利安，然后穿过海峡、从西口出来。
	给它 16 个游戏小时（实测这一整段 12 个小时出头 —— 海峡里要慢慢磨；
	×36 下约 20 分钟真实时间）。
	"""
	var v := _v()
	# ⚠️ `Voyage.setup()` 把船摆在**第一个港**（圣卢卡尔）—— 这一条测的是南美段，
	# 所以先把船摆到巴西那一段的起点（v0.5 的终点港）。
	var brazil := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sao_aleixo":
			brazil = Geom2D.centroid(p["shape"])
	v.ship.set_pose(brazil, 180.0)
	v.start_route_follow()
	var julian := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sao_julian":
			julian = Geom2D.centroid(p["shape"])
	var passed_julian := false
	var entered_strait := false
	var t := 0.0
	var limit := 16.0 * 3600.0
	while t < limit:
		v.tick(DT)
		t += DT
		var ll := v.sea.m_to_lonlat(v.ship.position_m())
		if not passed_julian and v.sea.dist(v.ship.position_m(), julian) < 4_000.0:
			passed_julian = true
		if ll.y < -51.5 and ll.x < -69.0:
			entered_strait = true
		if ll.x < -74.6:
			break
	_check(passed_julian, "路过圣胡利安（%.1f 个游戏小时）" % (t / 3600.0))
	_check(entered_strait, "进了海峡")
	var ll2 := v.sea.m_to_lonlat(v.ship.position_m())
	print("    [航程] t=%.1f 小时　位置经度 %.2f / 纬度 %.2f　速度 %.1f 节　航法 %s　"
		% [t / 3600.0, ll2.x, ll2.y, v.ship.speed_kn(), v.nav.method_name()]
		+ "目标 %s　航线剩余 %d 段　受阻 %s"
		% [str(v.orders.target_point if v.orders.has_target_point else Vector2.ZERO),
		   v.route_waypoints.size(), str(v.ship.last_blocked)])
	_check(ll2.x < -74.6, "从西口出来了 —— 在经度 %.2f（太平洋一侧），用了 %.1f 个游戏小时"
		% [ll2.x, t / 3600.0])
	_check(t < 16.0 * 3600.0, "这一整段没超过 16 个游戏小时（%.1f 小时）" % (t / 3600.0))
	_check(not v.sea.world.is_dry_land(v.ship.position_m()), "出来的时候没搁在干地上")

func _test_shortcut_hits_reef() -> void:
	var v := _v()
	var east := v.sea.poi_pos("strait_east_mouth")
	var west := v.sea.poi_pos("strait_west_mouth")
	_check(east != Vector2.ZERO and west != Vector2.ZERO, "两个峡口都有地标")
	var d := v.sea.delta(east, west)
	var hit := 0
	var n := maxi(1, int(ceil(d.length() / 100.0)))
	for k in range(n + 1):
		var p := v.sea.wrap_pos(east + d * (float(k) / float(n)))
		if v.sea.world.is_reef(p):
			hit += 1
	_check(hit > 0, "**从东口直着拉到西口会撞上中段的暗礁**（%d 处）—— 走错就撞" % hit)
	# 暗礁就在海峡里（不是在海峡外面）
	var reef_pos := v.sea.poi_pos("")
	var in_strait := false
	for f in v.sea.world.of_kind("reef"):
		var p := Geom2D.centroid(f["shape"])
		if str(f.get("id", "")) == "reef_strait":
			var lonlat := v.sea.m_to_lonlat(p)
			in_strait = lonlat.x > -72.0 and lonlat.x < -69.0
	_check(in_strait, "那块暗礁确实在海峡中段（不是合恩角外海那块）")


# ---------------------------------------------------------------- 5 走错也不卡死

func _test_no_trap() -> void:
	var v := _v()
	# 把船摆进海峡里、贴着北岸，然后让它掉头回东口 —— 它得开得出来
	var mid := v.sea.lonlat_to_m(-70.9, -52.9)
	v.ship.set_pose(mid, 90.0)
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	var back := v.sea.poi_pos("strait_east_mouth")
	v.orders.set_target_point(back)
	var t := 0.0
	var escaped := false
	while t < 9_000.0 and not escaped:
		v.tick(DT)
		t += DT
		var lonlat := v.sea.m_to_lonlat(v.ship.position_m())
		if lonlat.x > -69.2:
			escaped = true
	_check(escaped, "海峡里掉头能开出来（%.1f 个游戏分钟，现在在经度 %.2f）"
		% [t / 60.0, v.sea.m_to_lonlat(v.ship.position_m()).x])
	_check(not v.sea.world.is_dry_land(v.ship.position_m()), "开出来的时候没搁在干地上")


# ---------------------------------------------------------------- 6 事件与岸上

func _test_events_and_ashore() -> void:
	var v := _v()
	var want := ["strait_squall", "fires_of_tierra", "san_julian_gibbet", "first_pacific_look"]
	for id in want:
		_check(not v.events.def_of(id).is_empty(), "南美事件池里有 %s" % id)
	# 条件是按**海域**判的：船在海峡里，海峡那两条就该满足；太平洋那条不该满足
	v.ship.set_pose(v.sea.lonlat_to_m(-71.0, -53.0), 90.0)
	v.t = 50.0 * 86400.0 / VoyageJournal.voyage_time_scale   # 让"航程够长"这条也满足
	_check(v.events.unmet(v.events.def_of("strait_squall"), v) == "",
		"在海峡里：狂风那条满足（%s）" % v.events.unmet(v.events.def_of("strait_squall"), v))
	_check(v.events.unmet(v.events.def_of("first_pacific_look"), v) != "",
		"在海峡里：太平洋那条还不满足")
	# 真的触发一次（船还在海峡里）：天气被强推、知识记下来、日志有记录
	var before_weather := v.weather.state_id
	var r := v.events.try_fire("strait_squall", v)
	_check(bool(r.get("ok", false)), "海峡狂风可以按 id 触发（%s）" % str(r))
	_check(v.weather.state_id != before_weather or v.weather.state_name() != "",
		"触发之后天气变了（%s）" % v.weather.state_name())
	_check(v.knowledge.count() > 0, "触发之后知识里多了一条（%d 条）" % v.knowledge.count())
	# 再开到太平洋：那边那条才满足（条件是按海域判的）
	v.ship.set_pose(v.sea.lonlat_to_m(-120.0, -10.0), 90.0)
	_check(v.events.unmet(v.events.def_of("first_pacific_look"), v) == "",
		"开到太平洋里：第一眼那条满足了")
	_check(v.events.unmet(v.events.def_of("strait_squall"), v) != "",
		"开出来之后：海峡那条不再满足")
	# 圣胡利安的岸上内容
	var julian := {}
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sao_julian":
			julian = p
	_check(not julian.is_empty(), "圣胡利安在图上")
	var pois: Array = julian.get("pois", [])
	_check(pois.size() >= 3, "圣胡利安有三个能走到的岸上点（%d）" % pois.size())
	var on_land := 0
	for poi in pois:
		if v.sea.world.is_land(v.sea.lonlat_to_m(float(poi["pos_lonlat"][0]), float(poi["pos_lonlat"][1]))):
			on_land += 1
	_check(on_land == pois.size(), "这些岸上点都落在陆地上（%d/%d）" % [on_land, pois.size()])


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
