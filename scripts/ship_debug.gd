# 分层调试视图：负责输入、相机、HUD；船的绘制交给 ShipRenderer。
#
# Day 3 起它同时是"风力 → 帆 → 船 → 表现"这条链子的试验台：
#   风场（WindField）→ 船员按手册调帆打舵（Crew）→ 船自己动起来（ShipDynamics）
#   → 渲染器按位置和艏向把船画出来（ShipRenderer.apply_pose）
# 场景本身**不碰**船的位置和速度 —— 铁律（AGENTS.md 第 5 条）说的就是这个。
#
# 相机三态中的 A/B（甲板缩放 / 舱内切层）：
#   * 甲板上滚轮 = 拉远拉近
#   * 拉到最近后继续向下 = 穿过甲板沉入船舱，再向下逐层下探
#   * 向上逐层上浮，到最上层回到缩放模式
#
# 用法：
#   手动：  Godot.exe --path . res://scenes/ship_debug.tscn
#   截图：  Godot.exe --path . res://scenes/ship_debug.tscn -- shots

extends Node2D

const CELL := 40.0
const LAYER_ZOOM_STEP := 1.6
const SHOT_DIR := "res://.shots"
const SIM_DT_MAX := 0.05           # 一帧最多推进多少模拟时间（切窗口回来时防跳）

enum Mode { ZOOM, LAYER }

# --- 世界（Day 3 起）---
var physics: ShipPhysics
var wind: WindField
var ship: ShipDynamics
var crew: Crew

var _mode: Mode = Mode.ZOOM
var _layer := 2                  # 2 = 主甲板
var _zoom := 0.75
var _show_grid := false
var _show_ghost := true
var _paused := false

var _hud: Label
var _wind_gizmo: WindGizmo
var _font: Font
var _layer_order: Array[int] = []
var _frame := 0
var _shot_mode := false

@onready var view: ShipRenderer = $ShipView
@onready var cam: Camera2D = $Camera2D


func _ready() -> void:
	view.setup()
	_layer_order.assign(view.layers.keys())
	_layer_order.sort()
	_layer_order.reverse()                       # [3, 2, 1, 0]，下标越大层越低

	# 风 -> 帆 -> 船 -> 表现：这里把三个模块接起来
	physics = ShipPhysics.load_default()
	wind = WindField.new(8.0, 20.0)              # 真风 8 m/s（15.6 节），来自 20°
	ship = ShipDynamics.new(physics)
	ship.set_pose(Vector2.ZERO, 180.0)           # 船首朝 -x：和 Day 2 的调试画面同向
	crew = Crew.new(ship)
	crew.set_target_heading(180.0)
	ship.step(0.0, wind.velocity_world())        # 只把风灌进去（dt=0，不推进状态）
	crew.retrim()
	_sync_view()

	_build_hud()
	_build_wind_gizmo()
	_apply()
	_shot_mode = OS.get_cmdline_user_args().has("shots")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))


# ------------------------------------------------------- 模拟（风力驱动）

func _process(delta: float) -> void:
	if _shot_mode:
		_run_shot_timeline()
		return
	if _paused:
		return
	var dt: float = minf(delta, SIM_DT_MAX)
	wind.step(dt)
	crew.step(dt)                                 # 船员调帆、打舵
	ship.step(dt, wind.velocity_world())          # 船在风力下自己动
	_sync_view()
	_apply()


func _sync_view() -> void:
	"""把船的状态同步给渲染器 —— 渲染器只读，绝不写回。"""
	view.apply_pose(ship.position_m(), ship.heading_deg())
	var snap := ship.snapshot()
	# 帆弦线：物理里是船体系角度（0 = 船首），画布的 +x 是船尾，所以要 180 - a
	view.sail_main_rad = deg_to_rad(180.0 - float(snap["sail_main_deg"]))
	view.sail_jib_rad = deg_to_rad(180.0 - float(snap["sail_jib_deg"]))
	view.queue_redraw()


# ------------------------------------------------------- 自动截图（我的"眼睛"）
#
# 这一段必须极其可靠。三条硬约束（都是踩过坑才写下的，见 docs/06 第 3 节）：
#   * 时间线放 _process()，不放 _draw()（后者的调用次数不可控）
#   * 改完状态隔一帧再截（get_texture() 拿到的是上一帧）
#   * 截图模式禁用输入（一次误触滚轮就会污染整组图）

