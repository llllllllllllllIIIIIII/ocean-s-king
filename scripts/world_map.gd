class_name WorldMap
extends RefCounted

# 世界分块（M2）：把"一片 8km 的方块海"换成"一块一块拼起来的大西洋"。
#
# 三条设计（docs/13 第 5.2 节 / docs/15）：
#
#   1. **地形的真源是全局的**，不是 tile 的。所有特征（岛、海岸、礁、洋流、港、
#      地标）都用**世界坐标**写一份；tile 只是给它们建的**空间索引**。
#      所以"同一坐标在哪个 tile 采样结果一致"不是靠小心，而是靠构造：
#      查询永远只看"这个点"，tile 只决定**算哪些候选**。
#   2. **特征按 AABB 登记进它碰到的每一个 tile**（边界上的一点余地都不留），
#      所以压在缝上的海岸在缝两边都在候选里。
#   3. `force_full_scan = true` 时绕开索引全量扫描 —— `tests/test_worldmap.gd`
#      拿它做对照：索引版与全扫版**逐位相等**才算过。
#
# 数据格式（`data/world/*.json`）：
#   - 老格式（`test_sea.json`）：island / reef / current / port 四个块；
#   - 新格式（`data/world/atlantic/*.json`）：`world_m` + `tile_m` + `features[]`。
#   两种都读得进来，出来的都是同一套 features —— 老海域不需要改一个数。
#
# **全球图（M9）**：世界数据里多一个 `projection` 块时，特征可以直接写**经纬度**
#   （`points_lonlat` / `center_lonlat` / `from_lonlat` / `to_lonlat` / `pos_lonlat`
#   以及 POI 的 `pos_lonlat`），加载时换算成米。地理数据写真实经纬度才**能核**：
#   「圣卢卡尔在 36.8°N/6.3°W」是可以对着地图查的，「x=154667」不是。
#   等距圆柱：x = (lon − lon0) × m_per_deg，y = (lat0 − lat) × m_per_deg。

const DEFAULT_TILE_M := 16000.0
const DEFAULT_LEE := 0.45
# 背风区的横向跨度：v0.1 的公式是 `extent * 3`（岛半径的 3 倍）。
# ⚠️ 这意味着**影响范围比外形大得多** —— 索引必须按影响范围登记，
#    否则"站在岸外 2 公里、明明在背风区里"的点在跨块时会突然读不到那块陆地的影子。
const LEE_SPAN := 3.0
# 环球航行的世界是**圆柱**，不是平面：地球一整圈 360° 压进 320km 之后，
# 从西往东绕回来必然要跨过一条"接缝"。把 x 轴卷起来（wrap_x）之后，
# 接缝就不再是一个地方 —— 它只是坐标的数字游戏，地形在缝两边是同一片。
const WRAP_EPS := 0.001

var name := ""
var tile_m := DEFAULT_TILE_M
var world_m := Vector2.ZERO
var tiles := Vector2i.ONE
var wind := {}
var features: Array = []          # [{id, kind, name, shape, ...}]
var ready := false
var force_full_scan := false      # 测试专用：绕开 tile 索引
var projection := {}              # 有它才认 `*_lonlat` 字段（老海域没有）
var wrap_x := false               # 圆柱世界（全球图）：x 轴按世界宽度卷起来
var regions: Array = []           # 海图分区图幅（可选）：[{id, name, rect}]

var _tile_features: Array = []    # 每个 tile -> Array[int]（features 的下标）
var _m_per_deg := 0.0
var _lon0 := -180.0
var _lat0 := 90.0


