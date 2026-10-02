extends SceneTree

# 一次性长跑扫描（M13 的验收第 5 条，不进常驻通道）：
# 让一条船在**全球图**上按航线跑 120000 个游戏秒（≈ 三年的 1/6 量级），
# 看三年尺度的数值会不会烂 —— NaN、越界、永久卡死、名册漂移。
#
#   & $g --headless --path . --script res://tests/_sweep_voyage.gd
#
# 它每 5000 游戏秒打一行，最后给一句结论；退出码 0 = 没烂。
#
# **补给**：这趟扫描每隔一段就按"正常玩法"补一次给养（否则船员会饿死、
# 船停下来，那验的是断粮而不是"数值会不会烂"—— 断粮有 `test_climate` 专门盯）。

const DT := 0.5
var TOTAL := 120000.0        # 可以用命令行覆盖：`-- 15000 500`
var REPORT := 5000.0

func _initialize() -> void:
	print("=== sweep_voyage（120000 游戏秒 ≈ %.0f 个航程日）==="
		% (TOTAL * VoyageJournal.voyage_time_scale / 86400.0))
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		TOTAL = float(args[0])
	if args.size() > 1:
		REPORT = float(args[1])
	print("（扫 %d 游戏秒，每 %d 秒报一次）" % [int(TOTAL), int(REPORT)])
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false          # 这一条只是"数值会不会烂"，不掺遭遇与追捕
	# 从塞维利亚出发，按航线走
	v.start_route_follow()
	var t := 0.0
	var next_report := 0.0
	var bad := 0
	var stuck_max := 0.0
	var stuck_at := Vector2.ZERO
	var stuck_t := 0.0
	# 「卡住」不能只看瞬时位移（洋流会把人推着慢慢挪）——再加两个累计量：
	#   贴着干地的累计时间、几乎不动（< 0.2 节）的累计时间，以及单小时最小净前进。
	var blocked_t := 0.0
	var slow_t := 0.0
	var hour_t := 0.0
	var hour_pos := Vector2.ZERO
	var worst_hour_m := INF
	var last_pos := v.ship.position_m()
	hour_pos = last_pos
	var next_provision := 0.0
	while t < TOTAL:
		# 每 5000 游戏秒补一次给养（模拟"路上靠港"）
		if t >= next_provision:
			next_provision += 5000.0
			v.cargo.add("food", 400)
			v.cargo.add("water", 40)
			v.days_since_fresh = 0.0
			v.days_short = 0.0
			v.ship.apply_damage("hull", -0.05)   # 顺手修一点（码头能补的）
		v.tick(DT)
		t += DT
		var p := v.ship.position_m()
		# 数值健康：不是 NaN、在世界里、速度不离谱
		if is_nan(p.x) or is_nan(p.y) or is_nan(v.ship.speed_ms()):
			print("  [BAD] t=%.0f 出现 NaN" % t)
			bad += 1
			break
		if not v.sea.in_bounds(p):
			print("  [BAD] t=%.0f 跑出世界（%s）" % [t, str(p)])
			bad += 1
			break
		if v.ship.speed_ms() > 15.0:
			print("  [BAD] t=%.0f 速度离谱（%.1f m/s）" % [t, v.ship.speed_ms()])
			bad += 1
			break
		# 卡住：连续很久没有净前进（记录最长的一次）
		var moved := v.sea.dist(last_pos, p)
		if moved < 0.5:
			if stuck_max == 0.0:
				stuck_at = p
				stuck_t = t
			stuck_max = maxf(stuck_max, t - stuck_t)
		else:
			stuck_max = 0.0
		last_pos = p
		if v.ship.last_blocked:
			blocked_t += DT
		if v.ship.speed_kn() < 0.2:
			slow_t += DT
		hour_t += DT
		if hour_t >= 3600.0:
			worst_hour_m = minf(worst_hour_m, v.sea.dist(hour_pos, p))
			hour_pos = p
			hour_t = 0.0
		if t >= next_report:
			next_report += REPORT
			var ll := v.sea.m_to_lonlat(p)
			var anchor_word := "起"
			if v.orders.anchored:
				anchor_word = "下着"
			print("  t=%6.0f s（%4.1f 天）　经纬 %7.2f / %6.2f　%.1f 节　船体 %.0f%%　活 %d 人　坏血病 %.0f 天　天气 %s　锚 %s"
				% [t, t * VoyageJournal.voyage_time_scale / 86400.0, ll.x, ll.y,
				   v.ship.speed_kn(), (1.0 - v.ship.damage_of("hull")) * 100.0,
				   _alive(v), v.days_since_fresh, v.weather.state_name(), anchor_word])
			if v.ship.last_blocked:
				print("      ↑ 这一帧撞着干地（沿轴滑动）")
	print("---")
	var verdict := "数值没烂"
	if bad != 0:
		verdict = "有问题，见上面 [BAD]"
	print("结论：%s" % verdict)
	print("　· 贴着干地累计 %.0f 个航程小时（占 %.0f%%）" % [
		blocked_t * VoyageJournal.voyage_time_scale / 3600.0,
		blocked_t / maxf(1.0, t) * 100.0])
	print("　· 几乎不动（< 0.2 节）累计 %.0f 个航程小时" % (slow_t * VoyageJournal.voyage_time_scale / 3600.0))
	print("　· 单小时最小净前进 %s 米；瞬时卡住最久 %.0f 游戏秒" % [
		("∞" if worst_hour_m == INF else "%.0f" % worst_hour_m), stuck_max])
	print("　· 终点还剩 %d 段航线" % v.route_waypoints.size())
	quit(0 if bad == 0 else 1)


func _alive(v: Voyage) -> int:
	var n := 0
	for m in v.roster.members:
		if not m.dead:
			n += 1
	return n
