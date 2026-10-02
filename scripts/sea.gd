class_name Sea
extends RefCounted

# 海域（M2 起）：一层**保持签名不变**的壳，里面换成了 `WorldMap`。
#
# docs/13 第 5.2 节把这条写成了硬要求：
#   `is_land / is_beach / is_reef / is_port / current_at / lee_factor / poi_at`
#   七个查询**原名、原签名、原语义**，实现改成走 WorldMap。
#   这样 `Voyage`、`sea_debug.gd` 和 `test_world` 里那一批调用点都不用重写 ——
#   风险从"重写世界"降到"替换一层实现"。
#
# 两种数据都读得进来：
#   `data/world/test_sea.json`    —— v0.1 的 8km 迷你海域（回归用）
#   `data/world/atlantic/*.json`  —— M2 的大西洋（3×3 个 16km tile）
#   `data/world/global/*.json`    —— M9 的全球图（20×10 个 16km tile = 320km × 160km）
#
# 全球图分成几个地区文件写（大西洋 / 南美 / 太平洋 / 香料群岛 / 非洲 / 归乡），
# 主文件用 `"include": ["a.json", …]` 把它们**按顺序拼起来** —— 一个地区一个文件，
# 改一个地区不会碰到别的地区的数。

const DATA_PATH := "res://data/world/test_sea.json"
const ATLANTIC_PATH := "res://data/world/atlantic/geography.json"
const GLOBAL_PATH := "res://data/world/global/geography.json"

var data := {}
var world := WorldMap.new()
var route_list: Array = []        # 建议航段（可选：同目录下的 routes.json）
var path := ""
var ready := false


func setup(p := DATA_PATH) -> void:
	path = p
	var d = JSON.parse_string(FileAccess.get_file_as_string(p))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("海域数据读不出来：" + p)
		return
	if d.has("include"):
		d = _merged(d, p)
	data = d
	world.setup(d)
	route_list = _load_routes(p)
	ready = true


func _merged(d: Dictionary, p: String) -> Dictionary:
	"""把 `include` 里的地区文件的 features 拼进主文件（按 include 的顺序）。"""
	var merged := d.duplicate(true)
	var feats: Array = merged.get("features", []).duplicate(true)
	var dir := p.get_base_dir()
	for rel in d.get("include", []):
		var sub = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(str(rel))))
		if typeof(sub) != TYPE_DICTIONARY:
			push_error("地区数据读不出来：" + dir.path_join(str(rel)))
			continue
		for f in (sub as Dictionary).get("features", []):
			feats.append(f)
	merged["features"] = feats
	return merged


func ports_path() -> String:
	"""这个海域的港口经济表：同目录下的 `ports.json`；没有就退回大西洋那份。"""
	var pp := path.get_base_dir().path_join("ports.json")
	return pp if FileAccess.file_exists(pp) else Ports.DATA_PATH


func setup_data(d: Dictionary) -> void:
	"""直接喂一份已经解析好的数据（测试造小世界时用）。"""
	data = d
	world.setup(d)
	route_list = d.get("routes", [])
	ready = true


func _load_routes(p: String) -> Array:
	"""航段表放在海域文件旁边的 `routes.json`（没有就是空 —— 迷你海域没有航段）。"""
	var rp := p.get_base_dir().path_join("routes.json")
	if not FileAccess.file_exists(rp):
		return []
	var d = JSON.parse_string(FileAccess.get_file_as_string(rp))
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("航段表读不出来：" + rp)
		return []
	return d.get("routes", [])


func wind() -> Dictionary:
	return world.wind


func real_time_scale() -> float:
	"""地图的压缩系数：1 个地图公里 = 多少真实公里（v0.5 的大西洋是 125）。

	船在图上的速度、两个港之间的距离都是地图尺度；**日历、补给、价格**这些
	"跟真实航程有关"的东西要乘这个系数，否则 48km 的一趟横渡只吃两顿饭。
	迷你海域（test_sea）没有这个字段，默认 1.0。
	"""
	return maxf(1.0, float(data.get("real_km_per_map_km", 1.0)))


func size_m() -> Vector2:
	return world.size_m()


# ------------------------------------------------------------ 圆柱（全球图）

func wraps() -> bool:
	return world.wraps()


func wrap_pos(p: Vector2) -> Vector2:
	return world.wrap_pos(p)


