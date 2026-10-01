class_name SailPanel
extends Control

# 帆态观察面板（docs/01 支柱 5，Tab 呼出）。
#
# 它只回答一个问题：**船为什么慢** —— 是风不对，还是船员没调好？
#   风不对  = 视风角太顶、进了死区、风太小          -> 画在矢量图与数值条里
#   没调好  = 攻角偏离最优、帆还在收放中、人少且累   -> 画在数值条与诊断行里
#
# 三段（砍单顺序见 docs/02：先矢量图，侧视剪影可延后）：
#   A 俯视矢量图：真风 / 视风 / 船速 / 帆弦线 / 推力↔侧力分解
#   B 侧视剪影  ：横倾、桅杆倾斜、帆的拱度
#   C 数值条    ：视风角、攻角与偏差、L/D、推力、侧力、横倾、失速警告

const KNOT := 0.514444
const PANEL := Vector2(880.0, 430.0)

var font: Font
var ship: ShipDynamics
var crew: Crew
var nav: Navigator
var orders: ShipOrders


func update_from(p_ship: ShipDynamics, p_crew: Crew, p_nav: Navigator,
		p_orders: ShipOrders) -> void:
	ship = p_ship
	crew = p_crew
	nav = p_nav
	orders = p_orders
	queue_redraw()


func _draw() -> void:
	if ship == null or font == null:
		return
	var r := Rect2(Vector2.ZERO, PANEL)
	draw_rect(r, Color(0.03, 0.06, 0.09, 0.94), true)
	draw_rect(r, Color(0.45, 0.7, 0.9, 0.5), false, 2.0)

	_draw_vector_diagram(Rect2(12, 34, 330, 330))
	_draw_side_view(Rect2(354, 34, 200, 330))
	_draw_numbers(Rect2(566, 34, PANEL.x - 578.0, 384))
	draw_string(font, Vector2(14, 24), "帆态观察面板（Tab 关闭）", HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
		Color(0.85, 0.93, 1.0))


# ------------------------------------------------------------------ A 矢量图

func _panel_dir(world_deg: float) -> Vector2:
	"""世界方向 -> 面板方向：永远让**船首朝上**，这样玩家不用做心算。"""
	var a := deg_to_rad(world_deg - ship.heading_deg() - 90.0)
	return Vector2(cos(a), sin(a))


func _arrow(from: Vector2, dir: Vector2, length: float, color: Color, width := 2.5) -> void:
	var tip := from + dir * length
	draw_line(from, tip, color, width)
	var n := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([
		tip, tip - dir * 11.0 + n * 6.0, tip - dir * 11.0 - n * 6.0]), color)


func _draw_vector_diagram(box: Rect2) -> void:
	var c := box.position + box.size * 0.5
	var rad := box.size.x * 0.5 - 18.0
	draw_circle(c, rad, Color(0.06, 0.11, 0.16, 0.85))
	draw_arc(c, rad, 0.0, TAU, 48, Color(1, 1, 1, 0.18), 1.0)
	# 死区扇形：把"顶不上去的角度"直接画出来，玩家一眼就知道那一片不能走
	var no_go := nav.no_go_twa_deg() if nav else 42.0
	var wind_dir := _panel_dir(ship.wind_from_dir_deg())
	var wa := wind_dir.angle()
	draw_colored_polygon(_fan_points(c, rad, wa - deg_to_rad(no_go), wa + deg_to_rad(no_go), 24),
		Color(1.0, 0.35, 0.3, 0.16))

	var forces := ship.last_forces()
	var vscale := 3.4                      # 像素 / (m/s)
	# 真风与视风
	_arrow(c, _panel_dir(ship.wind_from_dir_deg() + 180.0),
		minf(ship.wind_ship_frame().length() * vscale, rad * 0.95), Color(1.0, 0.75, 0.35), 2.5)
	var aw := ship.apparent_wind_ship_frame()
	_arrow(c, _panel_dir(rad_to_deg(atan2(aw.y, aw.x)) + ship.heading_deg()),
		minf(aw.length() * vscale, rad * 0.95), Color(0.6, 0.9, 1.0), 2.5)
	# 船速（沿航向）
	_arrow(c, Vector2(0, -1), minf(ship.speed_ms() * vscale, rad * 0.7),
		Color(0.7, 1.0, 0.75), 3.0)
	# 帆弦线（主帆、前帆）
	var snap := ship.snapshot()
	for pair in [[float(snap["sail_main_deg"]), Color(0.95, 0.9, 0.7, 0.95), 3.0],
			[float(snap["sail_jib_deg"]), Color(0.95, 0.9, 0.7, 0.55), 2.0]]:
		var d := _panel_dir(float(pair[0]) + ship.heading_deg())
		draw_line(c - d * rad * 0.55, c + d * rad * 0.85, pair[1], pair[2])
	# 推力 ↔ 侧力分解（用上一帧的受力）
	if not forces.is_empty():
		var fscale: float = 0.012
		_arrow(c, Vector2(0, -1), clampf(float(forces["fx"]) * fscale, 0.0, rad), Color(0.5, 1.0, 0.6), 4.0)
		_arrow(c, Vector2(1, 0) * signf(float(forces["fy"])),
			clampf(absf(float(forces["fy"])) * fscale, 0.0, rad), Color(1.0, 0.5, 0.45), 4.0)
	# 船体（朝上）
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(0, -20), c + Vector2(9, 6), c + Vector2(7, 20),
		c + Vector2(-7, 20), c + Vector2(-9, 6)]), Color(0.85, 0.72, 0.45))
	draw_string(font, box.position + Vector2(6, 14), "俯视：船首朝上", HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(0.8, 0.88, 0.95, 0.9))
	draw_string(font, box.position + Vector2(6, box.size.y - 6),
		"橙=真风　蓝=视风　绿=船速　米色=帆　红扇=死区", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
		Color(0.75, 0.83, 0.9, 0.85))