func setup(data: Dictionary) -> bool:
	name = str(data.get("name", "无名海域"))
	tile_m = maxf(1.0, float(data.get("tile_m", DEFAULT_TILE_M)))
	wind = data.get("wind", {})
	wrap_x = bool(data.get("wrap_x", false))
	# 先把 world_m 定下来：投影的每度米数可以从它推出来（3218.7 那个系数不该手写两遍）
	var w: Array = data.get("world_m", [])
	if w.size() >= 2:
		world_m = Vector2(float(w[0]), float(w[1]))
	elif data.has("size_m"):
		var s: Array = data["size_m"]
		world_m = Vector2(float(s[0]), float(s[1]))
	else:
		world_m = Vector2.ZERO
	_setup_projection(data.get("projection", {}))
	features.clear()
	if data.has("features"):
		for raw in data.get("features", []):
			features.append(_feature(raw))
	else:
		_legacy_features(data)
	regions.clear()
	for raw in data.get("regions", []):
		regions.append(_region(raw))
	if world_m == Vector2.ZERO:
		world_m = _features_aabb().end
	tiles = Vector2i(maxi(1, int(ceil(world_m.x / tile_m))), maxi(1, int(ceil(world_m.y / tile_m))))
	_build_index()
	ready = true
	return true


# ------------------------------------------------------------ 投影（全球图用）

func _setup_projection(p) -> void:
	projection = p if typeof(p) == TYPE_DICTIONARY else {}
	if projection.is_empty():
		_m_per_deg = 0.0
		return
	_lon0 = float(projection.get("lon0", -180.0))
	_lat0 = float(projection.get("lat0", 90.0))
	# 默认：整张图横跨 360°，所以每度米数 = 图宽 ÷ 360
	_m_per_deg = float(projection.get("m_per_deg", world_m.x / 360.0 if world_m.x > 0.0 else 0.0))
	if projection.has("wrap"):
		wrap_x = bool(projection["wrap"])


func has_projection() -> bool:
	return _m_per_deg > 0.0


func lonlat_to_m(lon: float, lat: float) -> Vector2:
	"""经纬度 → 地图米。只在世界数据声明了 `projection` 时有意义。"""
	return Vector2((lon - _lon0) * _m_per_deg, (_lat0 - lat) * _m_per_deg)


func m_to_lonlat(p: Vector2) -> Vector2:
	"""地图米 → 经纬度（海图上的读数、导出用）。返回 (lon, lat)。"""
	if _m_per_deg <= 0.0:
		return Vector2.ZERO
	var lon := _lon0 + wrap_pos(p).x / _m_per_deg
	if lon > 180.0:
		lon -= 360.0
	return Vector2(lon, _lat0 - p.y / _m_per_deg)


# ------------------------------------------------------------ 圆柱（wrap_x）

func wraps() -> bool:
	return wrap_x and world_m.x > 0.0


func wrap_pos(p: Vector2) -> Vector2:
	"""把 x 卷进世界宽度。环球时"越过接缝"不是瞬移，只是坐标回到 0 那一边。"""
	if not wraps():
		return p
	return Vector2(fposmod(p.x, world_m.x), p.y)


func dx(a: Vector2, b: Vector2) -> float:
	"""从 a 到 b 的 x 位移，取**绕地球走最短的那一边**。"""
	var d := b.x - a.x
	if wraps():
		d = fposmod(d + world_m.x * 0.5, world_m.x) - world_m.x * 0.5
	return d


func delta(a: Vector2, b: Vector2) -> Vector2:
	"""从 a 到 b 的位移（x 走最短的一边，y 照常）。"""
	return Vector2(dx(a, b), b.y - a.y)


func dist(a: Vector2, b: Vector2) -> float:
	"""两点之间的距离（环球时走最短的一边）。"""
	return delta(a, b).length()


func _projected(raw: Dictionary) -> Dictionary:
	"""把 `*_lonlat` 字段换算成米。没有投影、或没写 lonlat 的原样返回。"""
	if not has_projection():
		return raw
	var any := raw.has("points_lonlat") or raw.has("center_lonlat") \
		or raw.has("from_lonlat") or raw.has("to_lonlat") or raw.has("pos_lonlat")
	if not any:
		return raw
	var f := raw.duplicate(true)
	if raw.has("points_lonlat"):
		f["points"] = _lonlat_list(raw["points_lonlat"])
	if raw.has("center_lonlat"):
		f["center"] = _lonlat_one(raw["center_lonlat"])
	if raw.has("pos_lonlat"):
		f["pos"] = _lonlat_one(raw["pos_lonlat"])
	if raw.has("from_lonlat"):
		f["from"] = _lonlat_one(raw["from_lonlat"])
	if raw.has("to_lonlat"):
		f["to"] = _lonlat_one(raw["to_lonlat"])
	if raw.has("pois"):
		var pois := []
		for p in raw["pois"]:
			if typeof(p) == TYPE_DICTIONARY and (p as Dictionary).has("pos_lonlat"):
				var q: Dictionary = (p as Dictionary).duplicate(true)
				q["pos"] = _lonlat_one(q["pos_lonlat"])
				pois.append(q)
			else:
				pois.append(p)
		f["pois"] = pois
	if raw.has("label_lonlat"):
		f["label_pos"] = _lonlat_one(raw["label_lonlat"])
	return f


