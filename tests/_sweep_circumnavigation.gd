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
const STOP_RADIUS_M := 1500.0    # 离港口的锚地多近就"靠港"
# 说明：航段跟随在离航点 ~500 米时就切下一段，所以船不一定能走到 `can_dock()` 那个
# 450 米的圈里。长跑里那会让它**跳过好几个补给港**（船体因此一路掉到 0%）。
# 所以：先到 1500 米内，把船摆进锚地（`set_pose` 是测试/重置用的口子），再正常靠港。
const LOG_PATH := "user://sweep_circumnavigation.log"
var TOTAL := 400000.0        # 可以用命令行覆盖：`-- 80000 10000`
var REPORT := 20000.0

var _log: FileAccess
var _wall0 := 0


func _say(s: String) -> void:
	print(s)
	if _log != null:
		_log.store_line(s)
		_log.flush()


func _initialize() -> void:
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	_wall0 = Time.get_ticks_msec()
	_say("=== sweep_circumnavigation ===")
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		TOTAL = float(args[0])
	if args.size() > 1:
		REPORT = float(args[1])
	_say("（扫 %d 游戏秒，每 %d 秒报一次；靠港就补满）" % [int(TOTAL), int(REPORT)])
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	# **远洋口粮**：太平洋那一段一百多天没有港口 —— 真船长这时候就是半份口粮、
	# 严格配水（`Rules` 里现成的档位，代价是心情），不然载重根本装不下。
	v.set_rule("ration", "half")
	v.set_rule("water", "strict")
	v.start_route_follow()
	_say("出发：%s　终点：%s（归乡港 %s）" % [
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
	var serviced := {}                 # 靠过哪些港（每个港只停一次）
	var stops := 0
	var island_stops := 0
	var used_islands := {}             # 上过哪些岛（每座岛只补一次）
	while t < TOTAL:
		v.tick(DT)
		t += DT
		var p := v.ship.position_m()
		if is_nan(p.x) or is_nan(p.y) or not v.sea.in_bounds(p):
			_say("  [BAD] t=%.0f 位置出问题（%s）" % [t, str(p)])
			quit(1)
			return
		# **靠港补给**（M15 卡片里那句"中途自动停靠补给"）：
		# 进了锚地圈就抛锚、靠港、修满、补足口粮淡水，再出海接着跟航线走。
		for port in v.sea.ports():
			var pid := str(port.get("id", ""))
			if serviced.has(pid):
				continue
			var centroid := Geom2D.centroid(port["shape"])
			if v.sea.dist(p, centroid) > STOP_RADIUS_M:
				continue
			serviced[pid] = true
			stops += 1
			v.ship.set_pose(centroid, v.ship.heading_deg())
			v.orders.anchored = true
			var docked := v.dock()
			if v.docked_port != "":
				# 真游戏里修船要木料帆布与工钱、口粮要花钱买；这一步验的是**连通性**，
				# 所以按"港口愿意把远征队补满"来算（数字只在长跑里用）。
				for part in ["hull", "mast", "rudder", "sail", "hold", "magazine"]:
					v.ship.apply_damage(str(part), -1.0)
				# 按最长的缺口装：关岛之前那一段约 120 个航程日没有港口
				# （40 个人 × 每天 1 份口粮 / 3 升水）—— 真船长也会这么装。
				# 舱位装不下就装到满（载重那本账仍然是船的数据说了算）。
				v.cargo.add("water", mini(240, v.cargo.how_many_fit("water")))
				v.cargo.add("food", mini(4800, v.cargo.how_many_fit("food")))
				# 新鲜食物：压住坏血病的那一条（M13 验收第 3 条的后半），但只放得住四十天
				v.cargo.add("fresh_food", mini(400, v.cargo.how_many_fit("fresh_food")))
				v.cargo.add("wood", mini(20, v.cargo.how_many_fit("wood")))
				v.cargo.add("canvas", mini(10, v.cargo.how_many_fit("canvas")))
				v.cargo.money = maxi(v.cargo.money, 600)
				v.days_since_fresh = 0.0
				v.days_short = 0.0
				_say("  · t=%.0f 靠上%s（第 %d 站）：修满、补足，接着走（%s）"
					% [t, v.port_name(), stops, docked])
				v.undock()
			v.orders.anchored = false
			v.start_route_follow()
			break
		# **上岛补给**（M13 的规则：岛链就是太平洋上的补给点）：
		# 新鲜东西快断的时候**主动朝最近的岛开**（真船长会这么做），到了就上去补水补食。
		if v.days_since_fresh > 30.0 and not v.ashore:
			if v.can_land():
				var before_water := v.cargo.qty("water")
				var land_id := str(v.landing_land.get("id", "")) # 上一次的，占位（下面用真正的）
				v.orders.anchored = true
				v.land([], 4)
				if v.ashore:
					island_stops += 1
					land_id = str(v.landing_land.get("id", ""))
					used_islands[land_id] = true
					_say("  · t=%.0f 上岛补水（%s，淡水 %d → %d 桶）"
						% [t, land_id, before_water, v.cargo.qty("water")])
					v.return_to_ship()
					var guard := 0
					while v.ashore and guard < 400:
						v.tick(DT)
						t += DT
						guard += 1
				v.orders.anchored = false
				v.start_route_follow()
			elif v.following_route:
				var off := _island_offshore(v, used_islands)
				if off != Vector2.ZERO:
					v.stop_route_follow()
					v.orders.anchored = false
					v.orders.set_target_point(off)
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
			_say("  t=%7.0f s（%5.1f 天）　经纬 %7.2f / %6.2f　%.1f 节　航程 %5.0f 公里　船体 %.0f%%　活 %d 人　图幅 %s　剩 %d 段　靠港 %d 次"
				% [t, t * VoyageJournal.voyage_time_scale / 86400.0, ll.x, ll.y,
				   v.ship.speed_kn(), v.journal.distance_km(), (1.0 - v.ship.damage_of("hull")) * 100.0,
				   _alive(v), rid, v.route_waypoints.size(), stops])
		if ending_at >= 0.0:
			break                      # 触发了结局就收工（不用把预算跑完）

	_say("---")
	_say("结论：%s" % ("**跑通了**：触发结局" if ending_at >= 0.0 else "**没跑完**（到预算为止还没触发结局）"))
	_say("　· 全程 %.0f 游戏秒 = %.1f 个航程日（真实用时 %.1f 分钟）" % [
		t, t * VoyageJournal.voyage_time_scale / 86400.0,
		float(Time.get_ticks_msec() - _wall0) / 60000.0])
	_say("　· 触发结局的时刻：%s" % ("t=%.0f" % ending_at if ending_at >= 0.0 else "—"))
	_say("　· 航程 %.0f 公里（航海日志）；靠港 %d 次、上岛补水 %d 次" % [
		v.journal.distance_km(), stops, island_stops])
	_say("　· 贴着干地累计 %.0f 个航程小时（占 %.1f%%）；几乎不动累计 %.0f 个航程小时" % [
		blocked_t * VoyageJournal.voyage_time_scale / 3600.0,
		blocked_t / maxf(1.0, t) * 100.0,
		slow_t * VoyageJournal.voyage_time_scale / 3600.0])
	_say("　· 单小时最小净前进 %s 米；走过的图幅 %d 个（%s）" % [
		("∞" if worst_hour_m == INF else "%.0f" % worst_hour_m),
		regions.size(), ", ".join(regions.keys())])
	for row in Settlement.fleet_report(v):
		_say("　· %s：离终点 %.0f 米　船体 %.0f%%　%d 人　%s" % [
			str(row["name"]), float(row["distance_to_goal_m"]), float(row["hull_pct"]) * 100.0,
			int(row["crew_count"]), "到位" if bool(row["arrived"]) else "没到"])
	if _log != null:
		_log.close()
	quit(0 if ending_at >= 0.0 else 1)


func _alive(v: Voyage) -> int:
	var n := 0
	for m in v.roster.members:
		if not m.dead:
			n += 1
	return n


func _island_offshore(v: Voyage, used: Dictionary) -> Vector2:
	"""最近的一座**还没上去过**的岛的"离岸一点"（用它当目标点开过去）。

	只看 `role == "island"` 的陆地 —— 大陆海岸线不在此列（`extent` 太大，目标点会飞到海里）。
	"""
	var best := Vector2.ZERO
	var best_d := INF
	var pos := v.ship.position_m()
	for land in v.sea.lands():
		var id := str(land.get("id", ""))
		if id == "" or used.has(id) or str(land.get("role", "")) != "island":
			continue
		var c := Geom2D.centroid(land["shape"])
		var d := v.sea.dist(c, pos)
		if d > 40000.0 or d >= best_d:
			continue
		var dir := v.sea.delta(c, pos).normalized()          # 从岛指向船
		var off := v.sea.wrap_pos(c + dir * (Geom2D.extent(land["shape"]) + 320.0))
		best = off
		best_d = d
	return best
