class_name Geom2D
extends RefCounted

# 世界地形的两个基本形状（docs/15 第 2 节）。
#
#   circle —— 圆：岛、暗礁、港口
#   band   —— 折线 + 半宽的带子：海岸、洋流带、礁脉
#
# **只有这两个原语**。v0.1 的 8km 海域（一座圆岛 + 一个圆礁 + 一条两点洋流带）
# 恰好是它们的特例，所以老海域的数据一个数都不用改，`test_world` 的 62 项断言
# 原样就能过 —— 这是"换一层实现"而不是"重写世界"的判据（docs/13 第 5.2 节）。
#
# 形状字典：
#   { "shape": "circle", "center": Vector2, "radius_m": float }
#   { "shape": "band",   "points": PackedVector2Array, "half_width_m": float }
#
# 它只有**纯函数**：不引用任何节点、不存状态，所以可以放心地被地形查询、
# 船的陆地碰撞、海图三方共用（"甲板外形与船壳轮廓必须同源"的同一套路子）。


static func make_circle(center: Vector2, radius_m: float) -> Dictionary:
	return { "shape": "circle", "center": center, "radius_m": maxf(0.0, radius_m) }


static func make_band(points: PackedVector2Array, half_width_m: float) -> Dictionary:
	return { "shape": "band", "points": points, "half_width_m": maxf(0.0, half_width_m) }


static func is_band(shape: Dictionary) -> bool:
	return str(shape.get("shape", "")) == "band"


static func extent(shape: Dictionary) -> float:
	"""形状的"半宽"：圆是半径，带子是半宽。"""
	if is_band(shape):
		return float(shape.get("half_width_m", 0.0))
	return float(shape.get("radius_m", 0.0))


static func centroid(shape: Dictionary) -> Vector2:
	"""重心（只用于海图上摆标签、算大致范围，不是几何判定的依据）。"""
	if not is_band(shape):
		return shape.get("center", Vector2.ZERO)
	var pts: PackedVector2Array = shape.get("points", PackedVector2Array())
	if pts.is_empty():
		return Vector2.ZERO
	var s := Vector2.ZERO
	for p in pts:
		s += p
	return s / float(pts.size())


static func dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var d := b - a
	var len2 := d.length_squared()
	if len2 <= 1e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(d) / len2, 0.0, 1.0)
	return p.distance_to(a + d * t)


static func nearest_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var d := b - a
	var len2 := d.length_squared()
	if len2 <= 1e-9:
		return a
	return a + d * clampf((p - a).dot(d) / len2, 0.0, 1.0)


static func dist_to_polyline(p: Vector2, pts: PackedVector2Array) -> float:
	if pts.is_empty():
		return INF
	if pts.size() == 1:
		return p.distance_to(pts[0])
	var best := INF
	for i in range(pts.size() - 1):
		best = minf(best, dist_to_segment(p, pts[i], pts[i + 1]))
	return best


static func nearest_on_polyline(p: Vector2, pts: PackedVector2Array) -> Vector2:
	if pts.is_empty():
		return Vector2.ZERO
	if pts.size() == 1:
		return pts[0]
	var best := INF
	var at := pts[0]
	for i in range(pts.size() - 1):
		var q := nearest_on_segment(p, pts[i], pts[i + 1])
		var d := p.distance_to(q)
		if d < best:
			best = d
			at = q
	return at


static func segment_dir_at(p: Vector2, pts: PackedVector2Array) -> Vector2:
	"""离 p 最近的那一段的方向（单位矢量）。用来判断"岸是不是横在风里"。"""
	if pts.size() < 2:
		return Vector2.RIGHT
	var best := INF
	var dir := Vector2.RIGHT
	for i in range(pts.size() - 1):
		var q := nearest_on_segment(p, pts[i], pts[i + 1])
		var d := p.distance_to(q)
		if d < best:
			best = d
			var seg := pts[i + 1] - pts[i]
			if seg.length() > 1e-6:
				dir = seg.normalized()
	return dir


static func center_dist(shape: Dictionary, p: Vector2) -> float:
	"""到"骨架"的距离：圆是到圆心，带子是到折线。"""
	if is_band(shape):
		return dist_to_polyline(p, shape.get("points", PackedVector2Array()))
	return p.distance_to(shape.get("center", Vector2.ZERO))


static func nearest_on_skeleton(shape: Dictionary, p: Vector2) -> Vector2:
	if is_band(shape):
		return nearest_on_polyline(p, shape.get("points", PackedVector2Array()))
	return shape.get("center", Vector2.ZERO)