func _lonlat_one(v) -> Array:
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
		var p := lonlat_to_m(float(v[0]), float(v[1]))
		return [p.x, p.y]
	return [0.0, 0.0]


func _lonlat_list(raw) -> Array:
	var out := []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for v in raw:
		out.append(_lonlat_one(v))
	return out


func _region(raw) -> Dictionary:
	"""海图分区图幅：一块矩形 + 一个名字。**用米写**（`rect`），不用经纬度 ——
	跨接缝的经纬度矩形会算出一整张图那么大的框。"""
	var out := {"id": str(raw.get("id", "")), "name": str(raw.get("name", ""))}
	if raw.has("rect"):
		var r: Array = raw["rect"]
		if r.size() >= 4:
			out["rect"] = Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
		else:
			out["rect"] = Rect2()
	elif raw.has("center") and raw.has("size"):
		var c: Array = raw["center"]
		var s: Array = raw["size"]
		out["rect"] = Rect2(float(c[0]) - float(s[0]) * 0.5, float(c[1]) - float(s[1]) * 0.5,
			float(s[0]), float(s[1]))
	else:
		out["rect"] = Rect2()
	return out


func region_of_tile(t: Vector2i) -> Dictionary:
	var p := tile_rect(t).get_center()
	for rg in regions:
		if (rg["rect"] as Rect2).has_point(p):
			return rg
	return {}


# ------------------------------------------------------------ 装载

func _feature(raw: Dictionary) -> Dictionary:
	var f := _projected(raw)
	# ⚠️ 一律从**投影之后**的 f 上取：`points_lonlat` 换成 `points` 之后，
	#    形状与地标都得用换好的那一份，不然它们会全部落在原点。
	f["id"] = str(f.get("id", f.get("name", "?")))
	f["name"] = str(f.get("name", f["id"]))
	f["kind"] = str(f.get("kind", "land"))
	f["shape"] = _shape_of(f)
	f["beach_width_m"] = float(f.get("beach_width_m", 0.0))
	f["pois"] = f.get("pois", [])
	return f


func _shape_of(raw: Dictionary) -> Dictionary:
	var pts := _points(raw.get("points", raw.get("polyline", [])))
	# ⚠️ 老数据的 `_legacy_feature` 里 from/to 永远是空数组，所以不能只看 has() ——
	#    只看 has() 会把圆岛当成"半宽 0 的带子"，于是全世界的 is_land 都变成 false。
	if _is_pt(raw.get("from")) and _is_pt(raw.get("to")):
		pts = _points([raw["from"], raw["to"]])
	if pts.size() >= 2:
		var hw := float(raw.get("half_width_m", float(raw.get("width_m", 0.0)) * 0.5))
		return Geom2D.make_band(pts, hw)
	var c := _vec(raw.get("center", raw.get("pos", [0.0, 0.0])))
	var r := float(raw.get("radius_m", 0.0))
	return Geom2D.make_circle(c, r)


func _legacy_features(data: Dictionary) -> void:
	"""v0.1 的 `test_sea.json`（island / reef / current / port）转成 features。"""
	if data.has("island") and not (data["island"] as Dictionary).is_empty():
		features.append(_feature(_legacy_feature(data["island"], "land", "island")))
	if data.has("reef") and not (data["reef"] as Dictionary).is_empty():
		features.append(_feature(_legacy_feature(data["reef"], "reef", "reef")))
	if data.has("current") and not (data["current"] as Dictionary).is_empty():
		features.append(_feature(_legacy_feature(data["current"], "current", "current")))
	if data.has("port") and not (data["port"] as Dictionary).is_empty():
		features.append(_feature(_legacy_feature(data["port"], "port", "port")))


