class_name ShipPath
extends RefCounted

# 船内寻路：在 (层, x, y) 上做 BFS。
#
#   * 能走的格子 = tiles.json 说这格能走 **且** 上面没有挡路的物件（桅杆、木桶、箱子…）
#   * 跨层 = ship.json 里的 links（梯子/舱口），同一个 (x, y) 换一个层
#   * 站位也从数据里推：桅杆旁边的甲板就是操帆位、灶台旁边就是伙房位、
#     `kind == "platform"` 的层就是瞭望台 —— 改船体数据不用改代码（AGENTS.md 铁律 2）

const NEIGHBORS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var ready := false
var _walk := {}          # layer -> Dictionary["x,y": true]
var _cross := {}         # "layer:x,y" -> Array[[layer, x, y], ...]
var _stations := {}      # job -> Array[Vector3i(x, y, layer)]
var _reachable := {}     # "layer:x,y" -> true（从主甲板能走到的格子）
var _hub := Vector3i(-1, -1, -1)
var _platform_layer := 3


func setup(ship_path := "res://data/ships/caravel_60.json",
		tiles_path := "res://data/defs/tiles.json",
		props_path := "res://data/defs/props.json") -> void:
	var ship = JSON.parse_string(FileAccess.get_file_as_string(ship_path))
	var tiles: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(tiles_path))["tiles"]
	var props: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(props_path))["props"]
	if typeof(ship) != TYPE_DICTIONARY:
		push_error("船体数据读不出来：" + ship_path)
		return

	# 1) 每层哪些格子能走
	for l in ship["layers"]:
		var lid := int(l["id"])
		var walk := {}
		var rows: Array = l["tiles"]
		for y in rows.size():
			var row: String = str(rows[y])
			for x in row.length():
				var ch := row.substr(x, 1)
				if tiles.has(ch) and bool(tiles[ch]["walkable"]):
					walk["%d,%d" % [x, y]] = true
		_walk[lid] = walk
		if str(l["kind"]) == "platform":
			_platform_layer = lid

	# 2) 挡路的物件把格子堵上（货堆、木桶、桅杆、铺位、灶台…）
	for p in ship["props"]:
		var def: Dictionary = props.get(str(p["type"]), {})
		if not bool(def.get("blocks", false)):
			continue
		var lid := int(p["layer"])
		if _walk.has(lid):
			_walk[lid].erase("%d,%d" % [int(p["x"]), int(p["y"])])

	# 3) 跨层通道（梯子/舱口）：两个方向都要通
	for link in ship["links"]:
		var a := int(link["from"])
		var b := int(link["to"])
		var x := int(link["x"])
		var y := int(link["y"])
		_connect(a, b, x, y)
		_connect(b, a, x, y)

	# 4) 从数据推出站位
	_stations["sail"] = _merge(_around_prop(ship, "mast", 6), _around_prop(ship, "capstan", 6))
	_stations["repair"] = _around_prop(ship, "windlass", 4)
	_stations["helm"] = _around_prop(ship, "helm", 3)
	_stations["cook"] = _around_prop(ship, "stove", 3)
	_stations["chores"] = _layer_cells(2).filter(func(v): return v.y == 3 and v.x >= 13 and v.x <= 16)
	_stations["lookout"] = _layer_cells(_platform_layer)
	# 睡觉：铺位旁边 + 三个住舱（铺位本身就是挡路的物件，人只能站在旁边）
	_stations["sleep"] = _merge(_around_prop_multi(ship, ["bunk"], 8),
		_merge(_room_cells(ship, "前部铺位"),
			_merge(_room_cells(ship, "中部水手舱"), _room_cells(ship, "后部铺位"))))
	_stations["eat"] = _room_cells(ship, "厨房")
	# 休更（不在班的人）回水手舱待着 —— 真船就是一半人当班一半人休息
	_stations["off_watch"] = _layer_cells(1)

	# 5) 只保留"从主甲板走得到"的站位。
	#    船上有封死的舱（压舱石舱就是——真实帆船也这样），任何派活都不能派进死胡同。
	var mast_side := _around_prop(ship, "mast", 1)
	_hub = mast_side[0] if mast_side.size() > 0 else Vector3i(0, 0, 2)
	_compute_reachable()
	for job in _stations:
		_stations[job] = (_stations[job] as Array).filter(
			func(v): return _reachable.has(_key(v)))
	ready = true


func _compute_reachable() -> void:
	_reachable.clear()
	if not _walkable(_hub.z, _hub.x, _hub.y):
		return
	var frontier: Array = [_hub]
	_reachable[_key(_hub)] = true
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_front()
		for nxt in neighbors(cur):
			var k := _key(nxt)
			if _reachable.has(k):
				continue
			_reachable[k] = true
			frontier.append(nxt)


func reachable_cells(layer: int) -> Array:
	var out := []
	for key in _reachable:
		var parts: PackedStringArray = str(key).split(":")
		if int(parts[0]) != layer:
			continue
		var xy: PackedStringArray = parts[1].split(",")
		out.append(Vector3i(int(xy[0]), int(xy[1]), layer))
	out.sort_custom(func(a, b): return a.x * 100 + a.y < b.x * 100 + b.y)
	return out


