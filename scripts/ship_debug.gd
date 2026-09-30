# 分层调试视图：负责输入、相机、HUD；船的绘制交给 ShipRenderer。
#
# 相机三态中的 A/B（甲板缩放 / 舱内切层）在这里已经成立：
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

enum Mode { ZOOM, LAYER }

var _mode: Mode = Mode.ZOOM
var _layer := 2                  # 2 = 主甲板
var _zoom := 0.75
var _sail := -0.26
var _show_grid := false
var _show_ghost := true

var _hud: Label
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

	_build_hud()
	_apply()
	_shot_mode = OS.get_cmdline_user_args().has("shots")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))


# ------------------------------------------------------- 自动截图（我的"眼睛"）
#
# 这一段必须极其可靠。三条硬约束（都是踩过坑才写下的，见 docs/06 第 3 节）：
#   * 时间线放 _process()，不放 _draw()（后者的调用次数不可控）
#   * 改完状态隔一帧再截（get_texture() 拿到的是上一帧）
#   * 截图模式禁用输入（一次误触滚轮就会污染整组图）

func _process(_delta: float) -> void:
	if not _shot_mode:
		return
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
			_set_state(2, Mode.ZOOM, 2.20, -1.15)
		24:
			_capture("03_rig_to_port")
		28:
			_set_state(2, Mode.ZOOM, 2.20, 0.95)
		32:
			_capture("04_rig_to_starboard")
		36:
			_set_state(1, Mode.LAYER, 1.80, -0.26)
		40:
			_capture("05_belowdeck")
		44:
			_set_state(0, Mode.LAYER, 1.80, -0.26)
		48:
			_capture("06_hold")
		52:
			_set_state(3, Mode.LAYER, 1.80, -0.26)
		56:
			_capture("07_crow_nest")
		62:
			print("[shots] " + view.bank.stats())
			get_tree().quit(0)


# 注意：不能叫 _set()，那是 Object 的内置虚函数，签名是 _set(StringName, Variant)，
# 同名不同签名会导致解析失败。
func _set_state(layer: int, mode: Mode, zoom: float, sail := 1e9) -> void:
	_layer = layer
	_mode = mode
	_zoom = zoom
	if sail < 1e8:
		_sail = sail
	_apply()


func _apply() -> void:
	view.layer = _layer
	view.zoom = _zoom
	view.sail_angle = _sail
	view.show_grid = _show_grid
	view.show_ghost = _show_ghost
	view.queue_redraw()

	var cx := float(view.ship["hull"]["cells_x"]) * CELL * 0.5
	var cy := float(view.ship["hull"]["cells_y"]) * CELL * 0.5
	cam.position = Vector2(cx, cy)
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
	print("[shot] %-18s err=%d  zoom=%.2f  L%d  %s" % [
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
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.keycode:
			KEY_Q:
				_sail = clampf(_sail - 0.08, -1.35, 1.35)
				_apply()
			KEY_E:
				_sail = clampf(_sail + 0.08, -1.35, 1.35)
				_apply()
			KEY_G:
				_show_grid = not _show_grid
				_apply()
			KEY_H:
				_show_ghost = not _show_ghost
				_apply()


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
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud.add_theme_constant_override("outline_size", 6)
	cl.add_child(_hud)


func _update_hud() -> void:
	if _hud == null:
		return
	var mode := "缩放" if _mode == Mode.ZOOM else "分层"
	var hint := "拉远/拉近（拉到最近继续向下可沉入船舱）" if _mode == Mode.ZOOM \
		else "向上逐层上浮，到最上层回到缩放"
	_hud.text = "L%d  %s   高程 %+.0f m   [%s]   x%.2f\n滚轮：%s\nQ/E 调帆　G 网格　H 上层虚影　帆角 %+.0f°" % [
		_layer, view.layer_name(_layer), view.layer_elevation(_layer),
		mode, _zoom, hint, rad_to_deg(_sail)]


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
