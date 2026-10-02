extends SceneTree

# 一次性长跑（M15 的验收第 1、2 条，不进常驻通道）：
# **从圣卢卡尔出发，按航线把整条环球航线跑完，看它能不能回到圣卢卡尔。**
#
#   & $g --headless --path . --script res://tests/_sweep_circumnavigation.gd
#
# 它每 20000 游戏秒打一行，最后给一句结论；退出码 0 = 跑通（触发结局）。
#
# **补给**：每隔一段按"正常玩法"补一次给养（真游戏里是沿途靠港），
# 否则船员会饿死 —— 那验的是断粮（`test_climate` 专盯），不是连通性。

const DT := 0.5
var TOTAL := 400000.0        # 可以用命令行覆盖：`-- 80000 10000`
var REPORT := 20000.0


func _initialize() -> void:
	print("=== sweep_circumnavigation ===")
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		TOTAL = float(args[0])
	if args.size() > 1:
		REPORT = float(args[1])
	print("（扫 %d 游戏秒，每 %d 秒报一次）" % [int(TOTAL), int(REPORT)])
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.start_route_follow()
	print("出发：%s　终点：%s（归乡港 %s）" % [
		v.port_name(), v.goal_port_name(), v.home_port_id()])

	var t := 0.0
	var next_report := 0.0
	var blocked_t := 0.0
	var slow_t := 0.0
	var hour_t := 0.0
	var hour_pos := v.ship.position_m()
	var worst_hour_m := INF
	var regions := {}
	var ending_at := -1.0
	var next_provision := 0.0
	while t < TOTAL:
		# 每 20000 游戏秒补一次给养 + 修一点船（模拟"沿途靠港"）
		if t >= next_provision:
			next_provision += 20000.0
			v.cargo.add("food", 900)
			v.cargo.add("water", 90)
			v.cargo.add("wood", 6)
			v.cargo.add("canvas", 4)
			v.days_since_fresh = 0.0
			v.days_short = 0.0
			v.ship.apply_damage("hull", -0.10)
			v.ship.apply_damage("mast", -0.10)
			v.ship.apply_damage("sail", -0.10)
		v.tick(DT)
		t += DT
		var p := v.ship.position_m()
		if is_nan(p.x) or is_nan(p.y) or not v.sea.in_bounds(p):
			print("  [BAD] t=%.0f 位置出问题（%s）" % [t, str(p)])
			quit(1)
			return
		var rid := str(v.sea.world.region_of_tile(v.sea.tile_of(p)).get("id", ""))
		if rid != "":
			regions[rid] = true
		if v.ship.last_blocked:
			blocked_t += DT
		if v.ship.speed_kn() < 0.2:
			slow_t += DT
		hour_t += DT
		if hour_t >= 3600.0:
			worst_hour_m = minf(worst_hour_m, v.sea.dist(hour_pos, p))
			hour_pos = p
			hour_t = 0.0
		if ending_at < 0.0 and v.story.ending_ready:
			ending_at = t
		if t >= next_report:
			next_report += REPORT
			var ll := v.sea.m_to_lonlat(p)
			print("  t=%7.0f s（%5.1f 天）　经纬 %7.2f / %6.2f　%.1f 节　航程 %5.0f 公里　船体 %.0f%%　活 %d 人　图幅 %s　剩 %d 段"
				% [t, t * VoyageJournal.voyage_time_scale / 86400.0, ll.x, ll.y,
				   v.ship.speed_kn(), v.journal.distance_km(), (1.0 - v.ship.damage_of("hull")) * 100.0,
				   _alive(v), rid, v.route_waypoints.size()])

	print("---")
	print("结论：%s" % ("**跑通了**：触发结局" if ending_at >= 0.0 else "**没跑完**（到预算为止还没触发结局）"))
	print("　· 全程 %.0f 游戏秒 = %.1f 个航程日（真实用时 %.1f 分钟）" % [
		t, t * VoyageJournal.voyage_time_scale / 86400.0, t / 3600.0 / 60.0])
	print("　· 触发结局的时刻：%s" % ("t=%.0f" % ending_at if ending_at >= 0.0 else "—"))
	print("　· 航程 %.0f 公里（航海日志）" % v.journal.distance_km())
	print("　· 贴着干地累计 %.0f 个航程小时（占 %.1f%%）；几乎不动累计 %.0f 个航程小时" % [
		blocked_t * VoyageJournal.voyage_time_scale / 3600.0,
		blocked_t / maxf(1.0, t) * 100.0,
		slow_t * VoyageJournal.voyage_time_scale / 3600.0])
	print("　· 单小时最小净前进 %s 米；走过的图幅 %d 个（%s）" % [
		("∞" if worst_hour_m == INF else "%.0f" % worst_hour_m),
		regions.size(), ", ".join(regions.keys())])
	for row in Settlement.fleet_report(v):
		print("　· %s：离终点 %.0f 米　船体 %.0f%%　%d 人　%s" % [
			str(row["name"]), float(row["distance_to_goal_m"]), float(row["hull_pct"]) * 100.0,
			int(row["crew_count"]), "到位" if bool(row["arrived"]) else "没到"])
	quit(0 if ending_at >= 0.0 else 1)


func _alive(v: Voyage) -> int:
	var n := 0
	for m in v.roster.members:
		if not m.dead:
			n += 1
	return n