func _fan_points(c: Vector2, r: float, a0: float, a1: float, steps: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.append(c)
	for i in steps + 1:
		var a := lerpf(a0, a1, float(i) / float(steps))
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts


# ------------------------------------------------------------------ B 侧视剪影

func _draw_side_view(box: Rect2) -> void:
	var mid := box.position + box.size * 0.5
	draw_string(font, box.position + Vector2(6, 14), "侧视：横倾与帆形", HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(0.8, 0.88, 0.95, 0.9))

	# 水线
	var wy := mid.y + 70.0
	draw_line(Vector2(box.position.x + 8, wy), Vector2(box.end.x - 8, wy), Color(0.4, 0.7, 0.9, 0.5), 2.0)
	# 船体（侧视：一个细长的梯形）
	draw_colored_polygon(PackedVector2Array([
		Vector2(mid.x - 78, wy - 14), Vector2(mid.x + 78, wy - 14),
		Vector2(mid.x + 58, wy + 12), Vector2(mid.x - 58, wy + 12)]),
		Color(0.55, 0.4, 0.22))

	# 桅杆按横倾倾斜：向背风侧倒
	var heel := deg_to_rad(ship.heel_deg())
	var mast_h := 120.0
	var tip := Vector2(mid.x + sin(heel) * mast_h, wy - 14.0 - cos(heel) * mast_h)
	draw_line(Vector2(mid.x, wy - 14.0), tip, Color(0.8, 0.65, 0.4), 4.0)
	# 帆：从桅杆上段张到船尾（按当前弦线角简化成一个三角形）
	var chord := deg_to_rad(ship.snapshot()["sail_main_deg"])
	var foot := Vector2(mid.x + cos(chord) * 95.0, wy - 16.0)
	var head := Vector2(lerpf(mid.x, tip.x, 0.82), lerpf(wy - 14.0, tip.y, 0.82))
	draw_colored_polygon(PackedVector2Array([head, foot, Vector2(mid.x, wy - 14.0)]),
		Color(0.95, 0.93, 0.85, 0.75))
	draw_line(head, foot, Color(0.8, 0.75, 0.6), 2.0)

	# 横倾读数
	draw_string(font, box.position + Vector2(6, box.size.y - 10),
		"横倾 %+.1f°（%s倾）" % [ship.heel_deg(), "右" if ship.heel_deg() > 0.0 else "左"],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.9, 0.95))


# ------------------------------------------------------------------ C 数值条

