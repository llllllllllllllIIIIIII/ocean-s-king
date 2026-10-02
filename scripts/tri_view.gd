class_name TriView
extends Control

# 三视图（M18 / docx 第十三节）：**俯视 / 侧视 / 艉视**三个正交观察窗。
#
# 它不是装饰：**七处损伤每一处都要在图上看得见** ——
#   船壳（俯视的破口 + 侧视的水线）· 桅杆（侧视的桅高）· 风帆（侧视的破帆）·
#   舵（艉视的舵叶）· 货舱（俯视的舱口）· 弹药区（俯视的红框）· 起火/进水（火苗 / 水线）。
#
# `damage_marks()` 把"图上画了什么"原样交出来 —— 无头测试照它逐处断言，
# 不用去读像素。所以这一层既是画面，也是**可验证的模型**。

const BG := Color(0.07, 0.09, 0.12, 0.92)
const FRAME := Color(0.35, 0.42, 0.5, 0.8)
const LABEL := Color(0.75, 0.8, 0.86)
const HULL := Color(0.62, 0.47, 0.31)
const HULL_DARK := Color(0.42, 0.31, 0.2)
const SAIL := Color(0.86, 0.84, 0.76)
const FINE := Color(0.35, 0.72, 0.42)
const WARN := Color(0.9, 0.72, 0.25)
const BAD := Color(0.85, 0.28, 0.22)
const WATER := Color(0.25, 0.5, 0.75)
const FIRE := Color(0.95, 0.5, 0.15)

const PARTS := ["hull", "mast", "rudder", "sail", "hold", "magazine"]
const PART_NAMES := {
	"hull": "船壳", "mast": "桅杆", "rudder": "舵", "sail": "风帆",
	"hold": "货舱", "magazine": "弹药区", "fire": "起火", "flood": "进水",
}

var voyage: Voyage
var font: Font


func configure(v: Voyage) -> void:
	voyage = v
	# 中文字形：Godot 默认字体没有汉字（老坑），照 `sea_debug` 的办法从系统字体里取
	for p in ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]:
		if not FileAccess.file_exists(p):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(p) == OK:
			font = f
			break
	if font == null:
		font = ThemeDB.fallback_font
	queue_redraw()


func _sev(v: float) -> Color:
	if v <= 0.02:
		return FINE
	return WARN if v < 0.5 else BAD


func damage_marks() -> Array:
	"""图上真的画了什么（每处损伤一条）—— 测试照它断言，不看像素。

	返回 [{part, label, value, views: [...]}]，七处（六处损伤 + 起火/进水两种状态）。
	"""
	var out := []
	if voyage == null or voyage.ship == null:
		return out
	for p in PARTS:
		var v := voyage.ship.damage_of(p)
		out.append({
			"part": p, "label": str(PART_NAMES.get(p, p)), "value": v,
			"views": _views_of(p), "drawn": v > 0.0,
		})
	for h in ["fire", "flood"]:
		var hv := voyage.ship.hazard_of(h)
		out.append({
			"part": h, "label": str(PART_NAMES.get(h, h)), "value": hv,
			"views": ["side"] if h == "fire" else ["stern", "side"], "drawn": hv > 0.0,
		})
	return out


func _views_of(part: String) -> Array:
	match part:
		"hull":
			return ["top", "side", "stern"]
		"mast", "sail":
			return ["side"]
		"rudder":
			return ["stern"]
		"hold", "magazine":
			return ["top"]
	return []


func _draw() -> void:
	if voyage == null or voyage.ship == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var pad := 10.0
	var w := (size.x - pad * 4.0) / 3.0
	var h := size.y - pad * 2.0 - 18.0
	var boxes := [
		["top", Rect2(pad, pad + 16.0, w, h)],
		["side", Rect2(pad * 2.0 + w, pad + 16.0, w, h)],
		["stern", Rect2(pad * 3.0 + w * 2.0, pad + 16.0, w, h)],
	]
	for b in boxes:
		var id := str(b[0])
		var r: Rect2 = b[1]
		draw_rect(r, Color(0.10, 0.13, 0.17, 0.9))
		draw_rect(r, FRAME, false, 1.0)
		_text(r.position + Vector2(6, 12), _view_name(id), LABEL, 12)
	_draw_top(boxes[0][1])
	_draw_side(boxes[1][1])
	_draw_stern(boxes[2][1])
	_text(Vector2(10, size.y - 4), "七处损伤：%s" % _marks_line(), LABEL, 11)


