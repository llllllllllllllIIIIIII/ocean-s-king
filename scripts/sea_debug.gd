# 测试海域视图（Day 6）：把 8km×8km 的海、岛、礁、洋流画出来，让船开出去。
#
# 相机状态（docs/01 支柱 5）：
#   A 甲板/海面 —— 跟着船
#   C 离船      —— 船长带人上岛，相机跟着船长，船留在海面上自己走（大副接管）
#
# 操作（Day 7 定稿）：
#   开场先是一页标题与背景（陌生人必须知道自己在哪儿、要干什么），按任意键开始
#   左键 = 设目标点（船长在岸上时 = 带队伍走过去）
#   X 抛锚 / 起锚　1/2/3 帆档　+/− 操帆人数
#   L 登陆 / 返船　空格 登陆名单里勾人　Tab 帆态面板　C 船员面板
#   . 快进 ×1/×4/×12（8 公里的海不开快进，一局就不是 15 分钟了）　滚轮 缩放
#   走完第三幕 → 一页文本结算（R 重开）

extends Node2D

const PPM := 0.5                  # 每米多少像素（zoom=0.25 时整片海 2000px 宽）
const SIM_DT := 0.05
# 一路滚到底的"船内视图"倍率：0.5 × 80 = 40 像素/米，正好等于船内调试视图的比例。
# 也就是说这个场景的相机是**连续的**：整片海 → 海图 → 船 → 船舱，同一套东西。
const SHIP_ZOOM := 80.0
const LAYER_STEP_ZOOM := 1.6

enum Mode { SEA, LAYER }

var voyage: Voyage
var _hud: VoyageHud
var _title: TitleCard
var _ending: EndingPanel
var _hud_layer: CanvasLayer
var _panel_layer: CanvasLayer
var _font: Font
var _cam: Camera2D
var _zoom := 1.0
var _mode: Mode = Mode.SEA
var _layer := 2
var _layer_order: Array[int] = []
var _started := false              # 标题卡关掉之前，一帧模拟都不跑
var _time_scales: Array[float] = [1.0, 4.0, 12.0]
var _time_scale_idx := 0
var _last_head := -1               # 上一次看到的"演到第几幕"，用来放剧情卡
var _act_card_timer := 0.0         # 剧情卡的剩余播放时间（真实秒）
var _act_card_seconds := 9.0       # 剧情卡放多久（截图模式下压到 2 秒，免得挡住一组图）
var _picker: LandingPicker
var _shot_mode := false
var _frame := 0
var _shot_dir := "res://.shots"
var _wind_gizmo: WindGizmo
var _ship_view: ShipRenderer       # 海图上用**真正的 SVG 船**，不是占位三角块
var _panel: SailPanel
var _show_panel := false
var _crew_panel: CrewPanel
var _show_crew_panel := false


func _ready() -> void:
	_shot_mode = OS.get_cmdline_user_args().has("shots")
	voyage = Voyage.new()
	voyage.setup()
	_ship_view = ShipRenderer.new()
	_ship_view.px_per_m = PPM
	_ship_view.draw_sea = false        # 海面由这个场景自己画
	_ship_view.show_ghost = false
	add_child(_ship_view)
	_ship_view.setup()
	_ship_view.apply_pose(voyage.ship.position_m(), voyage.ship.heading_deg())
	_layer_order.assign(_ship_view.layers.keys())
	_layer_order.sort()
	_layer_order.reverse()              # [3, 2, 1, 0]，下标越大层越低
	_cam = Camera2D.new()
	add_child(_cam)
	_font = _pick_font()
	_build_hud()
	_build_overlays()
	_update_camera()
	_update_hud()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_shot_dir))
	# 截图模式不等人：直接开演（标题卡由时间线自己在第 2 帧截一张）
	_started = _shot_mode
	if not _shot_mode:
		_act_card_seconds = 9.0
		_show_overlay(_title, true)
	else:
		_act_card_seconds = 2.0