func _draw_numbers(box: Rect2) -> void:
	var snap := ship.snapshot()
	var forces := ship.last_forces()
	var lines: PackedStringArray = []
	lines.append("── 风 ──")
	lines.append("真风 %.1f m/s（%.1f 节）来向 %.0f°" % [
		ship.wind_ship_frame().length(), ship.wind_ship_frame().length() / KNOT,
		ship.wind_from_dir_deg()])
	lines.append("真风角 %.0f°　视风角 %.0f°" % [ship.twa_deg(), ship.awa_deg()])
	lines.append("── 帆 ──")
	lines.append("帆档 %s（有效面积 %d%%）" % [
		orders.sail_level_name() if orders else "?", int(ship.sail_area_scale() * 100.0)])
	lines.append("攻角 %.1f°　目标 %.1f°　偏差 %+.1f°" % [
		ship.sail_alpha_main_deg(), crew.alpha_target if crew else 0.0,
		crew.alpha_error_deg if crew else 0.0])
	lines.append("收放速度 %.1f°/s　%s" % [
		crew.trim_rate_dps if crew else 0.0,
		"（帆还在收放中）" if (crew and crew.trim_busy) else "（已到位）"])
	lines.append("── 力 ──")
	lines.append("推力 %+.0f N　侧力 %+.0f N" % [
		float(forces.get("fx", 0.0)), float(forces.get("fy", 0.0))])
	var l_over_d := 0.0
	if not forces.is_empty():
		var main: Vector2 = forces["main"]
		if absf(main.y) > 1e-6:
			l_over_d = absf(main.x) / maxf(absf(main.y), 1e-6)
	lines.append("横倾 %+.1f°　侧滑 %+.1f°" % [ship.heel_deg(), ship.leeway_deg()])
	lines.append("── 船 ──")
	lines.append("船速 %.2f 节（%.1f m/s）　航向 %.0f°" % [
		snap["u_kn"], snap["u_ms"], snap["heading_deg"]])
	lines.append("── 船员 ──")
	lines.append("操帆 %d 人　手艺 %.0f%%　疲劳 %.0f%%" % [
		crew.hands_on_sails if crew else 0,
		(crew.skill * 100.0) if crew else 0.0,
		(crew.fatigue * 100.0) if crew else 0.0])
	lines.append("── 航海官 ──")
	lines.append("%s　抢风 %d 段 / 换舷 %d 次" % [
		nav.method_name(), nav.beat_count, nav.tack_count] if nav else "-")
	lines.append(orders.describe() if orders else "-")

	var y := box.position.y + 6.0
	for i in lines.size():
		var text: String = lines[i]
		var col := Color(0.86, 0.92, 0.98)
		if text.begins_with("──"):
			col = Color(0.55, 0.75, 0.95)
		draw_string(font, Vector2(box.position.x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
		y += 19.0

	# 诊断行：直接回答"船为什么慢"
	var diag := _diagnosis()
	draw_string(font, Vector2(box.position.x, box.end.y - 22), diag[0],
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x, 15, diag[1])
	if diag.size() > 2:
		draw_string(font, Vector2(box.position.x, box.end.y - 4), diag[2],
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x, 12, Color(0.75, 0.82, 0.9))


func _diagnosis() -> Array:
	"""一句话告诉玩家：慢是风的问题，还是人的问题。"""
	if ship.is_anchored():
		return ["诊断：抛锚中", Color(0.9, 0.85, 0.6)]
	if ship.sail_area_scale() <= 0.0:
		return ["诊断：收帆了，帆不产生推力", Color(0.9, 0.85, 0.6)]
	var aw := ship.apparent_wind_ship_frame()
	if aw.length() < 1.0:
		return ["诊断：几乎没风", Color(0.9, 0.8, 0.5)]
	var stall := float(ship.last_forces().get("stall_over", 0.0))
	if stall > 0.05:
		return ["诊断：风不对 —— 龙骨失速，船在横着漂", Color(1.0, 0.55, 0.5),
			"把船头转出去一点（目标航向离风向拉开），等速度起来再顶上去"]
	var err := absf(crew.alpha_error_deg) if crew else 0.0
	if err > 6.0:
		return ["诊断：船员没调好 —— 攻角偏了 %.0f°" % err, Color(1.0, 0.8, 0.45),
			"人少/手艺低/疲劳都会让帆收不准；调人去操帆或等他们缓一缓"]
	if crew and crew.trim_busy:
		return ["诊断：帆还在收放中（%.1f°/s）" % crew.trim_rate_dps, Color(0.8, 0.9, 0.6)]
	if ship.speed_kn() > 0.4 and ship.twa_deg() < 45.0:
		return ["诊断：正顶着风走 —— 抢风前进本来就慢", Color(0.8, 0.85, 0.95),
			"想更快要走之字形：让目标点偏开风向一侧"]
	return ["诊断：风帆配合正常", Color(0.6, 0.95, 0.7),
		"船速就是这阵风、这个舷角能给的上限"]