func _legacy_feature(raw: Dictionary, kind: String, id: String) -> Dictionary:
	return {
		"id": id, "kind": kind, "name": str(raw.get("name", id)),
		"center": raw.get("center", raw.get("pos", [0.0, 0.0])),
		"radius_m": float(raw.get("radius_m", 0.0)),
		"beach_width_m": float(raw.get("beach_width_m", 0.0)),
		"from": raw.get("from", []), "to": raw.get("to", []),
		"width_m": float(raw.get("width_m", 0.0)),
		"speed_ms": float(raw.get("speed_ms", 0.0)),
		"text": str(raw.get("text", "")),
		"pois": raw.get("pois", []),
		"primary": kind == "land",
	}


func _points(raw) -> PackedVector2Array:
	var out := PackedVector2Array()
	if typeof(raw) != TYPE_ARRAY:
		return out
	for p in raw:
		if _is_pt(p):
			out.append(_vec(p))
	return out


func _is_pt(p) -> bool:
	return (typeof(p) == TYPE_VECTOR2) \
		or (typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2)


func _vec(p) -> Vector2:
	if typeof(p) == TYPE_VECTOR2:
		return p
	if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2:
		return Vector2(float(p[0]), float(p[1]))
	return Vector2.ZERO


# ------------------------------------------------------------ 分块索引

func _build_index() -> void:
	_tile_features.clear()
	_tile_features.resize(tiles.x * tiles.y)
	for i in _tile_features.size():
		_tile_features[i] = []
	for i in features.size():
		for t in tiles_of_feature(features[i]):
			(_tile_features[_tile_index(t)] as Array).append(i)


func tile_of(pos: Vector2) -> Vector2i:
	if wraps():
		return Vector2i(
			int(floor(fposmod(pos.x, world_m.x) / tile_m)) % maxi(1, tiles.x),
			clampi(int(floor(pos.y / tile_m)), 0, tiles.y - 1))
	return Vector2i(
		clampi(int(floor(pos.x / tile_m)), 0, tiles.x - 1),
		clampi(int(floor(pos.y / tile_m)), 0, tiles.y - 1))


func tile_key(t: Vector2i) -> String:
	return "%d,%d" % [t.x, t.y]


func tile_rect(t: Vector2i) -> Rect2:
	return Rect2(Vector2(float(t.x), float(t.y)) * tile_m, Vector2(tile_m, tile_m))


func tiles_of(shape: Dictionary) -> Array:
	"""一个形状碰到的所有 tile（含只压到一条边的）。"""
	var box := Geom2D.aabb(shape)
	return _tiles_of_box(box)


func influence_aabb(f: Dictionary) -> Rect2:
	"""一个特征**影响**到的范围（不只是它的外形）。

	陆地的影响范围要往外放 `LEE_SPAN × 半宽`：背风区在岸外，不在岸里。
	"""
	var box := Geom2D.aabb(f["shape"])
	if str(f["kind"]) == "land":
		box = box.grow(Geom2D.extent(f["shape"]) * LEE_SPAN)
	return box


func tiles_of_feature(f: Dictionary) -> Array:
	return _tiles_of_box(influence_aabb(f))