static func surface_dist(shape: Dictionary, p: Vector2) -> float:
	"""到轮廓的距离：<= 0 表示在形状里面（负得越多越深）。"""
	return center_dist(shape, p) - extent(shape)


static func inside(shape: Dictionary, p: Vector2) -> bool:
	return center_dist(shape, p) <= extent(shape)


static func aabb(shape: Dictionary) -> Rect2:
	var e := extent(shape)
	if is_band(shape):
		var pts: PackedVector2Array = shape.get("points", PackedVector2Array())
		if pts.is_empty():
			return Rect2(Vector2.ZERO, Vector2.ZERO)
		var lo := pts[0]
		var hi := pts[0]
		for q in pts:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
		return Rect2(lo - Vector2(e, e), (hi - lo) + Vector2(2.0 * e, 2.0 * e))
	var c: Vector2 = shape.get("center", Vector2.ZERO)
	return Rect2(c - Vector2(e, e), Vector2(2.0 * e, 2.0 * e))


static func ring_point(shape: Dictionary, p: Vector2, inset: float) -> Vector2:
	"""骨架往 p 的方向外推 (extent - inset)：对圆岛就是沙滩环上离船最近的那个点。

	对标 v0.1 的 `_shore_near`（`center + dir * (r - beach_width * 0.5)`）——
	inset 传 `beach_width * 0.5` 时结果完全一样。
	"""
	var q := nearest_on_skeleton(shape, p)
	var d := p - q
	var r := maxf(0.0, extent(shape) - inset)
	if d.length() < 1e-6:
		return q + Vector2(-r, 0.0)
	return q + d.normalized() * r


static func clamp_inside(shape: Dictionary, p: Vector2, margin: float) -> Vector2:
	"""把点收进形状里面（离轮廓留 margin）。队伍在岛上走路用它。"""
	var q := nearest_on_skeleton(shape, p)
	var lim := maxf(0.0, extent(shape) - margin)
	var d := p - q
	if d.length() <= lim:
		return p
	if d.length() < 1e-6:
		return q
	return q + d.normalized() * lim


# ------------------------------------------------------------ 绘制（地形 / 海图共用）
# 只有这两个原语的画法，所以"沙滩环 + 草木心"、"海岸 + 内陆"、"海图上的轮廓"
# 全都长在同一份几何上 —— 与铁律 4（甲板外形与船壳轮廓同源）是同一个道理。

static func draw_shape(ci: CanvasItem, shape: Dictionary, col: Color, scale := 1.0) -> void:
	"""实心形状。带子用"每段一条粗线 + 每个顶点一个圆"画，接头处不会缺口。"""
	if is_band(shape):
		var pts: PackedVector2Array = shape.get("points", PackedVector2Array())
		var hw := float(shape.get("half_width_m", 0.0)) * scale
		for i in range(pts.size() - 1):
			ci.draw_line(pts[i] * scale, pts[i + 1] * scale, col, hw * 2.0, true)
		for p in pts:
			ci.draw_circle(p * scale, hw, col)
	else:
		ci.draw_circle((shape.get("center", Vector2.ZERO) as Vector2) * scale,
			float(shape.get("radius_m", 0.0)) * scale, col)


static func draw_shape_outline(ci: CanvasItem, shape: Dictionary, col: Color,
		width := 2.0, scale := 1.0) -> void:
	"""轮廓线。带子两边各偏移一个半宽（顶点法线取相邻两段的平均）。"""
	if is_band(shape):
		var pts: PackedVector2Array = shape.get("points", PackedVector2Array())
		if pts.size() < 2:
			return
		var hw := float(shape.get("half_width_m", 0.0))
		var nrm := vertex_normals(pts)
		var left := PackedVector2Array()
		var right := PackedVector2Array()
		for i in pts.size():
			left.append((pts[i] + nrm[i] * hw) * scale)
			right.append((pts[i] - nrm[i] * hw) * scale)
		ci.draw_polyline(left, col, width, true)
		ci.draw_polyline(right, col, width, true)
		ci.draw_line(left[0], right[0], col, width, true)
		ci.draw_line(left[pts.size() - 1], right[pts.size() - 1], col, width, true)
	else:
		ci.draw_arc((shape.get("center", Vector2.ZERO) as Vector2) * scale,
			float(shape.get("radius_m", 0.0)) * scale, 0.0, TAU, 64, col, width, true)


static func vertex_normals(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size():
		var d := Vector2.ZERO
		if i > 0:
			d += (pts[i] - pts[i - 1]).normalized()
		if i < pts.size() - 1:
			d += (pts[i + 1] - pts[i]).normalized()
		if d.length() < 1e-6:
			d = Vector2.RIGHT
		out.append(Vector2(-d.y, d.x).normalized())
	return out
