# 船体数据校验器（docs/05 第 11 节）。
#
# ship.json 是生成的 / 手调的，出错时往往表现为"某个船员莫名其妙不动了"
# 这种极难排查的现象。所以任何不符合结构约束的数据都必须在这里大声失败。
#
# 用法：
#   D:\Godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . ^
#       --script res://tests/validate_ship.gd
#
# 退出码 0 = 全部通过；1 = 有错误。
extends SceneTree

const SHIP_PATH := "res://data/ships/caravel_60.json"
const TILES_PATH := "res://data/defs/tiles.json"
const PROPS_PATH := "res://data/defs/props.json"
const TOP_LAYER := 2      # 从主甲板开始做可达性检查
const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var _errors: PackedStringArray = []
var _checks := 0


func _initialize() -> void:
	print("=== validate_ship ===")

	var ship := _load_json(SHIP_PATH)
	var tile_defs := _load_json(TILES_PATH)
	var prop_defs := _load_json(PROPS_PATH)
	if ship.is_empty() or tile_defs.is_empty() or prop_defs.is_empty():
		_finish()
		return

	var tiles: Dictionary = tile_defs["tiles"]
	var props: Dictionary = prop_defs["props"]
	var cx: int = ship["hull"]["cells_x"]
	var cy: int = ship["hull"]["cells_y"]

	var layers := _index_layers(ship, cx, cy, tiles)
	_check_links(ship, layers, tiles)
	_check_rooms(ship, layers, tiles)
	_check_props(ship, layers, tiles, props)
	_check_rig(ship)
	_check_reachability(ship, layers)

	_finish()


# ---------------------------------------------------------------- 各项检查

func _index_layers(ship: Dictionary, cx: int, cy: int, tiles: Dictionary) -> Dictionary:
	# 返回 {layer_id: {"grid": Array[String], "def": Dictionary}}
	var out := {}
	for layer in ship["layers"]:
		var lid: int = layer["id"]
		var rows: Array = layer["tiles"]
		_check(rows.size() == cy,
			"L%d 行数 = %d，应为 cells_y = %d" % [lid, rows.size(), cy])
		var bad_len := []
		for y in rows.size():
			if (rows[y] as String).length() != cx:
				bad_len.append(y)
		_check(bad_len.is_empty(),
			"L%d 第 %s 行长度不等于 cells_x = %d" % [lid, str(bad_len), cx])

		# 每个字符都必须在 tiles.json 里有定义
		var unknown := {}
		for y in rows.size():
			var row: String = rows[y]
			for x in row.length():
				var ch := row[x]
				if not tiles.has(ch):
					unknown[ch] = true
		_check(unknown.is_empty(),
			"L%d 出现未定义的格子字符：%s" % [lid, str(unknown.keys())])

		out[lid] = {"grid": rows, "def": layer}
	return out


func _check_links(ship: Dictionary, layers: Dictionary, tiles: Dictionary) -> void:
	_check(not (ship["links"] as Array).is_empty(), "没有任何层间通道")
	for link in ship["links"]:
		var lid_from: int = link["from"]
		var lid_to: int = link["to"]
		var pos := Vector2i(link["x"], link["y"])
		var ok := true
		for lid in [lid_from, lid_to]:
			if not layers.has(lid):
				_check(false, "通道 %s 引用了不存在的层 L%d" % [str(pos), lid])
				ok = false
				continue
			if not _walkable(layers[lid]["grid"], pos, tiles):
				_check(false, "通道 %s 在 L%d 上落在不可走的格子上" % [str(pos), lid])
				ok = false
		if ok:
			_checks += 1


func _check_rooms(ship: Dictionary, layers: Dictionary, tiles: Dictionary) -> void:
	var used := {}     # "lid:x:y" -> room_id
	for room in ship["rooms"]:
		var lid: int = room["layer"]
		var rid: String = room["id"]
		_check(layers.has(lid), "房间 %s 引用了不存在的层 L%d" % [rid, lid])
		if not layers.has(lid):
			continue
		for cell in room["cells"]:
			var pos := Vector2i(cell[0], cell[1])
			var key := "%d:%d:%d" % [lid, pos.x, pos.y]
			_check(not used.has(key),
				"房间 %s 与 %s 在 L%d %s 重叠" % [rid, used.get(key, ""), lid, str(pos)])
			used[key] = rid
			_check(_walkable(layers[lid]["grid"], pos, tiles),
				"房间 %s 的格子 %s 在 L%d 上不可走" % [rid, str(pos), lid])