func _view_name(id: String) -> String:
	match id:
		"top":
			return "俯视（甲板 / 弹药区 / 货舱）"
		"side":
			return "侧视（桅杆 / 帆 / 起火）"
	return "艉视（舵 / 进水）"


func _marks_line() -> String:
	var bits := PackedStringArray()
	for m in damage_marks():
		if float(m["value"]) > 0.01:
			bits.append("%s %.0f%%" % [str(m["label"]), float(m["value"]) * 100.0])
	return "无损伤" if bits.is_empty() else "　".join(bits)


func _draw_top(r: Rect2) -> void:
	var hull := voyage.ship.damage_of("hull")
	var mag := voyage.ship.damage_of("magazine")
	var hold := voyage.ship.damage_of("hold")
	var fire := voyage.ship.hazard_of("fire")
	# 船体（俯视：细长的椭圆）
	var c := r.position + r.size * 0.5
	var l := r.size.x * 0.72
	var b := r.size.y * 0.22
	var col := HULL.lerp(BAD, clampf(hull, 0.0, 1.0))
	_ellipse(c, Vector2(l * 0.5, b * 0.5), col)
	_ellipse(c, Vector2(l * 0.5, b * 0.5), HULL_DARK, false, 1.0)
	# 桅杆（俯视就是几个点）
	for i in 3:
		var x := c.x - l * 0.25 + float(i) * l * 0.25
		draw_circle(Vector2(x, c.y), 2.6, FINE.lerp(BAD, voyage.ship.damage_of("mast")))
	# 货舱（舱口）与弹药区（红框）
	var hatch := Rect2(Vector2(c.x - l * 0.22, c.y - b * 0.18), Vector2(l * 0.44, b * 0.36))
	draw_rect(hatch, Color(0.25, 0.2, 0.15).lerp(BAD, hold), true)
	draw_rect(hatch, FRAME, false, 1.0)
	var mag_box := Rect2(Vector2(c.x + l * 0.24, c.y - b * 0.22), Vector2(l * 0.16, b * 0.44))
	draw_rect(mag_box, FINE.lerp(BAD, mag), true)
	draw_rect(mag_box, FRAME, false, 1.0)
	if hull > 0.05:
		# 破口：舷侧几个红点
		for i in 4:
			var a := TAU * float(i) / 4.0 + 0.4
			var p := c + Vector2(cos(a) * l * 0.5, sin(a) * b * 0.5)
			draw_circle(p, 3.0, BAD)
	if fire > 0.01:
		_flame(Vector2(c.x, c.y - b * 0.5), fire)


func _draw_side(r: Rect2) -> void:
	var hull := voyage.ship.damage_of("hull")
	var mast := voyage.ship.damage_of("mast")
	var sail := voyage.ship.damage_of("sail")
	var fire := voyage.ship.hazard_of("fire")
	var flood := voyage.ship.hazard_of("flood")
	var base := r.position + Vector2(r.size.x * 0.12, r.size.y * 0.72)
	var l := r.size.x * 0.76
	var h := r.size.y * 0.16
	# 船体侧影
	var pts := PackedVector2Array([
		base, base + Vector2(l, 0.0), base + Vector2(l * 0.94, h * 0.7),
		base + Vector2(l * 0.1, h), base + Vector2(0.0, h * 0.6),
	])
	draw_colored_polygon(pts, HULL.lerp(BAD, clampf(hull, 0.0, 1.0)))
	draw_polyline(pts, HULL_DARK, 1.0)
	# 桅杆（损伤 → 变矮）
	var mast_h := r.size.y * 0.42 * (1.0 - 0.5 * mast)
	var mast_x := base.x + l * 0.45
	draw_line(Vector2(mast_x, base.y), Vector2(mast_x, base.y - mast_h),
		FINE.lerp(BAD, mast), 3.0)
	# 帆（损伤 → 破口）
	var sail_top := base.y - mast_h
	var spts := PackedVector2Array([
		Vector2(mast_x, sail_top), Vector2(mast_x + r.size.x * 0.22, sail_top + r.size.y * 0.06),
		Vector2(mast_x + r.size.x * 0.2, base.y - h * 0.4), Vector2(mast_x, base.y - h * 0.4),
	])
	draw_colored_polygon(spts, SAIL.lerp(BAD, clampf(sail, 0.0, 1.0)))
	if sail > 0.05:
		draw_line(Vector2(mast_x + r.size.x * 0.05, sail_top + r.size.y * 0.02),
			Vector2(mast_x + r.size.x * 0.12, base.y - h * 0.5), BAD, 1.5)
	if fire > 0.01:
		_flame(Vector2(mast_x - r.size.x * 0.06, base.y - h * 0.4), fire)
	if flood > 0.01:
		var wl := base.y - h * 0.2 - h * 0.5 * flood
		draw_line(Vector2(base.x - 4.0, wl), Vector2(base.x + l + 4.0, wl), WATER, 2.0)


