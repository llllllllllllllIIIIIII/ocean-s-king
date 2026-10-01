class_name ChartView
extends Node2D

# 大西洋海图（M2）：**同一台相机**拉到最远时，地形"化"成海图上的符号。
#
# 三条设计：
#
#   1. **不是另一个场景、不是另一个相机。** 它画在同一个世界坐标里（世界米 × PPM），
#      和地形、和船共用一套变换，所以永远对得上 —— 这就是 docs/13 M2 卡片里
#      那句"地形与海图符号交叉淡入"的字面实现。
#   2. **符号与地形同源**：海图上的海岸线就是 Geom2D 画的那些形状，不是另画一张图。
#      （手绘的第二份海岸线迟早会和可航行的那份对不上，和铁律 4 是同一个坑。）
#   3. **雾按 16km 分块铺**：`voyage.discovered` 里没有的 tile 一律盖住。
#      因为瞭望视野是 8km = 半个 tile，所以雾是在**开过界之前**就散掉的，
#      不会出现"越过分块线地形才冒出来"。

const PARCHMENT := Color(0.855, 0.815, 0.675)
const PARCHMENT_DARK := Color(0.62, 0.555, 0.4)
const INK := Color(0.29, 0.235, 0.16)
const INK_SOFT := Color(0.36, 0.31, 0.23, 0.55)
const FOG := Color(0.10, 0.13, 0.18)
const CHART_SEA := Color(0.145, 0.235, 0.30)

var world: WorldMap
var voyage: Voyage
var font: Font
var px_per_m := 0.5           # 世界米 -> 像素（与 sea_debug 的 PPM 一致；不能叫 scale，Node2D 已经占了）
var zoom := 1.0               # 相机缩放：文字要按它反向补偿，屏幕上字号才恒定
var fade := 0.0               # 0 = 全是地形，1 = 全是海图符号
var _s := 1.0                 # 1 / zoom：把"屏幕上的 1 像素"换算成世界像素


