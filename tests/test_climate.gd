extends SceneTree

# M13 的验收：季节 · 季风 · 飓风 · 坏血病 · 断粮 · 老化（docs/23 的 M13 卡片）。
#
# 六件事：
#   1. 真源自检：四季 / 两条季风带 / 两个飓风窗口 / 坏血病、断粮、老化的数。
#   2. **季风窗口**（验收第 1 条）：同一段航线，窗口内外**真的走得不一样快**。
#   3. 飓风季：在窗口里才危险；"等"（过了月份）与"绕"（换个纬度）都成立。
#   4. **坏血病**（验收第 3 条）：长期只有咸肉饼干 → 健康掉；靠港补给 → 清零。
#   5. **断粮断水**（验收第 2 条）：无补给的长航程**必然减员**；补给够就活着到港。
#   6. 老化：在海上待久了船体会自己掉；而且这些数都在真源里。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_climate ===")
	_test_truth_source()
	_test_seasons_follow_calendar()
	_test_monsoon_window_matters()
	_test_hurricane_season()
	_test_scurvy()
	_test_attrition_and_wear()
	_test_hazards()
	_test_pacific_content()
	_test_aground_escape()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false          # 这一条验的是气候与消耗，不是海盗
	return v


func _set_day(v: Voyage, day_index: float) -> void:
	v.t = day_index * 86400.0 / VoyageJournal.voyage_time_scale


# ---------------------------------------------------------------- 1 真源

func _test_truth_source() -> void:
	var d := Climate.defs()
	_check((d.get("seasons", []) as Array).size() == 4, "四季（%d）" % (d.get("seasons", []) as Array).size())
	_check((d.get("monsoon", []) as Array).size() >= 2, "至少两条季风带（%d）"
		% (d.get("monsoon", []) as Array).size())
	_check((d.get("hurricane", []) as Array).size() >= 2, "至少两个飓风窗口（%d）"
		% (d.get("hurricane", []) as Array).size())
	for key in ["scurvy", "attrition", "wear"]:
		_check(d.has(key), "真源里有 %s 这一块" % key)
	_check(Climate.defs().has("seasons") and not Climate.defs().is_empty(), "气候表读得出来")


# ---------------------------------------------------------------- 2 季节跟着日历

func _test_seasons_follow_calendar() -> void:
	var v := _v()
	_set_day(v, 0.0)                       # 1519-09-20
	var s0 := Climate.season_id_at(0.0)
	_check(s0 == "autumn", "出发那天是秋（%s）" % Climate.season_name_at(0.0))
	var winter := 120.0 * 86400.0 / VoyageJournal.voyage_time_scale
	_check(Climate.season_id_at(winter) == "winter",
		"四个月后入冬（%s）" % Climate.season_name_at(winter))
	# 季节只跟日期走：同一天、两个不同的 Voyage 得到同一个季节
	var v2 := _v()
	v2.t = winter
	_check(Climate.season_id_at(v2.t) == Climate.season_id_at(winter), "同一时刻同一个季节")


# ---------------------------------------------------------------- 3 季风窗口

func _test_monsoon_window_matters() -> void:
	# 北印度洋（纬 10 度）：夏天与冬天的季风不一样
	var summer := 300.0 * 86400.0 / VoyageJournal.voyage_time_scale   # 7 月前后
	var winter := 120.0 * 86400.0 / VoyageJournal.voyage_time_scale   # 1 月前后
	var shift_s := Climate.wind_shift_deg(10.0, summer)
	var shift_w := Climate.wind_shift_deg(10.0, winter)
	var gain_s := Climate.wind_gain(10.0, summer)
	var gain_w := Climate.wind_gain(10.0, winter)
	_check(absf(shift_s - shift_w) > 90.0, "北印度洋的季风方向夏冬差 %.0f 度" % absf(shift_s - shift_w))
	_check(not is_equal_approx(gain_s, gain_w), "风力也不一样（×%.2f vs ×%.2f）" % [gain_s, gain_w])
	# **同一段航线，窗口内外真的走得不一样快** —— 这是验收第 1 条
	var a := _sail_indian(300.0)      # 夏天（西南季风）
	var b := _sail_indian(120.0)      # 冬天（东北季风）
	_check(not is_equal_approx(a, b), "同一条航线，夏天走了 %.1f 海里、冬天走了 %.1f 海里"
		% [a, b])
	_check(absf(a - b) / maxf(a, b) > 0.02, "差别不是四舍五入的零头（%.1f%%）"
		% (absf(a - b) / maxf(a, b) * 100.0))


