# Day 1 调试视图：把 data/ships/caravel_60.json 按层画出来。
#
# 它要证明三件事：
#   1. 船确实"是数据"——画面完全由 JSON 决定，代码里没有任何船的硬编码形状
#   2. 分层观察成立——滚轮能从甲板一路沉到货舱
#   3. 我可以自己看到结果——带 --shots 参数时会自动截一组图然后退出
#
# 用法：
#   手动看：  Godot.exe --path . res://scenes/ship_debug.tscn
#   自动截图：Godot.exe --path . res://scenes/ship_debug.tscn -- shots
extends Node2D

const SHIP_PATH := "res://data/ships/caravel_60.json"
const TILES_PATH := "res://data/defs/tiles.json"
const PROPS_PATH := "res://data/defs/props.json"

const CELL := 40.0              # 未缩放时每格多少像素
const LAYER_ZOOM_STEP := 1.6    # 拉近到多少倍进入分层视图

enum Mode { ZOOM, LAYER }

var _ship: Dictionary
var _tiles: Dictionary
var _props: Dictionary
var _layers: Dictionary = {}          # layer_id -> layer dict
var _layer_order: Array[int] = []     # 从高到低

var _mode: Mode = Mode.ZOOM
var _layer: int = 2
var _zoom: float = 0.55

var _font: Font
var _hud: Label
var _frame := 0
var _shot_mode := false


func _ready() -> void:
	_font = _pick_font()
	_ship = _load_json(SHIP_PATH)
	_tiles = _load_json(TILES_PATH)["tiles"]
	_props = _load_json(PROPS_PATH)["props"]

	for layer in _ship["layers"]:
		# JSON 里的数字会解析成 float，字典键必须显式转 int，
		# 否则 _layers[2] 找不到键 2.0（Godot 的字典不会把 int 2 和 float 2.0 视为同一个键）。
		_layers[int(layer["id"])] = layer
	_layer_order.assign(_layers.keys())      # assign() 才能把 Array 装进 Array[int]
	_layer_order.sort()
	_layer_order.reverse()            # 3, 2, 1, 0

	_build_hud()
	_apply_camera()
	_shot_mode = OS.get_cmdline_user_args().has("shots")
	queue_redraw()


# ------------------------------------------------------- 自动截图（我的"眼睛"）
#
# 这一段必须极其可靠——它是我唯一能"看见"画面的手段。所以：
#   * 时间线放在 _process()（每帧一次，节奏可预测），不放在 _draw()（调用次数不可控）
#   * 截图模式下一律禁用输入，避免误触滚轮污染状态
#   * 改完状态隔一帧再截，否则拿到的是上一帧的画面

func _process(_delta: float) -> void:
	if not _shot_mode:
		return
	_frame += 1
	match _frame:
		5:
			_set_state(2, Mode.ZOOM, 1.75)
		8:
			_capture("01_deck_wide")
		12:
			_set_state(2, Mode.ZOOM, 3.2)
		15:
			_capture("02_deck_close")
		19:
			_set_state(1, Mode.LAYER, 2.4)
		22:
			_capture("03_belowdeck")
		26:
			_set_state(0, Mode.LAYER, 2.4)
		29:
			_capture("04_hold")
		33:
			_set_state(3, Mode.LAYER, 2.4)
		36:
			_capture("05_crow_nest")
		42:
			print("[shots] done")
			get_tree().quit(0)


func _set_state(layer: int, mode: Mode, zoom: float) -> void:
	_layer = layer
	_mode = mode
	_zoom = zoom
	_apply_camera()
	_update_hud()
	queue_redraw()


func _capture(name: String) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[shot] 拿不到 viewport 纹理（headless 下必然如此）")
		return
	var cam := $Camera2D as Camera2D
	var img := tex.get_image()
	var path := "res://tests/_shot_%s.png" % name
	var err := img.save_png(path)
	print("[shot] %-16s err=%d  相机zoom=%.2f  %s" % [
		name, err, cam.zoom.x, ProjectSettings.globalize_path(path)])


# ------------------------------------------------------------------ 输入

func _unhandled_input(event: InputEvent) -> void:
	if _shot_mode:
		return                      # 截图模式禁用输入，保证结果可复现
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		_wheel(-1)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_wheel(1)


func _wheel(dir: int) -> void:
	if _mode == Mode.LAYER:
		# _layer_order = [3, 2, 1, 0]，下标越大层越低。
		# 所以"向下 = 下沉"是 +dir，"向上 = 上浮"是 -dir。
		var idx := _layer_order.find(_layer) + dir
		if idx < 0:                                     # 在最上层继续向上 -> 回到缩放
			_mode = Mode.ZOOM
			_zoom = LAYER_ZOOM_STEP
			_layer = 2                                  # 缩放模式永远看主甲板
		else:
			_layer = _layer_order[clampi(idx, 0, _layer_order.size() - 1)]
	else:
		if dir > 0 and _zoom >= LAYER_ZOOM_STEP and _layer == 2:
			# 已经拉到最近，再往下滚 -> 穿过甲板沉入船舱
			_mode = Mode.LAYER
			_layer = _layer_order[_layer_order.find(_layer) + 1]
		else:
			# 滚轮把"垂直"当成一根轴：向上 = 拉远看全船，向下 = 拉近看细节。
			# 注意 Godot 的 Camera2D.zoom 越大 = 放大越多，别写反。
			_zoom = clampf(_zoom * (1.18 if dir > 0 else 0.85), 0.25, 4.0)
	_apply_camera()
	_update_hud()
	queue_redraw()


