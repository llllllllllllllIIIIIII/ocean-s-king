class_name Sea
extends RefCounted

# 测试海域：地形查询 + 风与洋流的区域修正。
#
# 它只回答"这个位置是什么情况"：
#   是不是陆地 / 是不是沙滩 / 是不是暗礁 / 这里有没有洋流 / 这里的风被岛挡住了多少
# 怎么用这些答案（撞礁受伤、被流带走、背风区帆软）是 Voyage 的事。

const DATA_PATH := "res://data/world/test_sea.json"

var data := {}
var ready := false


func setup(path := DATA_PATH) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("海域数据读不出来：" + path)
		return
	data = d
	ready = true


func size_m() -> Vector2:
	var s: Array = data.get("size_m", [8000, 8000])
	return Vector2(float(s[0]), float(s[1]))


func in_bounds(pos: Vector2) -> bool:
	return pos.x >= 0.0 and pos.y >= 0.0 and pos.x <= size_m().x and pos.y <= size_m().y


func port() -> Dictionary:
	return data.get("port", {})


func _pos_of(d: Dictionary) -> Vector2:
	# 岛用 "center"，港/礁/地标用 "pos" —— 两种都要认
	var p: Array = d.get("pos", d.get("center", [0, 0]))
	return Vector2(float(p[0]), float(p[1]))


func island() -> Dictionary:
	return data.get("island", {})


func dist_to_island_center(pos: Vector2) -> float:
	return pos.distance_to(_pos_of(island()))


func is_land(pos: Vector2) -> bool:
	"""岛心半径以内都算陆地（沙滩也算陆地）。"""
	return dist_to_island_center(pos) <= float(island().get("radius_m", 0.0))


func is_beach(pos: Vector2) -> bool:
	var r := float(island().get("radius_m", 0.0))
	return is_land(pos) and dist_to_island_center(pos) >= r - float(island().get("beach_width_m", 0.0))


func is_reef(pos: Vector2) -> bool:
	var reef: Dictionary = data.get("reef", {})
	if reef.is_empty():
		return false
	return pos.distance_to(_pos_of(reef)) <= float(reef.get("radius_m", 0.0))


func is_port(pos: Vector2) -> bool:
	return pos.distance_to(_pos_of(port())) <= float(port().get("radius_m", 0.0))


func current_at(pos: Vector2) -> Vector2:
	"""洋流：一条从 from 到 to 的带子，带宽内才有。返回速度矢量（世界系，m/s）。"""
	var c: Dictionary = data.get("current", {})
	if c.is_empty():
		return Vector2.ZERO
	var a: Array = c["from"]
	var b: Array = c["to"]
	var p0 := Vector2(float(a[0]), float(a[1]))
	var p1 := Vector2(float(b[0]), float(b[1]))
	var d := p1 - p0
	var len2 := d.length_squared()
	if len2 <= 0.0:
		return Vector2.ZERO
	var t := clampf((pos - p0).dot(d) / len2, 0.0, 1.0)
	var closest := p0 + d * t
	if pos.distance_to(closest) > float(c.get("width_m", 0.0)) * 0.5:
		return Vector2.ZERO
	return d.normalized() * float(c.get("speed_ms", 0.0))


func lee_factor(pos: Vector2) -> float:
	"""岛的背风区：站在岛的下风侧，风速打折。

	"下风侧" = 从岛心往**风吹去的方向** —— 岛把风挡住了，那一片就软。
	"""
	var isl: Dictionary = island()
	if isl.is_empty():
		return 1.0
	var c := _pos_of(isl)
	var r := float(isl.get("radius_m", 0.0))
	var d := pos - c
	var dist := d.length()
	if dist > r * 3.0 or dist < 1.0:
		return 1.0
	var w: Dictionary = data.get("wind", {})
	var blow_to := deg_to_rad(float(w.get("base_from_deg", 0.0)) + 180.0)
	var downwind := Vector2(cos(blow_to), sin(blow_to))
	# 只有在下风侧（夹角小）才打折，越靠近岛心越明显
	var align := d.normalized().dot(downwind)
	if align <= 0.0:
		return 1.0
	var fade := clampf(1.0 - dist / (r * 2.5), 0.0, 1.0)
	var base := float(w.get("lee_factor", 0.45))
	return lerpf(1.0, base, align * fade)


func poi_at(pos: Vector2) -> Dictionary:
	"""走到哪个地标上了？没走到就返回空字典。"""
	for poi in island().get("pois", []):
		if pos.distance_to(_pos_of(poi)) <= float(poi.get("radius_m", 0.0)):
			return poi
	return {}


func pois() -> Array:
	return island().get("pois", [])


func describe() -> String:
	return "%s：%d×%d 米，一座岛（%d 个地标）、一处暗礁、一条洋流带" % [
		str(data.get("name", "?")), int(size_m().x), int(size_m().y), pois().size()]