func _sail_indian(start_day: float) -> float:
	"""把船摆在印度洋那一段，按航线走 4 个游戏小时，返回跑了多少海里。"""
	var v := _v()
	_set_day(v, start_day)
	v.ship.set_pose(v.sea.lonlat_to_m(75.0, -6.0), 90.0)
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(v.sea.lonlat_to_m(60.0, -12.0))
	var t := 0.0
	while t < 4.0 * 3600.0:
		v.tick(DT)
		t += DT
	return v.journal.distance_m / 1852.0


# ---------------------------------------------------------------- 4 飓风季

func _test_hurricane_season() -> void:
	var jul := 300.0 * 86400.0 / VoyageJournal.voyage_time_scale
	var jan := 120.0 * 86400.0 / VoyageJournal.voyage_time_scale
	# 北大西洋热带：夏秋是飓风季，冬天不是
	_check(not Climate.hurricane_band(15.0, jul).is_empty(), "七月在北大西洋热带是飓风季")
	_check(Climate.hurricane_band(15.0, jan).is_empty(), "一月不是 —— **等**过去就安全了")
	# 绕：换个纬度就不在带子里
	_check(Climate.hurricane_band(42.0, jul).is_empty(), "七月跑到 42 度就不在带子里 —— **绕**开")
	# 赌：在飓风季里待着，总会挨上一场（确定性硬币：每个航程日掷一次）
	var v := _v()
	_set_day(v, 300.0)
	v.ship.set_pose(v.sea.lonlat_to_m(-45.0, 15.0), 90.0)
	var hit := false
	var guard := 0
	while guard < 30 and not hit:
		v.tick(60.0)                       # 一步一个航程日
		guard += 1
		if v.weather.state_id == "storm":
			hit = true
	_check(hit, "在飓风季里待着，%d 个航程日之内挨上了一场风暴（赌的代价）" % guard)


# ---------------------------------------------------------------- 5 坏血病

func _test_scurvy() -> void:
	var v := _v()
	# 两个情形：刚离港（10 天）与长期没补给（90 天）
	var fresh := _health_after_days(10.0)
	var stale := _health_after_days(90.0)
	_check(fresh < 0.001, "刚离港十天：健康几乎不掉（%.4f）" % fresh)
	_check(stale > 0.15, "九十天只有咸肉与饼干：健康明显掉（%.4f）" % stale)
	_check(stale > fresh * 10.0, "两者差一个数量级（%.4f vs %.4f）" % [stale, fresh])
	# 靠港会清零：`dock()` 之后 days_since_fresh 归零
	var v2 := _v()
	v2.days_since_fresh = 88.0
	# 靠港要先抛锚、而且得停在锚地圈里 —— 把船直接摆到第一个港
	v2.ship.set_pose(Geom2D.centroid(v2.sea.ports()[0]["shape"]), 0.0)
	v2.orders.anchored = true
	var r := v2.dock()
	_check(is_zero_approx(v2.days_since_fresh),
		"靠港补给把坏血病的计时清零（%s）" % str(r))


func _health_after_days(days_since_fresh: float) -> float:
	"""让潮一次 90 个航程日后，全船平均掉了多少健康。"""
	var v := _v()
	v.days_since_fresh = days_since_fresh
	var before := 0.0
	for m in v.roster.members:
		before += m.health
	before /= float(maxi(1, v.roster.members.size()))
	v._climate_health_tick(90.0, false, false)
	var after := 0.0
	for m in v.roster.members:
		after += m.health
	after /= float(maxi(1, v.roster.members.size()))
	return before - after


# ---------------------------------------------------------------- 6 断粮与老化

func _test_attrition_and_wear() -> void:
	var v := _v()
	# 断粮断水：过宽限期之后按天掉健康，见底就死人 —— 一天一天地推
	var alive_before := 0
	for m in v.roster.members:
		if not m.dead:
			alive_before += 1
	v.days_short = Climate.attrition_grace_days()
	for i in 40:
		v.days_short += 1.0
		v._climate_health_tick(1.0, true, true)
	var alive_after := 0
	for m in v.roster.members:
		if not m.dead:
			alive_after += 1
	_check(alive_after < alive_before, "断粮断水久了真的会死人（%d → %d）" % [alive_before, alive_after])
	_check(int(v.ending_score.get("crew", 0)) < 0, "死人扣结算的船员成果（%d）"
		% int(v.ending_score.get("crew", 0)))
	# 正面的一半：同样的天数，**补给够（而且定期靠港换新鲜东西）**就一个都不会少
	var v_ok := _v()
	var alive_ok := 0
	for m in v_ok.roster.members:
		if not m.dead:
			alive_ok += 1
	for i in 40:
		v_ok.days_since_fresh = 0.0     # 每 40 天靠一次港（新鲜东西重新上船）
		v_ok._climate_health_tick(1.0, false, false)
	var alive_ok_after := 0
	for m in v_ok.roster.members:
		if not m.dead:
			alive_ok_after += 1
	_check(alive_ok_after == alive_ok, "补给够就一个都不少（%d → %d）"
		% [alive_ok, alive_ok_after])
	# 老化：在海上过 120 个航程日之后，船体自己掉
	var v2 := _v()
	_set_day(v2, 120.0)
	var hull_before := v2.ship.damage_of("hull")
	v2._wear_tick(1.0)
	_check(v2.ship.damage_of("hull") > hull_before, "船体在老化（%.4f → %.4f）"
		% [hull_before, v2.ship.damage_of("hull")])
	# 还没到 start_day 的时候不掉
	var v3 := _v()
	_set_day(v3, 30.0)
	var before3 := v3.ship.damage_of("hull")
	v3._wear_tick(1.0)
	_check(is_equal_approx(v3.ship.damage_of("hull"), before3), "头两个月不老化（走远洋才磨损）")


