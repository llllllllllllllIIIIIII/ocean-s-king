extends SceneTree

# Day 6 的验收测试：测试海域 + 登陆 + 事件（docs/02 Day 6）。
#
# 四条验收：
#   1. 走通"出港 → 巡航 → 发现岛 → 决定带谁登陆 → 上岛 → 返航"
#   2. 登陆期间船上发生了玩家没直接控制的事，回来后能收到报告
#   3. 带走的船员会影响船的操控（人少了，调帆变慢）
#   4. 至少一条事件因果链可见（风向突变 → 被压向暗礁 → 触礁 → 木匠去修）

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_world ===")
	_test_sea_data()
	_test_wind_and_current()
	_test_land_collision()
	_test_damage()
	_test_voyage_flow()
	_test_landing_chain()
	_finish()


func _voyage() -> Voyage:
	var v := Voyage.new()
	v.setup()
	return v


func _run(v: Voyage, seconds: float) -> void:
	for _i in int(seconds / DT):
		v.tick(DT)


# ---------------------------------------------------------------- 1 海域数据

func _test_sea_data() -> void:
	var s := Sea.new()
	s.setup()
	_check(s.ready, "海域数据加载成功")
	_check(s.size_m() == Vector2(8000, 8000), "8km × 8km（%s）" % str(s.size_m()))
	_check(s.pois().size() == 4, "岛上有 4 个地标（%d）" % s.pois().size())
	var ids := []
	for poi in s.pois():
		ids.append(str(poi["id"]))
	for want in ["beach", "ruins", "stream", "village"]:
		_check(ids.has(want), "地标里有 %s" % want)
	_check(not s.is_land(Vector2(700, 4000)), "出发港在海上")
	_check(s.is_port(Vector2(700, 4000)), "出发港位置正确")
	_check(s.is_land(Vector2(5600, 3600)), "岛心是陆地")
	_check(s.is_beach(Vector2(4790, 3600)), "滩头算沙滩")
	_check(not s.is_beach(Vector2(5600, 3600)), "岛心不是沙滩")
	_check(s.is_reef(Vector2(3400, 2050)), "暗礁位置")
	_check(not s.is_reef(Vector2(1000, 1000)), "别处不是暗礁")
	var poi := s.poi_at(Vector2(5620, 3320))
	_check(str(poi.get("id", "")) == "ruins", "走到遗迹能认出来（%s）" % str(poi.get("id", "")))
	_check(s.poi_at(Vector2(2000, 2000)).is_empty(), "海面上没有地标")


# ---------------------------------------------------------------- 2 风与洋流

func _test_wind_and_current() -> void:
	var s := Sea.new()
	s.setup()
	# 背风区：风从东北来（吹向西南），岛的下风侧应该在岛的西/南那一侧
	var upwind := s.lee_factor(Vector2(6600, 2800))     # 上风侧
	var downwind := s.lee_factor(Vector2(4700, 4400))   # 下风侧
	_check(downwind < upwind - 0.1,
		"岛的背风区风速明显更低（上风 %.2f vs 下风 %.2f）" % [upwind, downwind])
	_check(upwind > 0.9, "上风侧基本不受影响（%.2f）" % upwind)

	var mid := Vector2((1200 + 4300) * 0.5, (900 + 3100) * 0.5)
	_check(s.current_at(mid).length() > 0.5, "洋流带中间有流速（%.2f m/s）" % s.current_at(mid).length())
	_check(s.current_at(Vector2(700, 700)).length() == 0.0, "带子外面没有洋流")

	# 洋流真的会带着船走：收帆、不抛锚，放在洋流带上
	var v := _voyage()
	v.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
	v.ship.set_pose(mid, 0.0)
	v.ship.set_sail_area_scale(0.0)
	var p0 := v.ship.position_m()
	_run(v, 300.0)
	var moved := v.ship.position_m() - p0
	_check(moved.length() > 80.0, "不挂帆也会被洋流带着走（漂了 %.0f 米）" % moved.length())
	_check(moved.normalized().dot(s.current_at(mid).normalized()) > 0.9,
		"漂的方向就是流的方向")