func _apply_camera() -> void:
	var cam := $Camera2D as Camera2D
	var cx := float(_ship["hull"]["cells_x"]) * CELL * 0.5
	var cy := float(_ship["hull"]["cells_y"]) * CELL * 0.5
	cam.position = Vector2(cx, cy)
	cam.zoom = Vector2(_zoom, _zoom)


# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	var grid: Array = _layers[_layer]["tiles"]
	var nx: int = _ship["hull"]["cells_x"]
	var ny: int = _ship["hull"]["cells_y"]

	# 1) 格子
	for y in ny:
		var row: String = grid[y]
		for x in nx:
			var ch := row[x]
			var def: Dictionary = _tiles.get(ch, {"color": "#ff00ff"})
			var c := Color(def["color"])
			var r := Rect2(x * CELL, y * CELL, CELL, CELL)
			draw_rect(r, c, true)
			draw_rect(r, Color(0, 0, 0, 0.25), false, 1.0)

	# 2) 房间（格子上的一层语义标注）
	for room in _ship["rooms"]:
		if int(room["layer"]) != _layer:
			continue
		var cells: Array = room["cells"]
		var minp := Vector2(1e9, 1e9)
		var maxp := Vector2(-1e9, -1e9)
		for cell in cells:
			var p := Vector2(float(cell[0]) * CELL, float(cell[1]) * CELL)
			minp = minp.min(p)
			maxp = maxp.max(p + Vector2(CELL, CELL))
		draw_rect(Rect2(minp, maxp - minp), Color(0.2, 0.7, 1.0, 0.16), true)
		draw_rect(Rect2(minp, maxp - minp), Color(0.4, 0.85, 1.0, 0.7), false, 2.0)
		_draw_label(str(room["name"]), minp + Vector2(6, 18), 14, Color(0.8, 0.95, 1.0))

	# 3) 物件
	for prop in _ship["props"]:
		if int(prop["layer"]) != _layer:
			continue
		var def: Dictionary = _props.get(prop["type"], {})
		var c := Color(def.get("color", "#ffffff"))
		var center := Vector2((float(prop["x"]) + 0.5) * CELL,
							  (float(prop["y"]) + 0.5) * CELL)
		if def.get("shape", "rect") == "circle":
			draw_circle(center, CELL * 0.34, c)
			draw_arc(center, CELL * 0.34, 0, TAU, 20, Color(0, 0, 0, 0.5), 2.0)
		else:
			var r := Rect2(center - Vector2(CELL * 0.32, CELL * 0.32),
						   Vector2(CELL * 0.64, CELL * 0.64))
			draw_rect(r, c, true)
			draw_rect(r, Color(0, 0, 0, 0.5), false, 2.0)
		_draw_label(str(def.get("name", prop["type"])), center + Vector2(-14, -CELL * 0.4),
					12, Color(1, 1, 1, 0.9))

	# 4) 层间通道（画在当前层上的标记）
	for link in _ship["links"]:
		if int(link["from"]) == _layer or int(link["to"]) == _layer:
			var center := Vector2((float(link["x"]) + 0.5) * CELL,
								  (float(link["y"]) + 0.5) * CELL)
			draw_arc(center, CELL * 0.42, 0, TAU, 24, Color(0.3, 0.95, 1.0), 2.5)

func _draw_label(text: String, pos: Vector2, size: int, color: Color) -> void:
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


# ------------------------------------------------------------------ HUD

func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud.add_theme_constant_override("outline_size", 6)
	cl.add_child(_hud)
	_update_hud()


func _update_hud() -> void:
	var layer: Dictionary = _layers[_layer]
	var mode := "缩放" if _mode == Mode.ZOOM else "分层"
	_hud.text = "L%d  %s   高程 %+.0f m   [%s]   x%.2f\n滚轮：%s" % [
		layer["id"], layer["name"], layer["elevation_m"], mode, _zoom,
		"切层（向上回到甲板）" if _mode == Mode.LAYER else "缩放（拉近后继续向下可沉入船舱）"]


# ------------------------------------------------------------------ 工具

func _load_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _pick_font() -> Font:
	# 默认字体不带中文字形，先找一个系统中文字体；找不到就退回默认字体
	# （那样中文会显示成方块，但调试视图仍然可用）。
	for p in ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]:
		if not FileAccess.file_exists(p):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(p) == OK:
			return f
	push_warning("没找到中文字体，标签可能显示为方块")
	return ThemeDB.fallback_font