func _process(delta: float) -> void:
	if _shot_mode:
		_run_shot_timeline()
		return
	if _started:
		_tick_sim(delta)
		voyage.tick_ui(delta)          # 消息条按真实时间消失，不跟着快进闪过去
	if _act_card_timer > 0.0:
		_act_card_timer = maxf(0.0, _act_card_timer - delta)
	_update_camera()
	_update_hud()
	queue_redraw()


func _tick_sim(delta: float) -> void:
	"""推进模拟。快进不是"把 dt 乘大" —— 那样物理步会变粗、气动跟着飘。
	这里永远是固定步长 SIM_DT，快进只是每帧多跑几步。"""
	var scale := _time_scales[_time_scale_idx]
	var real_dt := minf(delta, 0.1)
	if scale <= 1.0:
		voyage.tick(real_dt)
	else:
		var steps := int(real_dt * scale / SIM_DT)
		for _i in steps:
			voyage.tick(SIM_DT)


func _update_camera() -> void:
	if _mode == Mode.LAYER:
		# 沉进船舱了：相机锁在船体中心（和船内调试视图一样）
		_cam.position = _ship_view.hull_center_world_px()
		_cam.zoom = Vector2(_zoom, _zoom)
	elif voyage.ashore:
		# 状态 C：相机跟着船长，船离屏
		_cam.position = voyage.captain_pos * PPM
		# 只放近一点点：放太多的话船会跑出画面，"人在哪下船"就看不清了
		_cam.zoom = Vector2(_zoom * 2.0, _zoom * 2.0)
	else:
		_cam.position = voyage.ship.position_m() * PPM
		_cam.zoom = Vector2(_zoom, _zoom)


func _sync_ship_view() -> void:
	"""把船的状态交给真正的渲染器（和船内视图是同一个 ShipRenderer）。"""
	var snap := voyage.ship.snapshot()
	_ship_view.apply_pose(voyage.ship.position_m(), voyage.ship.heading_deg())
	_ship_view.sail_main_rad = deg_to_rad(180.0 - float(snap["sail_main_deg"]))
	_ship_view.sail_jib_rad = deg_to_rad(180.0 - float(snap["sail_jib_deg"]))
	_ship_view.sail_state = int(voyage.orders.sail_level)
	_ship_view.anchored = voyage.ship.is_anchored()
	_ship_view.layer = _layer
	_ship_view.show_ghost = _zoom > 20.0        # 拉到能看清船了才画上层虚影
	# 注意：这里**不能**打开渲染器自带的海面矩形 —— 它是一块画在世界坐标里的深色底，
	# 近距离时会把海图（岛、礁、洋流）整块盖住，玩家就看不到附近地形了。
	_ship_view.draw_sea = false
	_ship_view.zoom = _zoom
	_ship_view.crew_dots = _crew_dots()
	_ship_view.queue_redraw()


func _crew_dots() -> Array:
	"""只有在看得清船的距离上才画人（海图尺度下那只是几个亚像素的点）。"""
	var out := []
	if _zoom < 20.0 or voyage.roster == null:
		return out
	for m in voyage.roster.members:
		if m.at.z != _layer or m.ashore:
			continue
		out.append({"x": m.at.x, "y": m.at.y, "color": _job_color(m.job), "key": m.is_key})
	return out


