# 测试海域视图（Day 6）：把 8km×8km 的海、岛、礁、洋流画出来，让船开出去。
#
# 相机状态（docs/01 支柱 5）：
#   A 甲板/海面 —— 跟着船
#   C 离船      —— 船长带人上岛，相机跟着船长，船留在海面上自己走（大副接管）
#
# 操作：
#   左键 = 设目标点（船长在岸上时 = 带队伍走过去）
#   X 抛锚 / 起锚　1/2/3 帆档　+/− 操帆人数
#   L 登陆 / 返船　空格 登陆名单里勾人　Tab 帆态面板　C 船员面板
#   . 快进一分钟（演示用）　滚轮 缩放

extends Node2D

const PPM := 0.25                 # 每米多少像素（zoom=1 时整片海 2000px 宽）
const SIM_DT := 0.05

var voyage: Voyage
var _hud: Label
var _font: Font
var _cam: Camera2D
var _zoom := 0.9
var _fast_forward := 0.0
var _picking_party := false
var _party_index := 0
var _party_pick := {}
var _shot_mode := false
var _frame := 0
var _shot_dir := "res://.shots"
var _wind_gizmo: WindGizmo
var _panel: SailPanel
var _show_panel := false
var _crew_panel: CrewPanel
var _show_crew_panel := false


func _ready() -> void:
	voyage = Voyage.new()
	voyage.setup()
	_cam = Camera2D.new()
	add_child(_cam)
	_font = _pick_font()
	_build_hud()
	_update_camera()
	_update_hud()
	_shot_mode = OS.get_cmdline_user_args().has("shots")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_shot_dir))


func _process(delta: float) -> void:
	if _shot_mode:
		_run_shot_timeline()
		return
	var dt: float = minf(delta, 0.1)
	voyage.tick(dt)
	if _fast_forward > 0.0:
		var left := minf(_fast_forward, 1.0)
		_fast_forward -= left
		var steps := int(left / SIM_DT)
		for _i in steps:
			voyage.tick(SIM_DT)
	_update_camera()
	_update_hud()
	queue_redraw()


func _update_camera() -> void:
	if voyage.ashore:
		# 状态 C：相机跟着船长，船离屏
		_cam.position = voyage.captain_pos * PPM
		_cam.zoom = Vector2(_zoom * 3.0, _zoom * 3.0)
	else:
		_cam.position = voyage.ship.position_m() * PPM
		_cam.zoom = Vector2(_zoom, _zoom)


# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	if voyage == null:
		return
	var sea := voyage.sea
	var size := sea.size_m() * PPM
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0b1a26"), true)
	# 洋流带
	var cur: Dictionary = sea.data.get("current", {})
	if not cur.is_empty():
		var a: Array = cur["from"]
		var b: Array = cur["to"]
		var pa := Vector2(float(a[0]), float(a[1])) * PPM
		var pb := Vector2(float(b[0]), float(b[1])) * PPM
		draw_line(pa, pb, Color(0.35, 0.75, 0.9, 0.18), float(cur.get("width_m", 0.0)) * PPM)
		_arrow(pa, pb, Color(0.45, 0.85, 1.0, 0.5), 2.0)
	# 出发港
	var port_d: Dictionary = sea.port()
	var pp: Array = port_d["pos"]
	var pc := Vector2(float(pp[0]), float(pp[1])) * PPM
	draw_circle(pc, float(port_d.get("radius_m", 0.0)) * PPM, Color(0.35, 0.5, 0.65, 0.35))
	draw_arc(pc, float(port_d.get("radius_m", 0.0)) * PPM, 0, TAU, 40, Color(0.6, 0.8, 1.0, 0.7), 2.0)
	_label(pc, str(port_d.get("name", "")), Color(0.7, 0.85, 1.0))
	# 暗礁
	if not sea.data.get("reef", {}).is_empty():
		var rd: Dictionary = sea.data["reef"]
		var rp: Array = rd["pos"]
		var rpc := Vector2(float(rp[0]), float(rp[1])) * PPM
		var rr := float(rd.get("radius_m", 0.0)) * PPM
		draw_circle(rpc, rr, Color(0.6, 0.35, 0.3, 0.35))
		draw_arc(rpc, rr, 0, TAU, 32, Color(0.9, 0.55, 0.45, 0.8), 2.0)
		_label(rpc, str(rd.get("name", "")), Color(1.0, 0.7, 0.6))
	# 岛
	var isl: Dictionary = sea.island()
	var ic: Array = isl["center"]
	var icp := Vector2(float(ic[0]), float(ic[1])) * PPM
	var ir := float(isl.get("radius_m", 0.0)) * PPM
	var bw := float(isl.get("beach_width_m", 0.0)) * PPM
	draw_circle(icp, ir, Color(0.78, 0.72, 0.5, 0.9))            # 沙
	draw_circle(icp, ir - bw, Color(0.32, 0.5, 0.28, 0.95))      # 草木
	draw_arc(icp, ir, 0, TAU, 64, Color(0.9, 0.85, 0.65, 0.8), 2.0)
	_label(icp, str(isl.get("name", "")), Color(0.95, 0.95, 0.8))
	# 地标
	for poi in sea.pois():
		var p: Array = poi["pos"]
		var v := Vector2(float(p[0]), float(p[1])) * PPM
		var seen := voyage.visited.has(str(poi["id"]))
		var col := Color(0.6, 1.0, 0.7) if seen else Color(0.95, 0.9, 0.5)
		draw_circle(v, 5.0, col)
		draw_arc(v, float(poi.get("radius_m", 0.0)) * PPM, 0, TAU, 24, Color(col, 0.45), 1.5)
		_label(v, str(poi["name"]), col)
	# 船 / 船长
	if voyage.ashore:
		var c := voyage.captain_pos * PPM
		draw_circle(c, 7.0, Color(1.0, 0.85, 0.35))
		draw_arc(c, 11.0, 0, TAU, 20, Color(1.0, 0.9, 0.5, 0.6), 2.0)
		_draw_ship_marker(voyage.ship.position_m() * PPM, voyage.ship.heading_deg(), 0.8)
	else:
		_draw_ship_marker(voyage.ship.position_m() * PPM, voyage.ship.heading_deg(), 1.0)
	# 航线：从船到目标点
	if voyage.orders.has_target_point:
		draw_dashed_line(voyage.ship.position_m() * PPM, voyage.orders.target_point * PPM,
			Color(0.5, 1.0, 0.7, 0.4), 2.0, 10.0)
	if _picking_party:
		_draw_party_picker()


func _draw_ship_marker(at: Vector2, heading_deg: float, alpha: float) -> void:
	var h := deg_to_rad(heading_deg)
	var fwd := Vector2(cos(h), sin(h))
	var side := Vector2(-sin(h), cos(h))
	var bow := at + fwd * 9.0
	var st := at - fwd * 7.0 + side * 5.0
	var pt := at - fwd * 7.0 - side * 5.0
	draw_colored_polygon(PackedVector2Array([bow, st, pt]),
		Color(0.95, 0.85, 0.55, alpha))
	draw_line(at, at + fwd * 12.0, Color(0.6, 0.5, 0.3, alpha), 2.0)


