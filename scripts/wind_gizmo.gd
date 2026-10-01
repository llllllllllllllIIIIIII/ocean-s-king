class_name WindGizmo
extends Control

# 屏幕右下角的"风玫瑰"：蓝箭头指**风吹去的方向**，橙色短线标来向，文字给真风速。
#
# 它画在 CanvasLayer 里（屏幕空间），所以摄像机拉远拉近都不影响它的大小 ——
# "我看不见风往哪儿吹"这个问题不能靠调试打印解决，得让它在画面上一直看得见。

const KNOT := 0.514444

var from_dir_deg := 0.0         # 真风来向（0 = +x，顺时针；和世界坐标一致）
var tws_ms := 8.0               # 真风速 m/s
var font: Font
var accent := Color(0.55, 0.85, 1.0)


func set_wind(p_from_dir: float, p_tws: float) -> void:
	from_dir_deg = p_from_dir
	tws_ms = p_tws
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5 - 26.0
	if r <= 4.0:
		return

	# 底盘与刻度
	draw_circle(c, r, Color(0.04, 0.08, 0.12, 0.72))
	draw_arc(c, r, 0.0, TAU, 64, Color(1, 1, 1, 0.22), 1.5)
	for i in 12:
		var a := TAU * float(i) / 12.0
		var d := Vector2(cos(a), sin(a))
		var long := (i % 3 == 0)
		draw_line(c + d * (r - (12.0 if long else 7.0)), c + d * r,
			Color(1, 1, 1, 0.35), 1.5)

	# 指针：真风来向（从外圈指向圆心）
	var fa := deg_to_rad(from_dir_deg)
	var fd := Vector2(cos(fa), sin(fa))
	draw_line(c + fd * r, c + fd * (r - 16.0), Color(1.0, 0.72, 0.35), 3.0)
	# 箭头：风吹去的方向
	var ta := deg_to_rad(from_dir_deg + 180.0)
	var td := Vector2(cos(ta), sin(ta))
	var tail := c - td * r * 0.62
	var tip := c + td * r * 0.78
	draw_line(tail, tip, accent, 3.0)
	var n := Vector2(-td.y, td.x)
	draw_colored_polygon(PackedVector2Array([
		tip, tip - td * 13.0 + n * 7.5, tip - td * 13.0 - n * 7.5]),
		accent)

	# 文字
	if font:
		var text := "真风 %.1f m/s（%.1f 节）\n来向 %.0f°　吹向 %.0f°" % [
			tws_ms, tws_ms / KNOT, fposmod(from_dir_deg, 360.0),
			fposmod(from_dir_deg + 180.0, 360.0)]
		draw_multiline_string(font, Vector2(0.0, size.y - 4.0), text,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 13, -1,
			Color(0.88, 0.93, 1.0))