func _draw_stern(r: Rect2) -> void:
	var hull := voyage.ship.damage_of("hull")
	var rudder := voyage.ship.damage_of("rudder")
	var flood := voyage.ship.hazard_of("flood")
	var c := r.position + r.size * 0.5
	var w := r.size.x * 0.42
	var h := r.size.y * 0.5
	# 艉板
	var pts := PackedVector2Array([
		Vector2(c.x - w * 0.5, c.y - h * 0.5), Vector2(c.x + w * 0.5, c.y - h * 0.5),
		Vector2(c.x + w * 0.34, c.y + h * 0.5), Vector2(c.x - w * 0.34, c.y + h * 0.5),
	])
	draw_colored_polygon(pts, HULL.lerp(BAD, clampf(hull, 0.0, 1.0)))
	draw_polyline(pts, HULL_DARK, 1.0)
	# 舵叶（损伤 → 偏转）
	var tilt := rudder * 0.6
	var rp := PackedVector2Array([
		Vector2(c.x - 4.0, c.y + h * 0.5), Vector2(c.x + 4.0, c.y + h * 0.5),
		Vector2(c.x + 4.0 + tilt * 18.0, c.y + h * 0.5 + h * 0.42),
		Vector2(c.x - 4.0 + tilt * 18.0, c.y + h * 0.5 + h * 0.42),
	])
	draw_colored_polygon(rp, FINE.lerp(BAD, rudder))
	draw_polyline(rp, FRAME, 1.0)
	if flood > 0.01:
		var wl := c.y + h * 0.5 - h * 0.8 * flood
		draw_line(Vector2(c.x - w, wl), Vector2(c.x + w, wl), WATER, 2.0)
	if hull > 0.05:
		for i in 3:
			var y := c.y - h * 0.2 + float(i) * h * 0.25
			draw_line(Vector2(c.x - w * 0.4, y), Vector2(c.x + w * 0.4, y * 1.0 + 3.0), BAD, 1.0)


func _flame(at: Vector2, strength: float) -> void:
	var s := clampf(strength, 0.1, 1.0)
	for i in 3:
		var p := at + Vector2(float(i - 1) * 6.0, -float(i % 2) * 4.0)
		var pts := PackedVector2Array([
			p + Vector2(-4.0, 4.0), p + Vector2(0.0, -8.0 * s - 4.0), p + Vector2(4.0, 4.0),
		])
		draw_colored_polygon(pts, FIRE)


# ⚠️ 不能叫 `draw_ellipse` —— `CanvasItem` 在新版本里已经有同名方法（签名不同），
#    重名会直接编译失败（AGENTS.md 记过 `_set`/`_get` 那类坑）。
func _ellipse(center: Vector2, radii: Vector2, color: Color, filled := true,
		width := 1.0) -> void:
	var pts := PackedVector2Array()
	for i in 48:
		var a := TAU * float(i) / 48.0
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	if filled:
		draw_colored_polygon(pts, color)
	else:
		pts.append(pts[0])
		draw_polyline(pts, color, width)


func _text(at: Vector2, s: String, col: Color, px: int) -> void:
	if font == null:
		return
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px, col)