# ---------------------------------------------------------------- 7 起火 / 进水

func _test_hazards() -> void:
	"""七处损伤的最后一条（docs/22 第 5.4 节）：火与水是**状态**，不是损伤值。

	四条：没人管会恶化 + 真的烧坏东西；派人压得住；上层看得见（阻力/货舱/炮弹）；
	以及它跟着存档走、靠港能了结。
	"""
	# 真源：速率就在 ship_physics.json 的 hazard 块里（和气动同一个文件）
	var hz: Dictionary = ShipPhysics.load_default().hazard
	_check(hz.has("fire") and hz.has("flood"), "真源里有起火与进水两块")
	_check(float((hz.get("fire", {}) as Dictionary).get("burn_sail_per_hour", 0.0)) > 0.0,
		"火会烧帆（数值来自真源）")

	# 1) 没人管：强度自己涨，帆被烧
	var v := _v()
	v.ship.apply_hazard("fire", 0.30)
	var sail_before := v.ship.damage_of("sail")
	for i in 4:
		v._hazard_tick(60.0)
	_check(v.ship.hazard_of("fire") > 0.30, "没人救火，火自己长大（%.2f → %.2f）"
		% [0.30, v.ship.hazard_of("fire")])
	_check(v.ship.damage_of("sail") > sail_before, "火把帆烧了（%.3f → %.3f）"
		% [sail_before, v.ship.damage_of("sail")])

	# 2) 派人：压得下去，最后灭掉
	var v2 := _v()
	v2.ship.apply_hazard("fire", 0.30)
	v2.fight_hazard(12)
	for i in 5:
		v2._hazard_tick(60.0)
	_check(v2.ship.hazard_of("fire") <= 0.0, "派 12 个人就把火灭了（%.2f）" % v2.ship.hazard_of("fire"))

	# 3) 进水：船壳继续掉、货被泡（Cargo 真的少件数）
	var v3 := _v()
	v3.cargo.add("brazilwood", 20)
	var goods_before := v3.cargo.qty("brazilwood")
	var hull_before := v3.ship.damage_of("hull")
	v3.ship.apply_hazard("flood", 0.30)
	for i in 12:
		v3._hazard_tick(60.0)
	_check(v3.ship.damage_of("hull") > hull_before, "进水让船壳继续掉（%.3f → %.3f）"
		% [hull_before, v3.ship.damage_of("hull")])
	_check(v3.cargo.qty("brazilwood") < goods_before, "水把货泡掉了（%d → %d）"
		% [goods_before, v3.cargo.qty("brazilwood")])

	# 4) 上层看得见：同样的风与帆，进水那条更慢（阻力那条链）
	var a := _v()
	var b := _v()
	b.ship.apply_hazard("flood", 0.60)
	a.ship.set_sail_area_scale(1.0)
	b.ship.set_sail_area_scale(1.0)
	for i in 180:
		a.ship.step(DT, Vector2(6.0, 0.0))
		b.ship.step(DT, Vector2(6.0, 0.0))
	_check(b.ship._u < a.ship._u, "进水让船更慢（%.3f → %.3f m/s）" % [a.ship._u, b.ship._u])

	# 5) 压不住：强度到顶就有沉船旗标（换旗舰是 M16）
	var v4 := _v()
	v4.ship.apply_hazard("fire", 0.85)
	for i in 4:
		v4._hazard_tick(60.0)
	_check(bool(v4.fired.get("ship_lost", false)), "火压不住 → 沉船旗标立起来")

	# 6) 存档往返：火与水的强度跟着船走
	var v5 := _v()
	v5.ship.apply_hazard("fire", 0.42)
	v5.ship.apply_hazard("flood", 0.18)
	var st := v5.ship.capture_state()
	var s2 := ShipDynamics.new(v5.ship.physics)
	s2.apply_state(st)
	_check(is_equal_approx(s2.hazard_of("fire"), 0.42) and is_equal_approx(s2.hazard_of("flood"), 0.18),
		"火与水的强度进得了存档（%.2f / %.2f）" % [s2.hazard_of("fire"), s2.hazard_of("flood")])

	# 7) 第七处损伤在"弹药区坏掉"这条链上也看得见：坏一半 → 少一半炮能打
	var guns := Guns.new()
	guns.setup_default()
	var all_ready := guns.ready_count()
	guns.magazine_damage = 0.5
	_check(guns.ready_count() < all_ready, "弹药区被打坏 → 能打的炮变少（%d → %d）"
		% [all_ready, guns.ready_count()])