# ---------------------------------------------------------------- 3 损伤

func _test_land_collision() -> void:
	"""船不能再开到陆地上（现场反馈：船能碾上岛）。"""
	var v := _voyage()
	var dry: float = float(v.sea.island().get("radius_m", 0.0)) \
		- float(v.sea.island().get("beach_width_m", 0.0))
	var c := Vector2(5600, 3600)
	# 从正西边直冲岛心，满帆
	v.ship.set_pose(c + Vector2(-1500, 0), 0.0)
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(c)
	var deepest := 1e12
	for _i in int(900.0 / DT):
		v.tick(DT)
		deepest = minf(deepest, v.ship.position_m().distance_to(c))
	_check(deepest >= dry - 1.0,
		"船进不了干地（最近到过离岛心 %.0f 米，干地边界 %.0f 米）" % [deepest, dry])
	_check(v.ship.last_blocked or v.ship.speed_kn() < 1.0,
		"冲到岸边会顶住或贴着岸滑（末速 %.1f 节）" % v.ship.speed_kn())


func _test_damage() -> void:
	var v := _voyage()
	var before := v.ship.damage_of("hull")
	v.ship.set_pose(Vector2(3400, 2050), 0.0)     # 直接开进暗礁
	v.orders.set_target_point(Vector2(4300, 3100))
	_run(v, 120.0)
	_check(v.reef_hit, "开进暗礁会触礁")
	_check(v.ship.damage_of("hull") > before + 0.2,
		"触礁让船体受损（%.0f%%）" % (v.ship.damage_of("hull") * 100.0))


# ---------------------------------------------------------------- 4 走通一趟

func _test_voyage_flow() -> void:
	var v := _voyage()
	var start := v.ship.position_m()
	# ① 出港
	_check(v.sea.is_port(start), "开局在出发港")
	# ② 巡航：给个目标点，船真的开出去
	v.orders.set_target_point(Vector2(3600, 3600))     # 目标点选在离岛 2000 米的位置
	_run(v, 1500.0)
	_check(v.ship.position_m().distance_to(start) > 800.0,
		"把船开出港（走了 %.0f 米）" % v.ship.position_m().distance_to(start))
	_check(v.ship.speed_kn() > 3.0, "巡航时有速度（%.1f 节）" % v.ship.speed_kn())
	# ③ 发现岛：靠近之后瞭望员会报告
	_check(v.island_known, "靠近岛时瞭望员会报告（已报告=%s）" % v.island_known)
	_check(v.fired.has("lookout"), "瞭望员报告事件触发过")
	_check(v.log_lines.size() > 2, "航海日志有内容（%d 条）" % v.log_lines.size())


# ---------------------------------------------------------------- 5 登陆与因果链