func _arrow(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	draw_line(a, b, col, width)
	var d := (b - a).normalized()
	var n := Vector2(-d.y, d.x)
	var mid := a.lerp(b, 0.5)
	draw_colored_polygon(PackedVector2Array([
		mid + d * 14.0, mid + n * 8.0, mid - n * 8.0]), col)


func _label(at: Vector2, text: String, col: Color) -> void:
	draw_string(_font, at + Vector2(9, 5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)


# ------------------------------------------------------------------ 输入

func _unhandled_input(event: InputEvent) -> void:
	if _shot_mode:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom * 1.2, 0.15, 4.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom / 1.2, 0.15, 4.0)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			var world := get_viewport().get_canvas_transform().affine_inverse() * mb.position
			var target := world / PPM
			if voyage.ashore:
				voyage.move_party_to(target)
			else:
				voyage.orders.set_target_point(target)
		_update_camera()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_key(event as InputEventKey)
		_update_camera()


func _key(k: InputEventKey) -> void:
	match k.keycode:
		KEY_X:
			voyage.orders.anchored = not voyage.orders.anchored
			if voyage.orders.anchored:
				voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
			else:
				voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
		KEY_1:
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
		KEY_2:
			voyage.orders.set_sail_level(ShipOrders.SailLevel.REEF)
		KEY_3:
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
		KEY_EQUAL, KEY_KP_ADD:
			voyage.orders.set_hands(voyage.orders.hands_on_sails + 1)
		KEY_MINUS, KEY_KP_SUBTRACT:
			voyage.orders.set_hands(voyage.orders.hands_on_sails - 1)
		KEY_PERIOD:
			_fast_forward += 60.0
		KEY_L:
			if voyage.ashore:
				var msg := voyage.return_to_ship()
				voyage._say("（船长）" + msg, true)
			elif voyage.can_land():
				_picking_party = true
				_party_index = 0
				_party_pick.clear()
			else:
				voyage._say("还没到滩头：先把船开过去，抛锚（X），再按 L。", true)
		KEY_SPACE:
			if _picking_party:
				var crew := voyage.roster.key_crew()
				var m: CrewMember = crew[_party_index]
				if _party_pick.has(m.id):
					_party_pick.erase(m.id)
				else:
					_party_pick[m.id] = true
			else:
				voyage.orders.clear_target_point()
		KEY_UP, KEY_W:
			if _picking_party:
				_party_index = clampi(_party_index - 1, 0, voyage.roster.key_crew().size() - 1)
		KEY_DOWN, KEY_S:
			if _picking_party:
				_party_index = clampi(_party_index + 1, 0, voyage.roster.key_crew().size() - 1)
		KEY_ENTER, KEY_KP_ENTER:
			if _picking_party:
				var ids := _party_pick.keys()
				_picking_party = false
				voyage.land(ids, 6)
		KEY_TAB:
			_show_panel = not _show_panel
			_panel.visible = _show_panel
		KEY_C:
			_show_crew_panel = not _show_crew_panel
			_crew_panel.visible = _show_crew_panel
		KEY_ESCAPE:
			_picking_party = false


# ------------------------------------------------------------------ HUD 与面板

func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_override("font", _font)
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud.add_theme_constant_override("outline_size", 6)
	cl.add_child(_hud)

	_wind_gizmo = WindGizmo.new()
	_wind_gizmo.font = _font
	var side := 200.0
	_wind_gizmo.size = Vector2(side, side)
	_wind_gizmo.position = get_viewport_rect().size - Vector2(side + 18.0, side + 18.0)
	cl.add_child(_wind_gizmo)

	var cl2 := CanvasLayer.new()
	cl2.layer = 2
	add_child(cl2)
	_panel = SailPanel.new()
	_panel.font = _font
	_panel.size = SailPanel.PANEL
	_panel.position = (get_viewport_rect().size - SailPanel.PANEL) * 0.5
	_panel.visible = false
	cl2.add_child(_panel)
	_crew_panel = CrewPanel.new()
	_crew_panel.font = _font
	_crew_panel.size = CrewPanel.PANEL
	_crew_panel.position = (get_viewport_rect().size - CrewPanel.PANEL) * 0.5
	_crew_panel.visible = false
	cl2.add_child(_crew_panel)


func _update_hud() -> void:
	if _hud == null:
		return
	_wind_gizmo.set_wind(voyage.wind.from_dir_deg, voyage.wind.tws_ms)
	if _show_panel:
		_panel.update_from(voyage.ship, voyage.crew, voyage.nav, voyage.orders)
	if _show_crew_panel:
		_crew_panel.update_from(voyage.roster)
	var v := voyage
	var lines: PackedStringArray = []
	lines.append("测试海域（%.0f 分钟）%s" % [
		v.t / 60.0, "　☀ 相机跟着船长" if v.ashore else ""])
	lines.append("左键 设目标点　X 抛锚　1/2/3 帆档　+/− 人数　L 登陆/返船　. 快进一分钟")
	lines.append("Tab 帆态面板　C 船员面板　滚轮 缩放")
	lines.append("——")
	lines.append(v.describe())
	lines.append("损伤：%s" % v.ship.describe_damage())
	lines.append("船员：%s" % v.roster.describe())
	if v.ashore:
		lines.append("船长在岸上，身边 %d 人。左键点岸边带他们走过去，走回滩头按 L 上船。" % v.party_size())
	elif v.can_land():
		lines.append("★ 到了滩头附近：按 L 选人登陆（记得先抛锚）")
	lines.append("航海日志：%s" % (v.log_lines[-1] if v.log_lines.size() > 0 else "——"))
	if v.message_timer > 0.0:
		lines.append("【%s】" % v.last_message)
	_hud.text = "\n".join(lines)


func _pick_font() -> Font:
	for p in ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]:
		if not FileAccess.file_exists(p):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(p) == OK:
			return f
	push_warning("没找到中文字体，标签可能显示为方块")
	return ThemeDB.fallback_font