func _job_color(job: String) -> Color:
	match job:
		"sail": return Color(0.45, 0.75, 1.0)
		"helm": return Color(1.0, 0.85, 0.4)
		"lookout": return Color(0.6, 1.0, 0.6)
		"cook": return Color(1.0, 0.6, 0.35)
		"repair": return Color(0.85, 0.85, 0.9)
		"chores": return Color(0.9, 0.9, 0.6)
		"eat": return Color(1.0, 0.95, 0.5)
		"sleep": return Color(0.7, 0.6, 1.0)
		_: return Color(0.72, 0.74, 0.78)


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
		draw_circle(v, 5.0 * _marker_scale(), col)
		draw_arc(v, float(poi.get("radius_m", 0.0)) * PPM, 0, TAU, 24, Color(col, 0.45), 1.5)
		_label(v, str(poi["name"]), col)
	# 船：交给真正的 ShipRenderer 画（海图和船内视图是同一个渲染器）
	_sync_ship_view()
	# 拉远到看不清船的时候，给一个明显的光点，免得找不到自己的船
	if _zoom < 0.7:
		var sp := voyage.ship.position_m() * PPM
		draw_circle(sp, 10.0, Color(1.0, 0.92, 0.55, 0.20))
		draw_arc(sp, 10.0, 0.0, TAU, 20, Color(1.0, 0.95, 0.7, 0.85), 2.0)
	if voyage.ashore:
		# 登陆队：每人一个点（船上还没下来的画在船边，下来的在岸上排成队形）
		var k := _marker_scale()
		for e in voyage.party.entries:
			var st: String = e["state"]
			if st == "onboard":
				continue
			var at: Vector2 = (e["pos"] as Vector2) * PPM
			var is_key: bool = e["key"]
			var col := Color(0.98, 0.86, 0.45, 0.95) if is_key else Color(0.85, 0.88, 0.92, 0.95)
			if is_key:
				draw_circle(at, 7.0 * k, Color(0.08, 0.09, 0.12, 0.9))
				draw_circle(at, 5.0 * k, col)
			else:
				draw_circle(at, 4.0 * k, col)
		# 队长（船长本人）
		var c := voyage.party.captain * PPM
		draw_circle(c, 8.0 * k, Color(1.0, 0.85, 0.35))
		draw_arc(c, 13.0 * k, 0, TAU, 20, Color(1.0, 0.9, 0.5, 0.6), 2.0 * k * 2.0)
	# 航线：从船到目标点
	if voyage.orders.has_target_point:
		draw_dashed_line(voyage.ship.position_m() * PPM, voyage.orders.target_point * PPM,
			Color(0.5, 1.0, 0.7, 0.4), 2.0, 10.0)
	# 抉择做完了（上过岸，或者把岛甩在了身后）：把回港的方向标出来。
	# 没有它，第三幕的"返航"就只是一句话，玩家不知道往哪儿开。
	if voyage.story.fired("act2") and not voyage.story.fired("act3") \
			and not voyage.ashore and voyage.story.objective.begins_with("返航"):
		var home := voyage.ship.position_m().lerp(Vector2(float(pp[0]), float(pp[1])), 0.5)
		draw_dashed_line(voyage.ship.position_m() * PPM,
			Vector2(float(pp[0]), float(pp[1])) * PPM, Color(1.0, 0.85, 0.45, 0.32), 2.0, 14.0)
		draw_arc(pc, 22.0 * _marker_scale(), 0.0, TAU, 32, Color(1.0, 0.86, 0.45, 0.8), 2.0)
		_label(home, "返航点：出发港", Color(1.0, 0.88, 0.5))