func _tiles_of_box(box: Rect2) -> Array:
	var out := []
	if wraps():
		# 一个盒子可能横跨接缝（x 从 319km 绕到 0）—— 按**未卷的格子号**枚举，
		# 再用 tile_of 卷回去，缝上就不会漏掉任何一个格子。
		var tx0 := int(floor(box.position.x / tile_m))
		var tx1 := int(floor((box.position.x + box.size.x) / tile_m))
		var ty0 := clampi(int(floor(box.position.y / tile_m)), 0, tiles.y - 1)
		var ty1 := clampi(int(floor((box.position.y + box.size.y) / tile_m)), 0, tiles.y - 1)
		if tx1 - tx0 + 1 >= tiles.x:
			for ty in range(ty0, ty1 + 1):
				for tx in range(tiles.x):
					out.append(Vector2i(tx, ty))
			return out
		for ty in range(ty0, ty1 + 1):
			for tx in range(tx0, tx1 + 1):
				out.append(Vector2i(posmod(tx, tiles.x), ty))
		return out
	var t0 := tile_of(box.position)
	var t1 := tile_of(box.position + box.size)
	for ty in range(t0.y, t1.y + 1):
		for tx in range(t0.x, t1.x + 1):
			out.append(Vector2i(tx, ty))
	return out


func features_in_tile(t: Vector2i) -> Array:
	var out := []
	for i in (_tile_features[_tile_index(t)] as Array):
		out.append(features[i])
	return out


func _tile_index(t: Vector2i) -> int:
	return clampi(t.y, 0, tiles.y - 1) * tiles.x + clampi(t.x, 0, tiles.x - 1)


func candidates(pos: Vector2) -> Array:
	"""查询这个点时该看哪些 features。全扫模式直接用全体，供测试对照。"""
	if force_full_scan or _tile_features.is_empty():
		var all := []
		all.resize(features.size())
		for i in features.size():
			all[i] = i
		return all
	return _tile_features[_tile_index(tile_of(pos))]


func _features_aabb() -> Rect2:
	if features.is_empty():
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var box := Geom2D.aabb((features[0] as Dictionary)["shape"])
	for f in features:
		box = box.merge(Geom2D.aabb(f["shape"]))
	return box


# ------------------------------------------------------------ 地形查询（签名与 v0.1 一致）

func size_m() -> Vector2:
	return world_m


func in_bounds(pos: Vector2) -> bool:
	if wraps():
		return pos.y >= 0.0 and pos.y <= world_m.y
	return pos.x >= 0.0 and pos.y >= 0.0 and pos.x <= world_m.x and pos.y <= world_m.y


func is_land(pos: Vector2) -> bool:
	return not land_containing(pos).is_empty()


func is_beach(pos: Vector2) -> bool:
	"""沙滩 = 陆地**靠外的那一圈**（不是"陆地里的浅色部分"）。

	v0.1 的口径：`dist >= r - beach_width`。翻译成到轮廓的距离就是
	`-beach_width <= surface_dist <= 0` —— 岛心那种"负得很深"的地方是干地，不是沙滩。
	"""
	var f := land_containing(pos)
	if f.is_empty():
		return false
	return Geom2D.surface_dist(f["shape"], pos) >= -float(f.get("beach_width_m", 0.0))


func is_dry_land(pos: Vector2) -> bool:
	var f := land_containing(pos)
	if f.is_empty():
		return false
	return Geom2D.surface_dist(f["shape"], pos) < -float(f.get("beach_width_m", 0.0))


func land_containing(pos: Vector2) -> Dictionary:
	"""这点在哪块陆地上？都没踩上就返回空字典。

	同时踩上两块（海岸压着岛）时取**陷得最深**的那一块 —— 与候选顺序无关，
	这样索引版和全扫版永远给同一个答案。
	"""
	pos = wrap_pos(pos)
	var best: Dictionary = {}
	var deepest := 0.0
	for i in candidates(pos):
		var f: Dictionary = features[i]
		if str(f["kind"]) != "land":
			continue
		var depth := -Geom2D.surface_dist(f["shape"], pos)
		if depth >= 0.0 and (best.is_empty() or depth > deepest):
			best = f
			deepest = depth
	return best


func is_reef(pos: Vector2) -> bool:
	pos = wrap_pos(pos)
	for i in candidates(pos):
		var f: Dictionary = features[i]
		if str(f["kind"]) == "reef" and Geom2D.inside(f["shape"], pos):
			return true
	return false


func reef_at(pos: Vector2) -> Dictionary:
	pos = wrap_pos(pos)
	for i in candidates(pos):
		var f: Dictionary = features[i]
		if str(f["kind"]) == "reef" and Geom2D.inside(f["shape"], pos):
			return f
	return {}


