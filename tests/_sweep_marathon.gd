extends SceneTree

# 一次性扫描（**不是常驻通道**）：把一条远征跑很久，盯着"数值会不会烂掉"。
# 看的是不变量：位置/速度/损伤/需求都还在合理范围里，没有 NaN，船没有跑到干地上。

const GEO := "res://data/world/atlantic/geography.json"
const DT := 0.5
const TOTAL := 120000.0          # 120000 游戏秒 ≈ 33 小时的模拟时间

var _fails: PackedStringArray = []
var _report := 0


func _initialize() -> void:
	print("=== 长征扫描 ===")
	var v := Voyage.new()
	v.setup(GEO)
	v.start_route_follow()
	var t := 0.0
	var next_report := 0.0
	while t < TOTAL:
		v.tick(DT)
		t += DT
		if t >= next_report:
			next_report += 20000.0
			_print_row(v, t)
		_check_invariants(v, t)
	if _fails.is_empty():
		print("长征扫描通过：%d 个检查点没发现数值烂掉" % _report)
	else:
		print("长征扫描发现 %d 处问题：%s" % [_fails.size(), ", ".join(_fails)])
	# 附：卡住之后，"点一个偏开一点的目标点"（待决问题第 ③ 条）真的能进去吗？
	_side_target_experiment(v)
	quit(0 if _fails.is_empty() else 1)


func _side_target_experiment(v: Voyage) -> void:
	var goal := v.default_destination()
	var d0 := v.ship.position_m().distance_to(goal)
	if d0 < 800.0:
		print("  已经进港了（离终点 %.0f m），不用做实验" % d0)
		return
	v.stop_route_follow()
	var bearing := (goal - v.ship.position_m()).angle()
	var off := v.ship.position_m() + Vector2.from_angle(bearing + deg_to_rad(70.0)) * d0 * 1.5
	v.orders.set_target_point(off)
	print("  卡在 %.2f km 处 → 把目标点偏开 70° 摆到 %.2f km 外" % [d0 / 1000.0, off.distance_to(v.ship.position_m()) / 1000.0])
	var t := 0.0
	while t < 40000.0 and v.ship.position_m().distance_to(goal) > 400.0:
		v.tick(DT)
		t += DT
	var d1 := v.ship.position_m().distance_to(goal)
	print("  偏开之后：离终点 %.2f km → %.2f km，用了 %.0f 游戏秒（%.1f 小时）  风 %.1f m/s %s" % [
		d0 / 1000.0, d1 / 1000.0, t, t / 3600.0, v.wind.tws_ms, v.weather.state_id])
	if d1 <= 400.0:
		print("  → 第 ③ 条成立：偏开一点就能磨进去（进到 400 m 以内）")
	else:
		print("  → 第 ③ 条在这一次没走通（还差 %.2f km）" % (d1 / 1000.0))


func _print_row(v: Voyage, t: float) -> void:
	print("  t=%6.0f 秒（第 %.0f 天）  本船 %s  离终点 %.1f km  船体 %.0f%%  人数 %d  风 %.1f m/s %s" % [
		t, t / 86400.0, _fmt(v.ship.position_m()),
		v.ship.position_m().distance_to(v.default_destination()) / 1000.0,
		(1.0 - v.ship.damage_of("hull")) * 100.0,
		v.crew_on_board(), v.wind.tws_ms, v.weather.state_id])


func _fmt(p: Vector2) -> String:
	return "(%.0f, %.0f)" % [p.x, p.y]


func _check_invariants(v: Voyage, t: float) -> void:
	_report += 1
	_finite("本船位置", v.ship.position_m(), t)
	_finite("本船艏向", Vector2(v.ship.heading_deg(), v.ship.speed_ms()), t)
	for part in ["hull", "mast", "rudder"]:
		var d := v.ship.damage_of(part)
		if not is_finite(d) or d < 0.0 or d > 1.0:
			_note("t=%.0f 损伤 %s 越界：%.4f" % [t, part, d])
	if absf(v.ship.speed_ms()) > 15.0:
		_note("t=%.0f 船速离谱：%.2f m/s" % [t, v.ship.speed_ms()])
	if v.sea.is_dry_land(v.ship.position_m()):
		_note("t=%.0f 本船跑到干地上了 %s" % [t, _fmt(v.ship.position_m())])
	for id in v.fleet.ids():
		var p: Vector2 = v.fleet.pose_of(id)
		if not is_finite(p.x) or not is_finite(p.y):
			_note("t=%.0f %s 的位置是 NaN" % [t, str(id)])
		elif v.sea.is_dry_land(p):
			_note("t=%.0f %s 在干地上 %s" % [t, str(id), _fmt(p)])
	for m in v.roster.members:
		for f in ["hunger", "fatigue", "health", "mood"]:
			var x: float = m.get(f)
			if not is_finite(x) or x < -0.001 or x > 1.001:
				_note("t=%.0f 船员 %s 的 %s 越界：%.4f" % [t, m.id, f, x])
				return
	if v.cargo.money < 0:
		_note("t=%.0f 金币是负数：%d" % [t, v.cargo.money])


func _finite(label: String, p: Vector2, t: float) -> void:
	if not is_finite(p.x) or not is_finite(p.y):
		_note("t=%.0f %s 不是有限数：%s" % [t, label, str(p)])


func _note(msg: String) -> void:
	for f in _fails:
		if f.begins_with(msg.substr(0, 12)):
			return                       # 同一类问题只报一次，别刷屏
	_fails.append(msg)
	print("  [FAIL] " + msg)