func _arrow(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	draw_line(a, b, col, width)
	var d := (b - a).normalized()
	var n := Vector2(-d.y, d.x)
	var mid := a.lerp(b, 0.5)
	draw_colored_polygon(PackedVector2Array([
		mid + d * 14.0, mid + n * 8.0, mid - n * 8.0]), col)


func _label(at: Vector2, text: String, col: Color) -> void:
	# 地名只在"看地图"的距离上画：字号按相机缩放反向补偿，屏幕上恒定 ~14px。
	# 拉得很近时干脆不画 —— 那会儿画面上全是沙滩，地名会变成糊在脸上的巨字。
	var eff := _zoom * (2.0 if voyage.ashore else 1.0)
	if eff > 3.0:
		return
	var size := maxi(8, int(14.0 / eff))
	draw_string(_font, at + Vector2(9, 5) / eff, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		size, col)


func _marker_scale() -> float:
	"""标记点（人、地标圆点）按屏幕尺寸画：不管拉多远拉多近，看上去都一样大。

	世界单位画点的话，一拉近就变成糊在屏幕上的大色块（队形会糊成一坨）。
	"""
	var eff := _zoom * (2.0 if voyage.ashore else 1.0)
	return 1.0 / maxf(eff, 0.05)


# ------------------------------------------------------------------ 输入

func _unhandled_input(event: InputEvent) -> void:
	if _shot_mode:
		return
	# 标题卡还摊在桌上：任何键、任何一次点击 = 开始（这是"陌生人 15 分钟"的第一道门）
	if _title.visible:
		var pressed := (event is InputEventKey and (event as InputEventKey).pressed) \
			or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
		if pressed:
			_show_overlay(_title, false)
			_started = true
		return
	# 结算页：R 再走一趟，Esc 收起来继续看海（别的键不管）
	if _ending.visible:
		if event is InputEventKey and (event as InputEventKey).pressed \
				and not (event as InputEventKey).echo:
			match (event as InputEventKey).keycode:
				KEY_R:
					get_tree().reload_current_scene()
				KEY_ESCAPE:
					_show_overlay(_ending, false)
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_wheel(-1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_wheel(1)
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


func _wheel(dir: int) -> void:
	"""滚轮就是一根轴：整片海 → 海图 → 船 → 穿过甲板沉进船舱。

	这一条是刻意的：玩家不需要在"看船"和"看海"之间切场景 —— 同一套相机，
	同一艘船，只是拉远拉近。拉到最近还继续向下，就进入船内分层模式。
	"""
	if _mode == Mode.LAYER:
		var idx := _layer_order.find(_layer) + dir
		if idx < 0:                              # 在最上层继续向上 -> 回到缩放
			_mode = Mode.SEA
			_layer = 2
		else:
			_layer = _layer_order[clampi(idx, 0, _layer_order.size() - 1)]
	else:
		if dir > 0 and _zoom >= SHIP_ZOOM:
			_mode = Mode.LAYER                   # 拉到最近再向下 -> 沉入船舱
			_layer = _layer_order[_layer_order.find(_layer) + 1]
		else:
			_zoom = clampf(_zoom * (1.2 if dir > 0 else 1.0 / 1.2), 0.15, SHIP_ZOOM)
	_update_camera()
	_update_hud()
	queue_redraw()


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
			_time_scale_idx = (_time_scale_idx + 1) % _time_scales.size()
			voyage.say("时间 ×%d。" % int(_time_scales[_time_scale_idx]))
		KEY_L:
			if voyage.ashore:
				var msg := voyage.return_to_ship()
				voyage.say("（船长）" + msg, true)
			elif voyage.can_land():
				_picker.open(voyage.roster)
				_picker.visible = true
			else:
				voyage.say("还没到滩头：先把船开过去，抛锚（X），再按 L。", true)
		KEY_SPACE:
			if _picker.visible:
				_picker.toggle_current()
			else:
				voyage.orders.clear_target_point()
		KEY_UP, KEY_W:
			if _picker.visible:
				_picker.move(-1)
		KEY_DOWN, KEY_S:
			if _picker.visible:
				_picker.move(1)
		KEY_ENTER, KEY_KP_ENTER:
			if _picker.visible:
				_picker.visible = false
				voyage.land(_picker.selected_ids(), _picker.hands)
		KEY_TAB:
			_show_panel = not _show_panel
			_panel.visible = _show_panel
			if _show_panel:
				voyage.story.note("open_sail_panel")
		KEY_C:
			_show_crew_panel = not _show_crew_panel
			_crew_panel.visible = _show_crew_panel
		KEY_ESCAPE:
			_picker.visible = false


# ------------------------------------------------------------------ HUD 与面板

func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud_layer = cl
	_hud = VoyageHud.new()
	_hud.font = _font
	_hud.voyage = voyage
	_hud.size = get_viewport_rect().size
	# 界面不接鼠标：所有输入都走 _unhandled_input（点目标点、带队上岸）
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	_panel_layer = cl2
	_panel = SailPanel.new()
	_panel.font = _font
	_panel.size = SailPanel.PANEL
	_panel.position = (get_viewport_rect().size - SailPanel.PANEL) * 0.5
	_panel.visible = false
	cl2.add_child(_panel)
	_picker = LandingPicker.new()
	_picker.font = _font
	_picker.size = LandingPicker.PANEL
	_picker.position = (get_viewport_rect().size - LandingPicker.PANEL) * 0.5
	_picker.visible = false
	cl2.add_child(_picker)
	_crew_panel = CrewPanel.new()
	_crew_panel.font = _font
	_crew_panel.size = CrewPanel.PANEL
	_crew_panel.position = (get_viewport_rect().size - CrewPanel.PANEL) * 0.5
	_crew_panel.visible = false
	cl2.add_child(_crew_panel)


func _build_overlays() -> void:
	"""标题卡与结算页：盖在整幅画面最上面，而且不接鼠标（点击要能漏到下面去）。"""
	var cl := CanvasLayer.new()
	cl.layer = 8
	add_child(cl)
	var vp := get_viewport_rect().size
	_ending = EndingPanel.new()
	_ending.font = _font
	_ending.size = vp
	_ending.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ending.visible = false
	cl.add_child(_ending)

	var cl2 := CanvasLayer.new()
	cl2.layer = 9
	add_child(cl2)
	_title = TitleCard.new()
	_title.font = _font
	_title.title = voyage.story.title
	_title.subtitle = voyage.story.subtitle
	_title.heading = voyage.story.opening_heading
	_title.body = voyage.story.opening_body
	_title.hint = voyage.story.opening_hint
	_title.size = vp
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.visible = false
	cl2.add_child(_title)


func _show_overlay(card: Control, on: bool) -> void:
	"""标题卡 / 结算页是"幕间"：铺开的时候把航行界面整层收起来。

	不收起的话半透明的底会把左上角的目标卡、右下角的风玫瑰透出来，
	画面看着像两个界面糊在一起（第一版截图就是这个样子）。
	"""
	card.visible = on
	var play_ui := not on and not (_ending != null and _ending.visible)
	_hud_layer.visible = play_ui
	_panel_layer.visible = play_ui


func _update_hud() -> void:
	if _hud == null:
		return
	_wind_gizmo.set_wind(voyage.wind.from_dir_deg, voyage.wind.tws_ms)
	# 新的一幕落下来了：把剧情卡摆出来。用**真实**秒计时，快进时才不会一闪而过。
	if voyage.story.head != _last_head:
		_last_head = voyage.story.head
		if _last_head >= 0:
			_act_card_timer = _act_card_seconds
	if _show_panel:
		_panel.update_from(voyage.ship, voyage.crew, voyage.nav, voyage.orders)
	if _show_crew_panel:
		_crew_panel.update_from(voyage.roster)
	_hud.time_scale = _time_scales[_time_scale_idx]
	_hud.act_card_timer = _act_card_timer
	_hud.mode_line = ("船舱 L%d %s　高程 %+.0f 米（向上滚回甲板）" % [
		_layer, _ship_view.layer_name(_layer), _ship_view.layer_elevation(_layer)]
		if _mode == Mode.LAYER else "")
	_hud.queue_redraw()


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
	# 截图模式里没有真实时间流逝（一帧就是一步），剧情卡按"一帧 = 0.4 秒"淡出
	if _act_card_timer > 0.0:
		_act_card_timer = maxf(0.0, _act_card_timer - 0.4)
	voyage.tick_ui(0.5)               # 消息条同理：一帧当半秒
	_update_camera()          # 截图模式下 _process 提前返回了，这里要自己同步相机
	_update_hud()
	queue_redraw()
	match _frame:
		1:
			_show_overlay(_title, true)       # 开场：先给陌生人一页交代
		2:
			_capture("19_title_card")
		3:
			_show_overlay(_title, false)
			_started = true
		4:
			_zoom = 0.35                      # 出海前：整片海一览
		8:
			_capture("20_sea_overview")
		12:
			_zoom = 1.0
			voyage.orders.set_target_point(Vector2(3600, 3600))
			_warp(900.0)
		14:
			_capture("20b_act1_card")         # 第一幕落下来的剧情卡
		16:
			_capture("21_under_way")
		17:
			_show_panel = true                # 教学第 2 步：帆态面板
			_panel.visible = true
			voyage.story.note("open_sail_panel")
		19:
			# 面板要等 _update_hud 把 ship/crew 灌进去、再等一帧才会画出来
			# （AGENTS.md 的坑：改完状态隔一帧再截）
			_capture("21a_sail_panel")
		20:
			_show_panel = false
			_panel.visible = false
			_warp(500.0)                      # 继续开，瞭望员会报告陆地
		24:
			_capture("22_island_sighted")
		25:
			_zoom = 4.0                       # 拉近看船：这里画的是真正的 SVG 船
			_warp(5.0)
		26:
			_capture("23_ship_close_up")
		27:
			_zoom = SHIP_ZOOM                 # 一路滚到底：就是船内调试视图那个比例
			_warp(5.0)
		28:
			_capture("24_deck_in_detail")
		29:
			_mode = Mode.LAYER                # 再继续向下：沉进船舱
			_layer = 1
			_warp(5.0)
		30:
			_capture("25_below_deck")
		31:
			_mode = Mode.SEA
			_layer = 2
			_zoom = 1.0
		34:
			# 这条航线正好穿过暗礁 —— 风向突变之后船被压过去，触礁（因果链的中间一环）
			voyage.orders.set_target_point(Vector2(2800, 1200))
			_warp(1300.0)
		38:
			_capture("26_reef_hit")
		42:
			voyage.orders.set_target_point(Vector2(4520, 3600))
			_warp(1700.0)
		46:
			# 截图脚本：把船直接摆到滩头外（航行过程已经在前两格演示过了）
			voyage.ship.set_pose(Vector2(4520, 3600), 0.0)
			voyage.orders.anchored = true
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
			_warp(120.0)
		50:
			_capture("27_anchored_off_beach")
		52:
			_zoom = 24.0                      # 锚泊时拉近：附近地形必须还在
			_warp(5.0)
		54:
			_capture("28_anchored_close_up")
		56:
			_zoom = 1.0
			# 登陆名单：这一版挂在 CanvasLayer 上（屏幕坐标），不再跟着相机跑
			_picker.open(voyage.roster)
			_picker.visible = true
			_picker.toggle_current()
			_picker.move(3)
			_picker.toggle_current()
		58:
			_capture("29_landing_picker")
		60:
			_picker.visible = false
			var ids := ["piloto", "carpintero", "cirujano", "escribano"]
			print("[shot] 登陆：%s" % voyage.land(ids, 6))
			_zoom = 1.0
			_warp(14.0)                       # 一个一个下船，这会儿有人还在船上
		62:
			_capture("30_disembarking_one_by_one")
		64:
			_zoom = 5.0                       # 拉近看队形
			_warp(60.0)                       # 都上岸了，站成队形
		66:
			_capture("31_ashore_in_formation")
		68:
			_zoom = 1.0
			voyage.move_party_to(Vector2(5620, 3320))
			_warp(240.0)
		72:
			_capture("32_ruins")
		76:
			voyage.move_party_to(Vector2(6080, 3820))
			_warp(200.0)
		80:
			_capture("33_stream")
		84:
			voyage.move_party_to(Vector2(4790, 3600))
			_warp(260.0)
			_deliver_reports()
		88:
			_capture("34_back_with_reports")
		90:
			print("[shot] 报告：%s" % str(voyage.pending_reports))
			_zoom = 0.35
			# 第三幕：起锚、满帆、真的把船开回出发港（不是摆回去）
			voyage.orders.anchored = false
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
			voyage.orders.set_target_point(Vector2(700, 4000))
			_warp(900.0)
		92:
			_zoom = 0.35
			_capture("35_homeward")
		94:
			_warp(900.0)
		96:
			_capture("36_homeward_arrival")
		98:
			if not voyage.story.ending_ready:
				print("[shot] 还没进港（离港 %.0f 米），摆到港外把第三幕走完" % \
					voyage.ship.position_m().distance_to(Vector2(700, 4000)))
				voyage.ship.set_pose(Vector2(1150, 4000), 180.0)
				_warp(60.0)
			print("[shot] 第三幕 = %s　结算就绪 = %s" % [
				voyage.story.act_name(), str(voyage.story.ending_ready)])
			_ending.text = voyage.journal.settlement(voyage, voyage.story)
			_show_overlay(_ending, true)
		100:
			_capture("37_settlement")
		110:
			get_tree().quit(0)


func _deliver_reports() -> void:
	if not voyage.ashore:
		return
	var msg := voyage.return_to_ship()
	voyage.say("（船长）" + msg, true)
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