func is_port(pos: Vector2) -> bool:
	return not port_at(pos).is_empty()


func port_at(pos: Vector2) -> Dictionary:
	pos = wrap_pos(pos)
	var best: Dictionary = {}
	var best_d := INF
	for i in candidates(pos):
		var f: Dictionary = features[i]
		if str(f["kind"]) != "port":
			continue
		var d := Geom2D.center_dist(f["shape"], pos)
		if d <= Geom2D.extent(f["shape"]) and d < best_d:
			best = f
			best_d = d
	return best


func current_at(pos: Vector2) -> Vector2:
	"""洋流：流经这里的带的矢量之和（单条流时与 v0.1 完全一样）。

	流速按**相对水的速度**作用于受力，所以不挂帆也会被带走 —— Voyage 的事。
	"""
	pos = wrap_pos(pos)
	var v := Vector2.ZERO
	for i in candidates(pos):
		var f: Dictionary = features[i]
		if str(f["kind"]) != "current":
			continue
		var shape: Dictionary = f["shape"]
		if Geom2D.center_dist(shape, pos) > Geom2D.extent(shape):
			continue
		var dir := Geom2D.segment_dir_at(pos, shape.get("points", PackedVector2Array()))
		v += dir * float(f.get("speed_ms", 0.0))
	return v


func lee_factor(pos: Vector2) -> float:
	"""背风区：被陆地挡住的那一面，风是软的。取所有陆地里最"软"的那个。"""
	pos = wrap_pos(pos)
	var base := float(wind.get("lee_factor", DEFAULT_LEE))
	var best := 1.0
	for i in candidates(pos):
		var f: Dictionary = features[i]
		if str(f["kind"]) == "land":
			best = minf(best, _lee_of(f, pos, base))
	return best


func _lee_of(f: Dictionary, pos: Vector2, base: float) -> float:
	var shape: Dictionary = f["shape"]
	var ext := Geom2D.extent(shape)
	if ext <= 0.0:
		return 1.0
	var d := pos - Geom2D.nearest_on_skeleton(shape, pos)
	var dist := d.length()
	# 范围与淡出系数照抄 v0.1 的圆岛公式（r*3 与 r*2.5）—— 老海域的读数因此分毫不差
	if dist > ext * 3.0 or dist < 1.0:
		return 1.0
	var align := d.normalized().dot(_downwind())
	if align <= 0.0:
		return 1.0
	var fade := clampf(1.0 - dist / (ext * 2.5), 0.0, 1.0)
	var perp := 1.0
	if Geom2D.is_band(shape):
		# 一条与风向平行的海岸挡不住风（风是顺着岸吹的），只有横在风里的才挡得住
		perp = clampf(1.0 - absf(Geom2D.segment_dir_at(pos,
			shape.get("points", PackedVector2Array())).dot(_downwind())), 0.0, 1.0)
	return lerpf(1.0, base, align * fade * perp)


func _downwind() -> Vector2:
	"""风吹**去**的方向（世界系单位矢量）。"""
	var blow_to := deg_to_rad(float(wind.get("base_from_deg", 0.0)) + 180.0)
	return Vector2(cos(blow_to), sin(blow_to))


func poi_at(pos: Vector2) -> Dictionary:
	"""走到哪个地标上了？取最近的那个（与候选顺序无关）。"""
	pos = wrap_pos(pos)
	var best: Dictionary = {}
	var best_d := INF
	for i in candidates(pos):
		for poi in (features[i] as Dictionary).get("pois", []):
			var d := pos.distance_to(_vec(poi.get("pos", [0.0, 0.0])))
			if d <= float(poi.get("radius_m", 0.0)) and d < best_d:
				best = poi
				best_d = d
	return best


func pois() -> Array:
	var out := []
	for f in features:
		for poi in f.get("pois", []):
			out.append(poi)
	return out


func poi_pos(id: String) -> Vector2:
	for poi in pois():
		if str(poi.get("id", "")) == id:
			return _vec(poi.get("pos", [0.0, 0.0]))
	return Vector2.ZERO