func _draw() -> void:
	if world == null or voyage == null or fade <= 0.01:
		return
	var a := fade
	_s = 1.0 / maxf(zoom, 0.0005)
	var size_px := world.world_m * px_per_m
	# ① 海面：海图的底色比"真水面"浅，像一张摊开在桌上看过很多年的纸
	draw_rect(Rect2(Vector2.ZERO, size_px), Color(CHART_SEA, 0.94 * a), true)
	# ② 洋流：细细的流向线（真海图上是这样的）
	for f in world.of_kind("current"):
		var shape: Dictionary = f["shape"]
		var pts: PackedVector2Array = shape["points"]
		for i in range(pts.size() - 1):
			draw_line(pts[i] * px_per_m, pts[i + 1] * px_per_m,
				Color(0.55, 0.78, 0.9, 0.45 * a), 3.0 * _s, true)
		_flow_arrows(pts, a)
	# ③ 陆地：羊皮纸色 + 墨线，是这张图的主体
	for f in world.lands():
		Geom2D.draw_shape(self, f["shape"], Color(PARCHMENT, a), px_per_m)
		Geom2D.draw_shape_outline(self, f["shape"], Color(INK, 0.9 * a), 2.0 * _s, px_per_m)
		# 内陆的"山"：靠里再描一圈淡淡的线，像手绘的等高线
		var inner := _shrunk(f["shape"], 0.55)
		Geom2D.draw_shape_outline(self, inner, Color(PARCHMENT_DARK, 0.55 * a), 1.2 * _s, px_per_m)
	# ④ 暗礁：海图上用一排小十字标出来
	for f in world.of_kind("reef"):
		_crosses(Geom2D.centroid(f["shape"]), Geom2D.extent(f["shape"]), a)
	# ⑤ 航段：走过的航段才画（没走过的海没有线）
	for r in voyage.sea.routes():
		if not _route_known(r):
			continue
		var pts := voyage.sea.route_points(r)
		for i in range(pts.size() - 1):
			_dashes(pts[i] * px_per_m, pts[i + 1] * px_per_m, Color(0.35, 0.27, 0.18, 0.6 * a))
	# ⑥ 港口与地名：只有认得名字的陆地才写名字
	for p in world.ports():
		var pos := Geom2D.centroid(p["shape"]) * px_per_m
		if not voyage.known_places.has(str(p.get("id", ""))):
			continue
		draw_circle(pos, 4.0 * _s, Color(INK, 0.9 * a))
		draw_arc(pos, 8.0 * _s, 0.0, TAU, 20, Color(INK, 0.7 * a), 1.5 * _s, true)
		# 港口在海面上，所以字用浅色（墨色写在深蓝的海上读不出来）
		_text(pos + Vector2(12.0, 5.0) * _s, str(p.get("name", "")),
			Color(0.94, 0.90, 0.76, 0.95 * a), 13)
	for f in world.lands():
		if not voyage.known_places.has(str(f["id"])):
			continue
		var at := Geom2D.centroid(f["shape"]) * px_per_m
		if f.has("label_pos"):
			var lp: Array = f["label_pos"]
			at = Vector2(float(lp[0]), float(lp[1])) * px_per_m
		_text(at, str(f.get("name", "")), Color(0.36, 0.28, 0.19, 0.95 * a), 14)
	# ⑦ 雾：没发现的分块整块盖住（含地名与航段）
	var fog_col := Color(FOG, 0.93 * a)
	var fog_edge := Color(0.55, 0.65, 0.75, 0.16 * a)
	for ty in world.tiles.y:
		for tx in world.tiles.x:
			var t := Vector2i(tx, ty)
			if voyage.is_tile_discovered(t):
				continue
			var r := world.tile_rect(t)
			var box := Rect2(r.position * px_per_m, r.size * px_per_m)
			draw_rect(box, fog_col, true)
			# 几条斜线：把"没画过的海"和"界面上的黑方块"区分开
			var step := 60.0 * _s
			var d := 0.0
			while d < box.size.x + box.size.y:
				var from := box.position + Vector2(d, 0.0)
				var to := box.position + Vector2(maxf(d - box.size.y, 0.0),
					minf(d, box.size.y))
				draw_line(from, to, Color(0.42, 0.55, 0.68, 0.10 * a), 2.0 * _s, true)
				d += step
			draw_rect(box, fog_edge, false, 1.0 * _s)
	# ⑧ 图外的海：伊比利亚/巴西这些陆地是按**真实坐标**画出去的，会溢出图框。
	#    海图应该是一张裁齐的图，所以把框外的部分再盖回去（不是把陆地裁掉，
	#    而是让"框外"看起来同样是没画过的海）。
	_mask_outside(a)
	# ⑨ 图廓与比例尺（一张海图该有的东西）
	draw_rect(Rect2(Vector2.ZERO, size_px), Color(0.42, 0.34, 0.22, 0.8 * a), false, 3.0 * _s)
	_scale_bar(a)
	_compass(a)


# ------------------------------------------------------------ 零件

func _shrunk(shape: Dictionary, k: float) -> Dictionary:
	"""往内收一圈（手绘等高线用）。"""
	var s := shape.duplicate()
	if Geom2D.is_band(s):
		s["half_width_m"] = float(s["half_width_m"]) * k
	else:
		s["radius_m"] = float(s["radius_m"]) * k
	return s


func _flow_arrows(pts: PackedVector2Array, a: float) -> void:
	for i in range(pts.size() - 1):
		var at := pts[i].lerp(pts[i + 1], 0.55) * px_per_m
		var d := (pts[i + 1] - pts[i]).normalized()
		var n := Vector2(-d.y, d.x)
		draw_colored_polygon(PackedVector2Array([
			at + d * 12.0 * _s, at - d * 4.0 * _s + n * 6.0 * _s,
			at - d * 4.0 * _s - n * 6.0 * _s]),
			Color(0.72, 0.88, 0.97, 0.6 * a))


func _crosses(at: Vector2, radius: float, a: float) -> void:
	var col := Color(0.55, 0.25, 0.2, 0.75 * a)
	var r := maxf(4.0, radius * px_per_m)
	for i in 4:
		var ang := TAU * float(i) / 4.0
		var c := at * px_per_m + Vector2(cos(ang), sin(ang)) * r * 0.6
		draw_line(c - Vector2(3, 3) * _s, c + Vector2(3, 3) * _s, col, 1.5 * _s, true)
		draw_line(c - Vector2(3, -3) * _s, c + Vector2(3, -3) * _s, col, 1.5 * _s, true)