func _run_shot_timeline() -> void:
	_frame += 1
	match _frame:
		4:
			_set_state(2, Mode.ZOOM, 1.30)
		8:
			_capture("01_deck_wide")
		12:
			_set_state(2, Mode.ZOOM, 4.00)
		16:
			_capture("02_deck_close")
		20:
			_sail_shot(335.0, 60.0, 2.00)      # 真风角 45 度：抢风行驶
		24:
			_capture("03_rig_close_hauled")
		28:
			_sail_shot(200.0, 60.0, 2.00)      # 真风角 180 度：顺风放到底
		32:
			_capture("04_rig_downed_on_a_run")
		36:
			_set_state(1, Mode.LAYER, 1.80)
		40:
			_capture("05_belowdeck")
		44:
			_set_state(0, Mode.LAYER, 1.80)
		48:
			_capture("06_hold")
		52:
			_set_state(3, Mode.LAYER, 1.80)
		56:
			_capture("07_crow_nest")
		60:
			_sail_shot(290.0, 60.0, 0.95)      # 真风角 90 度：横风最快，船是斜的
		64:
			_capture("08_sailing_beam_reach")
		70:
			print("[shots] " + view.bank.stats())
			get_tree().quit(0)


# 注意：不能叫 _set()，那是 Object 的内置虚函数，签名是 _set(StringName, Variant)，
# 同名不同签名会导致解析失败。
func _set_state(layer: int, mode: Mode, zoom: float) -> void:
	_layer = layer
	_mode = mode
	_zoom = zoom
	_apply()


func _sail_shot(heading: float, seconds: float, zoom: float) -> void:
	# 截图用的一次性"模拟快进"：让船真的在风里跑一会儿，再照一张。
	# 用的就是游戏里同一套链路（船员 → 帆 → 船），所以照片里的帆角、横倾、
	# 航速都是真的算出来的，不是摆拍。
	ship.set_pose(Vector2.ZERO, heading)
	crew.set_target_heading(heading)
	_mode = Mode.ZOOM
	_layer = 2
	_zoom = zoom
	var dt := 0.05
	for _i in int(seconds / dt):
		crew.step(dt)
		ship.step(dt, wind.velocity_world())
	_sync_view()
	_apply()


func _apply() -> void:
	view.layer = _layer
	view.zoom = _zoom
	view.show_grid = _show_grid
	view.show_ghost = _show_ghost
	view.queue_redraw()

	cam.position = view.hull_center_world_px()
	cam.zoom = Vector2(_zoom, _zoom)
	_update_hud()


func _capture(name: String) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[shot] 拿不到 viewport 纹理（headless 下必然如此）")
		return
	var img := tex.get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	var err := img.save_png(path)
	print("[shot] %-24s err=%d  zoom=%.2f  L%d  %s" % [
		name, err, cam.zoom.x, _layer, ProjectSettings.globalize_path(path)])


# ------------------------------------------------------------------ 输入