func lands() -> Array:
	var out := []
	for f in features:
		if str(f["kind"]) == "land":
			out.append(f)
	return out


func ports() -> Array:
	var out := []
	for f in features:
		if str(f["kind"]) == "port":
			out.append(f)
	return out


func of_kind(kind: String) -> Array:
	var out := []
	for f in features:
		if str(f["kind"]) == kind:
			out.append(f)
	return out


func primary_land() -> Dictionary:
	"""剧情说的"那座岛"：标了 primary 的那块；没标就取第一块陆地。"""
	var first: Dictionary = {}
	for f in features:
		if str(f["kind"]) != "land":
			continue
		if first.is_empty():
			first = f
		if bool(f.get("primary", false)):
			return f
	return first


func port() -> Dictionary:
	var ps := ports()
	return ps[0] if ps.size() > 0 else {}


func island() -> Dictionary:
	"""v0.1 的老接口：返回"那座岛"的老形状（中心 / 半径 / 沙滩宽 / 地标）。"""
	var f := primary_land()
	if f.is_empty():
		return {}
	var c := Geom2D.centroid(f["shape"])
	return {
		"name": str(f.get("name", "")),
		"center": [c.x, c.y],
		"radius_m": Geom2D.extent(f["shape"]),
		"beach_width_m": float(f.get("beach_width_m", 0.0)),
		"pois": f.get("pois", []),
	}


func land_shapes(dry := true) -> Array:
	"""给船的陆地碰撞用：一串纯数据的形状（干地，不含可以靠上去的沙滩环）。"""
	var out := []
	for f in lands():
		var shape: Dictionary = (f["shape"] as Dictionary).duplicate()
		if dry:
			var cut := float(f.get("beach_width_m", 0.0))
			if Geom2D.is_band(shape):
				shape["half_width_m"] = maxf(1.0, float(shape["half_width_m"]) - cut)
			else:
				shape["radius_m"] = maxf(1.0, float(shape["radius_m"]) - cut)
		out.append(shape)
	return out


func nearest_shore(pos: Vector2) -> Dictionary:
	"""离船最近的那段岸（沙滩环上的一点）。登陆点就是它，不是固定航标。"""
	pos = wrap_pos(pos)
	var best := Vector2.ZERO
	var best_d := INF
	var which: Dictionary = {}
	for f in lands():
		var q := Geom2D.ring_point(f["shape"], pos, float(f.get("beach_width_m", 0.0)) * 0.5)
		var d := dist(pos, q)
		if d < best_d:
			best_d = d
			best = q
			which = f
	return { "pos": best, "distance_m": best_d, "land": which }


func is_shape(pos: Vector2, kind: String) -> bool:
	match kind:
		"land": return is_land(pos)
		"beach": return is_beach(pos)
		"dry": return is_dry_land(pos)
		"reef": return is_reef(pos)
		"port": return is_port(pos)
	return false


# ------------------------------------------------------------ 采样签名（测试用）

func sample(pos: Vector2) -> Dictionary:
	"""一个点的全部查询结果打成一份签名。

	"同一坐标在任意 tile 采样结果完全一致"就是断言这个字典相等（M2 的头号硬指标）。
	"""
	return {
		"land": is_land(pos),
		"beach": is_beach(pos),
		"dry": is_dry_land(pos),
		"reef": is_reef(pos),
		"port": is_port(pos),
		"current_x": current_at(pos).x,
		"current_y": current_at(pos).y,
		"lee": lee_factor(pos),
		"poi": str(poi_at(pos).get("id", "")),
		"land_id": str(land_containing(pos).get("id", "")),
	}


func describe() -> String:
	var counts := {}
	for f in features:
		var k := str(f["kind"])
		counts[k] = int(counts.get(k, 0)) + 1
	return "%s：%d×%d 米，%d 个 tile（%d×%d），%s" % [
		name, int(world_m.x), int(world_m.y), tiles.x * tiles.y, tiles.x, tiles.y,
		", ".join(counts.keys().map(func(k): return "%s %d" % [k, counts[k]]))]