# ---------------------------------------------------------------- 8 太平洋段的内容

func _test_pacific_content() -> void:
	"""M13 的"太平洋内容"：事件池只在这片海发生，岛链上得了岸就能缓过来。"""
	var v := _v()
	var ids: Array = v.events.ids()
	for want in ["pacific_calm_days", "pacific_water_ration", "pacific_birds",
			"pacific_scurvy", "pacific_stars"]:
		_check(ids.has(want), "太平洋事件池里有 %s" % want)

	# 每一条都钉着 region: pacific（在大西洋那边不该发生）
	var e: Dictionary = v.events.def_of("pacific_scurvy")
	_check(str((e.get("requires", {}) as Dictionary).get("region", "")) == "pacific",
		"太平洋事件带 region 条件")
	_set_day(v, 90.0)
	var in_atlantic := v.events.unmet(e, v)
	_check(in_atlantic != "", "在大西洋这边它不发生（%s）" % in_atlantic)

	# 把船摆进太平洋、日子也够了 —— 条件就成立
	var mid := v.sea.lonlat_to_m(-150.0, -10.0)
	v.ship.set_pose(mid, 90.0)
	_check(v.sea.world.region_of_tile(v.sea.tile_of(mid)).get("id", "") == "pacific",
		"（-150 / -10）确实在太平洋图幅里")
	_check(v.events.unmet(e, v) == "", "进了太平洋、日子够了就能发生")

	# 真的触发一次：关键船员的健康真的掉
	var before := 0.0
	for m in v.roster.key_crew():
		before += m.health
	var r := v.events.try_fire("pacific_scurvy", v)
	var after := 0.0
	for m in v.roster.key_crew():
		after += m.health
	_check(bool(r.get("ok", false)) and after < before,
		"坏血病事件触发了、关键船员健康掉了（%.2f → %.2f）" % [before, after])

	# 岛链：只要上得了岸，坏血病的计时就清零
	var v2 := _v()
	var landed := false
	for land in v2.sea.lands():
		var c := Geom2D.centroid(land["shape"])
		for k in 24:
			var p := c + Vector2(cos(TAU * float(k) / 24.0), sin(TAU * float(k) / 24.0)) * 1200.0
			if v2.sea.world.is_dry_land(p):
				continue
			if float(v2.sea.nearest_shore(p)["distance_m"]) < 300.0:
				v2.ship.set_pose(p, 90.0)
				landed = v2.can_land()
				break
		if landed:
			break
	_check(landed, "能找到一处上得了岸的滩头")
	if landed:
		v2.days_since_fresh = 40.0
		v2.land([], 4)
		_check(is_equal_approx(v2.days_since_fresh, 0.0),
			"上岛就把坏血病计时清零（40 → %.0f 天）" % v2.days_since_fresh)


# ---------------------------------------------------------------- 9 搁浅兜底

func _test_aground_escape() -> void:
	"""长跑里"船被背风岸按了几十天"的兜底：搁浅太久就绞缆脱浅。"""
	var v := _v()
	# 找一处贴着岸的水面（脱浅规则的触发位置）
	var spot := Vector2.ZERO
	var found := false
	for land in v.sea.lands():
		var c := Geom2D.centroid(land["shape"])
		for k in 24:
			var p := c + Vector2(cos(TAU * float(k) / 24.0), sin(TAU * float(k) / 24.0)) * 1200.0
			if v.sea.world.is_dry_land(p):
				continue
			if float(v.sea.nearest_shore(p)["distance_m"]) < 150.0:
				spot = p
				found = true
				break
		if found:
			break
	_check(found, "能找到一处贴着岸的水面")
	if not found:
		return
	v.ship.set_pose(spot, 90.0)
	var before := v.ship.position_m()
	var kedged := false
	for i in 12:
		v.ship.last_blocked = true
		v._aground_tick(60.0)
		if v.ship.position_m().distance_to(before) > 50.0:
			kedged = true
			break
	var off := float(v.sea.nearest_shore(v.ship.position_m())["distance_m"])
	_check(kedged and off >= 600.0, "搁浅 12 个航程小时之后绞缆脱浅（离岸 %.0f 米）" % off)
	_check(v.ship.speed_kn() < 0.01, "脱浅之后速度清零（等着重新挂帆）")


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