func delta(a: Vector2, b: Vector2) -> Vector2:
	return world.delta(a, b)


func dist(a: Vector2, b: Vector2) -> float:
	return world.dist(a, b)


func lonlat_to_m(lon: float, lat: float) -> Vector2:
	return world.lonlat_to_m(lon, lat)


func m_to_lonlat(p: Vector2) -> Vector2:
	return world.m_to_lonlat(p)


func tile_m() -> float:
	return world.tile_m


func tiles() -> Vector2i:
	return world.tiles


func tile_of(pos: Vector2) -> Vector2i:
	return world.tile_of(pos)


func tile_key(t: Vector2i) -> String:
	return world.tile_key(t)


func in_bounds(pos: Vector2) -> bool:
	return world.in_bounds(pos)


func is_land(pos: Vector2) -> bool:
	return world.is_land(pos)


func is_beach(pos: Vector2) -> bool:
	return world.is_beach(pos)


func is_dry_land(pos: Vector2) -> bool:
	return world.is_dry_land(pos)


func land_containing(pos: Vector2) -> Dictionary:
	"""这点踩在哪块陆地上？没踩上就返回空字典（M5 用它判断"看得见陆地"）。"""
	return world.land_containing(pos)


func is_reef(pos: Vector2) -> bool:
	return world.is_reef(pos)


func is_port(pos: Vector2) -> bool:
	return world.is_port(pos)


func port_at(pos: Vector2) -> Dictionary:
	return world.port_at(pos)


func current_at(pos: Vector2) -> Vector2:
	return world.current_at(pos)


func lee_factor(pos: Vector2) -> float:
	return world.lee_factor(pos)


func poi_at(pos: Vector2) -> Dictionary:
	return world.poi_at(pos)


# ------------------------------------------------------------ 老接口（视图与剧情还在用）

func port() -> Dictionary:
	var p := world.port()
	if p.is_empty():
		return {}
	var c := Geom2D.centroid(p["shape"])
	return {
		"name": str(p.get("name", "")),
		"pos": [c.x, c.y],
		"radius_m": Geom2D.extent(p["shape"]),
		"faction": str(p.get("faction", "")),
		"text": str(p.get("text", "")),
	}


func ports() -> Array:
	return world.ports()


func port_pos() -> Vector2:
	var p := world.port()
	return Geom2D.centroid(p["shape"]) if not p.is_empty() else Vector2.ZERO


func port_name_of(id: String) -> String:
	for p in world.ports():
		if str(p.get("id", "")) == id:
			return str(p.get("name", id))
	return id


func island() -> Dictionary:
	return world.island()


func primary_land() -> Dictionary:
	return world.primary_land()


func primary_center() -> Vector2:
	var f := world.primary_land()
	return Geom2D.centroid(f["shape"]) if not f.is_empty() else Vector2.ZERO


func primary_radius() -> float:
	var f := world.primary_land()
	return Geom2D.extent(f["shape"]) if not f.is_empty() else 0.0


func dist_to_island_center(pos: Vector2) -> float:
	return pos.distance_to(primary_center())


func pois() -> Array:
	return world.pois()


func poi_pos(id: String) -> Vector2:
	return world.poi_pos(id)


func lands() -> Array:
	return world.lands()


func routes() -> Array:
	return route_list


func route_points(r: Dictionary) -> PackedVector2Array:
	"""一段航线的折线：起点港 → （可选 via 绕行点）→ 终点港。"""
	var out := PackedVector2Array()
	out.append(_port_pos(str(r.get("from", ""))))
	for v in r.get("via_lonlat", []):
		if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
			out.append(world.lonlat_to_m(float(v[0]), float(v[1])))
	for v in r.get("via", []):
		if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
			out.append(Vector2(float(v[0]), float(v[1])))
	out.append(_port_pos(str(r.get("to", ""))))
	return out


func _port_pos(id: String) -> Vector2:
	for p in world.ports():
		if str(p.get("id", "")) == id:
			return Geom2D.centroid(p["shape"])
	return Vector2.ZERO


func land_shapes(dry := true) -> Array:
	return world.land_shapes(dry)


func nearest_shore(pos: Vector2) -> Dictionary:
	return world.nearest_shore(pos)


func describe() -> String:
	return world.describe()