func _test_landing_chain() -> void:
	var v := _voyage()
	var beach := Vector2(4790, 3600)
	# 先把船开到滩头附近并抛锚
	v.ship.set_pose(beach + Vector2(-300, 0), 0.0)
	v.orders.set_target_point(beach)
	_run(v, 60.0)
	v.orders.anchored = true
	v.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
	_check(v.can_land(), "在滩头附近可以登陆")

	# 带走的船员会影响船：先记下操帆的人手与收放速度
	_run(v, 120.0)
	# 挑四个最能干的（水手长、木匠、大副、舵手）带走
	var ids := ["contramaestre", "carpintero", "maestre", "timonel"]
	_check(v.landing_candidates().size() == 12, "登陆名单里有 12 名关键船员")
	var hands_before := v.roster.sail_hands()
	var skill_before := v.roster.sail_skill()
	var rate_before := v.crew.trim_rate_dps
	var msg := v.land(ids, 6)
	_check(v.ashore, "带人上岸之后船长在岸上（%s）" % msg)
	_run(v, 30.0)
	# 上岸的人真的不在船上干活了（岗位变成"上岸"）
	var still_working := 0
	for m in v.roster.key_crew():
		if m.ashore and m.job != "ashore":
			still_working += 1
	_check(still_working == 0, "上岸的人不再担任船上的岗位（%d 人例外）" % still_working)
	_check(v.party_size() >= 5, "岸上有一支队伍（%d 人）" % v.party_size())
	_check(v.roster.sail_skill() < skill_before,
		"操帆的人手水平下降（%.2f → %.2f）" % [skill_before, v.roster.sail_skill()])
	_check(v.crew.trim_rate_dps < rate_before,
		"人少了以后调帆变慢（%.1f → %.1f 度/秒）" % [rate_before, v.crew.trim_rate_dps])

	# 船长不在船上的这段时间，船上自己发生事（触礁 → 伤病 → 木匠修）
	v.ship.apply_damage("hull", 0.28)
	v.fired.erase("reef_hit")
	v.reef_hit = false
	v.orders.anchored = false                     # 大副起锚了（玩家没在管）
	v.ship.set_pose(Vector2(3400, 2050), 0.0)     # 大副把船开进了暗礁（玩家没在管）
	_run(v, 120.0)
	_check(v.reef_hit, "船长不在时船撞上了暗礁（玩家没直接控制）")
	_check(v.pending_reports.size() > 0,
		"船长不在时发生的事被攒成报告（%d 条）" % v.pending_reports.size())

	# 岸上：走到遗迹
	v.move_party_to(Vector2(5620, 3320))
	_run(v, 240.0)
	_check(v.visited.has("ruins"), "走到遗迹会被记录")
	_check(v.fired.has("ruins"), "发现遗迹事件触发")
	# 五个脚本事件里的最后一个：部落接触
	v.move_party_to(Vector2(6260, 3180))
	_run(v, 300.0)
	_check(v.visited.has("village"), "走到部落村落会被记录")
	_check(v.fired.has("village"), "部落接触事件触发（5 个脚本事件齐了）")
	var five := ["lookout", "wind_shift", "injury", "ruins", "village"]
	var missing := PackedStringArray()
	for e in five:
		if not v.fired.has(e):
			missing.append(e)
	_check(missing.is_empty(), "五个脚本事件全部触发过（缺：%s）" % ("无" if missing.is_empty() else ", ".join(missing)))

	# 返航：走回滩头再上船，一次性收到报告
	v.move_party_to(beach)
	_run(v, 300.0)
	var back := v.return_to_ship()
	_check(not v.ashore, "回到船上")
	_check(back.find("船上发生了") >= 0, "回船时收到延迟报告")
	_check(v.pending_reports.is_empty(), "报告交付后清空")

	# 报告过的船员都回到船上干活
	var any_ashore := false
	for m in v.roster.key_crew():
		if m.ashore:
			any_ashore = true
	_check(not any_ashore, "返航后没有人还留在岸上")

	# 因果链：风向突变 → 触礁 → 木匠去修（修复工作被排上）
	_check(v.fired.has("wind_shift"), "风向突变事件触发过")
	_check(v.fired.has("reef_hit"), "触礁事件触发过")
	_check(v.fired.has("injury"), "触礁之后发生了船员伤病（5 个脚本事件之一）")
	var hurt := 0
	for m in v.roster.key_crew():
		if m.health < 0.9:
			hurt += 1
	_check(hurt >= 1, "有人真的受伤了（%d 人带伤）" % hurt)
	var repairing := false
	for m in v.roster.key_crew():
		if m.post == "木匠" and (m.job == "repair" or int(m.prio.get("repair", 0)) == 1):
			repairing = true
	_check(repairing, "木匠的修补优先级在损伤后起作用")


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
