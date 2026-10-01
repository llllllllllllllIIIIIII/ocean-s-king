extends SceneTree

# 一次性诊断（**不是常驻通道**）：把"进不了终点港"这件事拆开看。
#
# 每一行打的是同一条决策链上的量：
#   离终点 / 船速 / 真风 / **船实际收到的风**（真风 × 背风 × 天气）/ 风来向
#   目标方位 / 艏向 / 真风角(TWA) / 航海官选的航法 / 天气

const GEO := "res://data/world/atlantic/geography.json"
const DT := 0.5
const HOUR := 3600.0
const MAX_HOURS := 25.0


func _initialize() -> void:
	print("=== 情形 A：照原样的天气（会撞上无风带），只跑到第 12 小时 ===")
	_case("A", false, Vector2.ZERO, 12.0, false)
	print("=== 情形 B：天气按成晴天（隔离「无风带」这个变量）===")
	_case("B", true, Vector2.ZERO, MAX_HOURS, false)
	print("=== 情形 C：把船直接摆到卡住的位置，看航海官在下什么命令 ===")
	_case("C", false, Vector2(8559.0, 34420.0), 3.0, false)
	print("=== 情形 D：原样天气，但**不让那场「风向突变」发生** ===")
	_case("D", false, Vector2.ZERO, MAX_HOURS, true)
	quit(0)


func _case(label: String, force_clear: bool, at: Vector2, max_hours: float,
		no_wind_shift: bool) -> void:
	var v := Voyage.new()
	v.setup(GEO)
	if no_wind_shift:
		# `_events()` 里那条脚本事件：t > 300 秒时 `base_from_dir += 55°`（永久）。
		# 把旗标先立起来就跳过它 —— 用来隔离"风被判成东南之后才进不去"这个变量。
		v.fired["wind_shift"] = true
	var goal := v.default_destination()
	if at != Vector2.ZERO:
		# 摆到实测卡住的地方，直接对着终点下目标点（不走航线跟随）
		v.ship.set_pose(at, 80.0)
		v.ship.step(0.0, v.wind.velocity_world())
		v.orders.set_target_point(goal)
	else:
		v.start_route_follow()
	print("终点港 %s  起航位置 %s  强制晴天 = %s" % [
		str(goal), str(v.ship.position_m()), str(force_clear)])
	print("时间  离终点km  船速kn  真风  实收风  目标方位  艏向  命令艏向  TWA  航法        天气")
	var t := 0.0
	var hours := 0.0
	while hours < max_hours:
		# `force(id, hours)` 是给测试与剧情用的（docs/13 M7 卡片）
		if force_clear:
			v.weather.force("clear", 2.0)
		v.tick(DT)
		t += DT
		hours = t / HOUR
		# 情形 C 只有三个小时，改成每 10 分钟一行
		if fmod(t, HOUR if max_hours > 12.0 else 600.0) < DT:
			_row(v, hours, goal)
		if v.ship.position_m().distance_to(goal) < 300.0:
			print(">>> [%s] 第 %.1f 小时进港（离终点 %.0f m）" % [
				label, hours, v.ship.position_m().distance_to(goal)])
			break
	if v.ship.position_m().distance_to(goal) >= 300.0:
		print(">>> [%s] %.1f 小时里没进去，停在离终点 %.2f km、%.2f 节" % [
			label, hours, v.ship.position_m().distance_to(goal) / 1000.0, v.ship.speed_kn()])


func _row(v: Voyage, hours: float, goal: Vector2) -> void:
	var pos := v.ship.position_m()
	var felt := wind_felt(v, pos)
	var bearing := rad_to_deg((goal - pos).angle())
	var heading := v.ship.heading_deg()
	print("%5.2f  %7.2f  %6.2f  %5.1f  %6.2f  %8.0f  %5.0f  %8.0f  %4.0f  %-10s  %s" % [
		hours, pos.distance_to(goal) / 1000.0, v.ship.speed_kn(),
		v.wind.tws_ms, felt, fposmod(bearing, 360.0),
		fposmod(heading, 360.0), fposmod(v.nav.target_heading_deg, 360.0), v.ship.twa_deg(),
		v.nav.method_name(), v.weather.state_id])


func wind_felt(v: Voyage, pos: Vector2) -> float:
	return (v.wind.velocity_world() * v.sea.lee_factor(pos) * v.weather.wind_mult()).length()