func _check_props(ship: Dictionary, layers: Dictionary, tiles: Dictionary,
		prop_defs: Dictionary) -> void:
	var used := {}
	for prop in ship["props"]:
		var ptype: String = prop["type"]
		var lid: int = prop["layer"]
		var pos := Vector2i(prop["x"], prop["y"])
		_check(prop_defs.has(ptype), "未定义的物件类型：%s" % ptype)
		if not layers.has(lid):
			_check(false, "物件 %s 引用了不存在的层 L%d" % [ptype, lid])
			continue
		_check(_tile_defined(layers[lid]["grid"], pos, tiles),
			"物件 %s 在 L%d %s 超出格子范围" % [ptype, lid, str(pos)])

		# 两个 blocking 物件不能抢同一格
		var blocks: bool = prop_defs.get(ptype, {}).get("blocks", true)
		var key := "%d:%d:%d" % [lid, pos.x, pos.y]
		if blocks and used.has(key):
			_check(false, "物件 %s 与 %s 抢同一格 L%d %s" % [ptype, used[key], lid, str(pos)])
		elif blocks:
			used[key] = ptype


func _check_rig(ship: Dictionary) -> void:
	var rig: Dictionary = ship.get("rig", {})
	var masts: Array = rig.get("masts", [])
	_check(not masts.is_empty(), "rig 里没有桅杆")
	for mast in masts:
		var sails: Array = mast.get("sails", [])
		_check(not sails.is_empty(), "桅杆 %s 没有帆" % mast.get("id", "?"))
		for sail in sails:
			_check(float(sail.get("area_m2", 0)) > 0.0,
				"帆 %s 的面积必须大于 0" % sail.get("id", "?"))


func _check_reachability(ship: Dictionary, layers: Dictionary) -> void:
	# 从主甲板原点做 BFS，走通所有可走格 + 所有通道。
	# 只要能走到的格子数 = 全部可走格子数，说明没有孤立区域。
	var tiles: Dictionary = _load_json(TILES_PATH)["tiles"]
	var origin: Array = ship["hull"]["origin_cell"]
	var start := Vector3i(origin[0], origin[1], TOP_LAYER)

	var links_at := {}      # "lid:x:y" -> [对方层]
	for link in ship["links"]:
		var a := "%d:%d:%d" % [link["from"], link["x"], link["y"]]
		var b := "%d:%d:%d" % [link["to"], link["x"], link["y"]]
		links_at.get_or_add(a, []).append(link["to"])
		links_at.get_or_add(b, []).append(link["from"])

	var visited := {}
	var queue: Array[Vector3i] = [start]
	visited["%d:%d:%d" % [start.z, start.x, start.y]] = true

	while not queue.is_empty():
		var n: Vector3i = queue.pop_back()
		# 同层四邻接
		for d in NEIGHBORS:
			var p: Vector2i = Vector2i(n.x, n.y) + d
			var v := Vector3i(p.x, p.y, n.z)
			var k := "%d:%d:%d" % [v.z, v.x, v.y]
			if visited.has(k):
				continue
			if layers.has(v.z) and _walkable(layers[v.z]["grid"], Vector2i(v.x, v.y), tiles):
				visited[k] = true
				queue.append(v)
		# 跨层
		for other in links_at.get("%d:%d:%d" % [n.z, n.x, n.y], []):
			var k2 := "%d:%d:%d" % [other, n.x, n.y]
			if not visited.has(k2):
				visited[k2] = true
				queue.append(Vector3i(n.x, n.y, other))

	var total := 0
	for lid in layers:
		for y in (layers[lid]["grid"] as Array).size():
			var row: String = layers[lid]["grid"][y]
			for x in row.length():
				if tiles[row[x]]["walkable"]:
					total += 1

	_check(visited.size() == total,
		"可达性不足：可走格子 %d 个，从主甲板只能走到 %d 个（有孤立区域）"
		% [total, visited.size()])
	print("  可走格子 %d 个，全部可达" % total)


# ------------------------------------------------------------------ 工具

func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_errors.append(msg)


func _tile_at(grid: Array, pos: Vector2i) -> String:
	if pos.y < 0 or pos.y >= grid.size():
		return ""
	var row: String = grid[pos.y]
	if pos.x < 0 or pos.x >= row.length():
		return ""
	return row[pos.x]


func _tile_defined(grid: Array, pos: Vector2i, tiles: Dictionary) -> bool:
	var ch := _tile_at(grid, pos)
	return ch != "" and tiles.has(ch)


func _walkable(grid: Array, pos: Vector2i, tiles: Dictionary) -> bool:
	var ch := _tile_at(grid, pos)
	return ch != "" and tiles.has(ch) and bool(tiles[ch]["walkable"])


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		_check(false, "找不到文件：%s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_check(false, "%s 不是合法的 JSON 对象" % path)
		return {}
	return parsed


func _finish() -> void:
	if _errors.is_empty():
		print("=== OK：%d 项检查全部通过 ===" % _checks)
		quit(0)
	else:
		print("=== 失败：%d 项检查中有 %d 个错误 ===" % [_checks, _errors.size()])
		for e in _errors:
			print("  x  " + e)
		quit(1)