# ------------------------------------------------------------------ 截图

func _run_shot_timeline() -> void:
	_frame += 1
	_update_camera()          # 截图模式下 _process 提前返回了，这里要自己同步相机
	_update_hud()
	queue_redraw()
	match _frame:
		4:
			_zoom = 0.35                      # 出海前：整片海一览
		8:
			_capture("20_sea_overview")
		12:
			_zoom = 0.9
			voyage.orders.set_target_point(Vector2(3600, 3600))
			_warp(900.0)
		16:
			_capture("21_under_way")
		20:
			_warp(500.0)                      # 继续开，瞭望员会报告陆地
		24:
			_capture("22_island_sighted")
		26:
			# 这条航线正好穿过暗礁 —— 风向突变之后船被压过去，触礁（因果链的中间一环）
			voyage.orders.set_target_point(Vector2(2800, 1200))
			_warp(1300.0)
		32:
			_capture("23_reef_hit")
		36:
			voyage.orders.set_target_point(Vector2(4520, 3600))
			_warp(1700.0)
		40:
			# 截图脚本：把船直接摆到滩头外（航行过程已经在前两格演示过了）
			voyage.ship.set_pose(Vector2(4520, 3600), 0.0)
			voyage.orders.anchored = true
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
			_warp(120.0)
		44:
			_capture("24_anchored_off_beach")
		48:
			var ids := ["piloto", "carpintero", "cirujano", "escribano"]
			print("[shot] 登陆：%s" % voyage.land(ids, 6))
			voyage.move_party_to(Vector2(5620, 3320))
			_warp(240.0)
		52:
			_capture("25_ruins")
		56:
			voyage.move_party_to(Vector2(6080, 3820))
			_warp(200.0)
		60:
			_capture("26_stream")
		64:
			voyage.move_party_to(Vector2(4790, 3600))
			_warp(260.0)
			_deliver_reports()
		68:
			_capture("27_back_with_reports")
		70:
			print("[shot] 报告：%s" % str(voyage.pending_reports))
			_zoom = 0.35
			_warp(60.0)
		74:
			_capture("28_homeward")
		80:
			get_tree().quit(0)


func _deliver_reports() -> void:
	if not voyage.ashore:
		return
	var msg := voyage.return_to_ship()
	voyage._say("（船长）" + msg, true)
	_update_hud()


func _warp(seconds: float) -> void:
	var steps := int(seconds / SIM_DT)
	for _i in steps:
		voyage.tick(SIM_DT)
	_update_camera()
	_update_hud()
	queue_redraw()


func _capture(name: String) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[shot] 拿不到 viewport 纹理")
		return
	var img := tex.get_image()
	var err := img.save_png("%s/%s.png" % [_shot_dir, name])
	print("[shot] %-24s err=%d  第 %.0f 分钟  %s" % [
		name, err, voyage.t / 60.0, voyage.describe()])


func _draw_party_picker() -> void:
	"""登陆名单：↑↓ 选人，空格勾选，回车确认。"""
	var crew := voyage.roster.key_crew()
	var w := 420.0
	var h := 60.0 + float(crew.size()) * 24.0
	var origin := (get_viewport_rect().size - Vector2(w, h)) * 0.5
	draw_rect(Rect2(origin, Vector2(w, h)), Color(0.03, 0.06, 0.09, 0.95), true)
	draw_rect(Rect2(origin, Vector2(w, h)), Color(0.95, 0.8, 0.35, 0.8), false, 2.0)
	draw_string(_font, origin + Vector2(14, 26), "带谁上岸？（↑↓ 选人，空格勾选，回车确认）",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1.0, 0.95, 0.8))
	for i in crew.size():
		var m: CrewMember = crew[i]
		var y := origin.y + 50.0 + float(i) * 24.0
		var sel := i == _party_index
		if sel:
			draw_rect(Rect2(origin.x + 8.0, y - 16.0, w - 16.0, 23.0),
				Color(0.85, 0.7, 0.3, 0.30), true)
		var mark := "[×]" if _party_pick.has(m.id) else "[　]"
		draw_string(_font, Vector2(origin.x + 16.0, y), "%s %s" % [mark, m.label()],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
			Color(1.0, 0.98, 0.85) if sel else Color(0.85, 0.9, 0.95))