func has_reachable(layer: int) -> bool:
	return reachable_cells(layer).size() > 0


func hub() -> Vector3i:
	return _hub


func is_reachable(v: Vector3i) -> bool:
	return _reachable.has(_key(v))


func _connect(from_layer: int, to_layer: int, x: int, y: int) -> void:
	var key := "%d:%d,%d" % [from_layer, x, y]
	if not _cross.has(key):
		_cross[key] = []
	_cross[key].append(Vector3i(x, y, to_layer))


func _walkable(layer: int, x: int, y: int) -> bool:
	if not _walk.has(layer):
		return false
	return _walk[layer].has("%d,%d" % [x, y])


func walkable(layer: int, x: int, y: int) -> bool:
	return _walkable(layer, x, y)


func _layer_cells(layer: int) -> Array:
	var out := []
	if not _walk.has(layer):
		return out
	for key in _walk[layer]:
		var parts: PackedStringArray = str(key).split(",")
		out.append(Vector3i(int(parts[0]), int(parts[1]), layer))
	out.sort_custom(func(a, b): return a.x * 100 + a.y < b.x * 100 + b.y)
	return out


func layer_cells(layer: int) -> Array:
	return _layer_cells(layer)


func _merge(a: Array, b: Array) -> Array:
	var out := a.duplicate()
	for v in b:
		if not out.has(v):
			out.append(v)
	return out


func _around_prop(ship: Dictionary, prop_type: String, limit: int) -> Array:
	var out := []
	for p in ship["props"]:
		if str(p["type"]) != prop_type:
			continue
		var lid := int(p["layer"])
		var px := int(p["x"])
		var py := int(p["y"])
		for d: Vector2i in NEIGHBORS:
			var c := Vector2i(px, py) + d
			if _walkable(lid, c.x, c.y):
				var v := Vector3i(c.x, c.y, lid)
				if not out.has(v):
					out.append(v)
	return out.slice(0, limit) if out.size() > limit else out


func _around_prop_multi(ship: Dictionary, prop_types: Array, limit: int) -> Array:
	var out := []
	for t in prop_types:
		for v in _around_prop(ship, str(t), 8):
			if not out.has(v):
				out.append(v)
	return out.slice(0, limit) if out.size() > limit else out


func _room_cells(ship: Dictionary, room_name: String) -> Array:
	var out := []
	for room in ship["rooms"]:
		if str(room["name"]) != room_name:
			continue
		var lid := int(room["layer"])
		for c in room["cells"]:
			# 房间里的格子可能被物件占着（灶台、箱子），只留真能站的
			if _walkable(lid, int(c[0]), int(c[1])):
				out.append(Vector3i(int(c[0]), int(c[1]), lid))
	return out


func station_cells(job: String) -> Array:
	return _stations.get(job, [])


func neighbors(v: Vector3i) -> Array:
	var out := []
	for d: Vector2i in NEIGHBORS:
		var c := Vector2i(v.x, v.y) + d
		if _walkable(v.z, c.x, c.y):
			out.append(Vector3i(c.x, c.y, v.z))
	var cross: Array = _cross.get("%d:%d,%d" % [v.z, v.x, v.y], [])
	for c in cross:
		out.append(c)
	return out


func find(from: Vector3i, to: Vector3i) -> Array:
	"""BFS 找一条路。返回 [from..to]（含两端），找不到返回空数组。

	格子只有 24×7×4 = 672 个，BFS 便宜到可以每帧给几十个人算。
	"""
	if from == to:
		return [from]
	if not _walkable(from.z, from.x, from.y) or not _walkable(to.z, to.x, to.y):
		return []
	var frontier: Array = [from]
	var came := {_key(from): null}
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_front()
		for nxt in neighbors(cur):
			var k := _key(nxt)
			if came.has(k):
				continue
			came[k] = _key(cur)
			if nxt == to:
				return _rebuild(came, from, to)
			frontier.append(nxt)
	return []


func _rebuild(came: Dictionary, from: Vector3i, to: Vector3i) -> Array:
	var out := [to]
	var cur := to
	while true:
		var prev_key = came.get(_key(cur), null)
		if prev_key == null:
			break
		var parts: PackedStringArray = str(prev_key).split(":")
		var xy: PackedStringArray = parts[1].split(",")
		cur = Vector3i(int(xy[0]), int(xy[1]), int(parts[0]))
		out.push_front(cur)
		if cur == from:
			break
	return out


func _key(v: Vector3i) -> String:
	return "%d:%d,%d" % [v.z, v.x, v.y]


func describe() -> String:
	var parts := PackedStringArray()
	for job in _stations:
		parts.append("%s×%d" % [job, (_stations[job] as Array).size()])
	return "船内寻路：通道 %d 处，站位 %s" % [_cross.size() / 2, ", ".join(parts)]