func _unhandled_input(event: InputEvent) -> void:
	if _shot_mode:
		return                                   # 截图模式禁用输入，保证可复现
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_wheel(-1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_wheel(1)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_steer_toward_mouse(mb.position)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.keycode:
			KEY_LEFT, KEY_A:
				crew.set_target_heading(crew.target_heading_deg - 10.0)
			KEY_RIGHT, KEY_D:
				crew.set_target_heading(crew.target_heading_deg + 10.0)
			KEY_SPACE:
				crew.set_target_heading(ship.heading_deg())
			KEY_P:
				_paused = not _paused
			KEY_G:
				_show_grid = not _show_grid
			KEY_H:
				_show_ghost = not _show_ghost


func _steer_toward_mouse(screen_pos: Vector2) -> void:
	"""点哪儿就往哪儿走 —— Day 4 的"选目标点"在这条链子上的雏形。"""
	var world_px := get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var d := world_px - view.hull_center_world_px()
	if d.length() < 4.0:
		return
	crew.set_target_heading(rad_to_deg(atan2(d.y, d.x)))


func _wheel(dir: int) -> void:
	if _mode == Mode.LAYER:
		# _layer_order = [3, 2, 1, 0]，下标越大层越低：向下 = +dir，向上 = -dir
		var idx := _layer_order.find(_layer) + dir
		if idx < 0:                              # 在最上层继续向上 -> 回到缩放
			_mode = Mode.ZOOM
			_zoom = LAYER_ZOOM_STEP
			_layer = 2                           # 缩放模式永远看主甲板
		else:
			_layer = _layer_order[clampi(idx, 0, _layer_order.size() - 1)]
	else:
		if dir > 0 and _zoom >= LAYER_ZOOM_STEP and _layer == 2:
			_mode = Mode.LAYER                   # 拉到最近后再向下 -> 沉入船舱
			_layer = _layer_order[_layer_order.find(_layer) + 1]
		else:
			# 滚轮当成一根垂直轴：向上 = 拉远看全船，向下 = 拉近看细节。
			# 注意 Godot 的 Camera2D.zoom 是越大越放大。
			_zoom = clampf(_zoom * (1.18 if dir > 0 else 0.85), 0.25, 6.0)
	_apply()


# ------------------------------------------------------------------ HUD

func _build_hud() -> void:
	_font = _pick_font()
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


func _update_hud() -> void:
	if _hud == null:
		return
	if _wind_gizmo:
		_wind_gizmo.set_wind(wind.from_dir_deg, wind.tws_ms)
	var mode := "缩放" if _mode == Mode.ZOOM else "分层"
	var hint := "拉远/拉近（拉到最近继续向下可沉入船舱）" if _mode == Mode.ZOOM \
		else "向上逐层上浮，到最上层回到缩放"
	var snap := ship.snapshot()
	var flag := "   ⏸ 暂停" if _paused else ""
	_hud.text = ("L%d  %s   高程 %+.0f m   [%s]   x%.2f%s\n"
		+ "滚轮：%s\n"
		+ "←/→ 或 A/D 改目标航向　空格 稳住当前航向　左键点方向就走　P 暂停　G 网格　H 虚影\n"
		+ "%s\n"
		+ "真风 %.1f m/s（%.1f 节）来自 %.0f°，吹向 %.0f°　%s\n"
		+ "航向 %.0f°  船速 %.2f 节（%.1f m/s）  横倾 %+.1f°  侧滑 %+.1f°\n"
		+ "真风角 %.0f°  视风角 %.0f°  舵 %+.0f°  主帆攻角 %.0f°  位置 (%.0f, %.0f) m") % [
		_layer, view.layer_name(_layer), view.layer_elevation(_layer), mode, _zoom, flag,
		hint,
		crew.describe(),
		wind.tws_ms, wind.tws_ms / 0.514444, fposmod(wind.from_dir_deg, 360.0),
		fposmod(wind.from_dir_deg + 180.0, 360.0),
		"（右上角风玫瑰：箭头 = 风吹去的方向）",
		float(snap["heading_deg"]), float(snap["u_kn"]), float(snap["u_ms"]),
		float(snap["heel_deg"]), ship.leeway_deg(),
		ship.twa_deg(), ship.awa_deg(), float(snap["rudder_deg"]),
		ship.sail_alpha_main_deg(), ship.position_m().x, ship.position_m().y]


func _build_wind_gizmo() -> void:
	"""右上角的风玫瑰：让"风往哪儿吹"在画面上一直看得见（与摄像机缩放无关）。"""
	var cl := CanvasLayer.new()
	add_child(cl)
	_wind_gizmo = WindGizmo.new()
	_wind_gizmo.font = _font
	var side := 200.0
	_wind_gizmo.size = Vector2(side, side)
	_wind_gizmo.position = get_viewport_rect().size - Vector2(side + 18.0, side + 18.0)
	cl.add_child(_wind_gizmo)
	_wind_gizmo.set_wind(wind.from_dir_deg, wind.tws_ms)


func _pick_font() -> Font:
	# Godot 默认字体没有中文字形，先找系统中文字体
	for p in ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]:
		if not FileAccess.file_exists(p):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(p) == OK:
			return f
	push_warning("没找到中文字体，标签可能显示为方块")
	return ThemeDB.fallback_font