func _dashes(a: Vector2, b: Vector2, col: Color) -> void:
	var n := maxi(2, int(a.distance_to(b) / (22.0 * _s)))
	for i in n:
		if i % 2 == 1:
			continue
		draw_line(a.lerp(b, float(i) / float(n)), a.lerp(b, float(i + 1) / float(n)),
			col, 2.0 * _s, true)


func _screen_rect() -> Rect2:
	"""屏幕四角换回世界坐标 —— 罗盘和比例尺要钉在**屏幕**上，不是钉在世界角上。"""
	var inv := get_viewport().get_canvas_transform().affine_inverse()
	var vp := get_viewport_rect().size
	var tl := inv * Vector2.ZERO
	var br := inv * vp
	return Rect2(tl, br - tl)


func _mask_outside(a: float) -> void:
	var vis := _screen_rect().grow(200.0 * _s)
	var w := Rect2(Vector2.ZERO, world.world_m * px_per_m)
	var w_end := w.position + w.size
	var vis_end := vis.position + vis.size
	var col := Color(0.031, 0.078, 0.114, a)
	if vis.position.y < w.position.y:
		draw_rect(Rect2(vis.position,
			Vector2(vis.size.x, w.position.y - vis.position.y)), col, true)
	if vis_end.y > w_end.y:
		draw_rect(Rect2(Vector2(vis.position.x, w_end.y),
			Vector2(vis.size.x, vis_end.y - w_end.y)), col, true)
	var band := Vector2(0.0, w.size.y)
	if vis.position.x < w.position.x:
		draw_rect(Rect2(Vector2(vis.position.x, w.position.y),
			Vector2(w.position.x - vis.position.x, band.y)), col, true)
	if vis_end.x > w_end.x:
		draw_rect(Rect2(Vector2(w_end.x, w.position.y),
			Vector2(vis_end.x - w_end.x, band.y)), col, true)


func _scale_bar(a: float) -> void:
	"""比例尺：一段 5 公里的线，画在屏幕左下角。"""
	var r := _screen_rect()
	var km5 := 5000.0 * px_per_m
	var at := Vector2(r.position.x + 30.0 * _s, r.position.y + r.size.y - 40.0 * _s)
	var col := Color(0.72, 0.66, 0.5, 0.9 * a)
	draw_line(at, at + Vector2(km5, 0.0), col, 2.0 * _s)
	for i in [0.0, 0.5, 1.0]:
		draw_line(at + Vector2(km5 * i, -5.0 * _s), at + Vector2(km5 * i, 5.0 * _s),
			col, 2.0 * _s)
	_text(at + Vector2(0.0, -14.0 * _s), "5 公里", col, 13)


func _compass(a: float) -> void:
	var r := _screen_rect()
	var s := _s
	var at := Vector2(r.position.x + r.size.x - 70.0 * s, r.position.y + 70.0 * s)
	var col := Color(0.42, 0.34, 0.22, 0.85 * a)
	draw_arc(at, 26.0 * s, 0.0, TAU, 32, col, 1.5 * s, true)
	draw_colored_polygon(PackedVector2Array([
		at + Vector2(0, -30) * s, at + Vector2(6, 0) * s,
		at + Vector2(0, 30) * s, at + Vector2(-6, 0) * s]), col)
	_text(at + Vector2(-4, -34) * s, "北", col, 13)


func _text(at: Vector2, s: String, col: Color, px: int) -> void:
	if font == null:
		return
	# 海图上的字按**屏幕**字号画：拉远拉近都一样大（换算式与 sea_debug._label 同源）
	var size := maxi(6, int(float(px) / maxf(zoom, 0.001)))
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _route_known(r: Dictionary) -> bool:
	var pts := voyage.sea.route_points(r)
	if pts.size() < 2:
		return false
	return voyage.is_tile_discovered(voyage.sea.tile_of(pts[0])) \
		and voyage.is_tile_discovered(voyage.sea.tile_of(pts[pts.size() - 1]))
