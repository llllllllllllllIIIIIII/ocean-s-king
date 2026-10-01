class_name ShipRenderer
extends Node2D

# 船的渲染器：读 ship.json + SVG 部件，把某一层画出来。
#
# 分层观察的规则（docs/01 支柱 5）：
#   * 船体轮廓 / 甲板 / 舷墙是"整船"部件，四层共用（因为外形同源）
#   * 上面一层的半透明虚影给出层间高度感
#   * 队员/物件只画当前层

const CELL := 40.0                 # 1 格 = 40 逻辑像素（摄像机再缩放）
const SVG_PER_CELL := 100.0        # 1 格 = 100 SVG 单位
const GHOST_ALPHA := 0.13
const SAIL_ALPHA := 0.50           # 俯视下帆保持半透明，甲板始终可读

var ship: Dictionary
var tiles: Dictionary
var prop_defs: Dictionary
var layers: Dictionary = {}        # id -> layer dict
var bank: SvgBank

var layer := 2
var zoom := 1.0
var sail_main_rad := -0.45         # 主帆弦线方向（**画布系**弧度）
var sail_jib_rad := -0.75          # 前帆弦线方向（画布系弧度）
# 帆的形态：0 全帆 / 1 缩帆 / 2 收帆。三种形态是**三个不同的 SVG 部件**，
# 不是把同一张图缩一缩 —— 缩帆要看得见少了多少帆布，收帆要看得见卷在桁上。
var sail_state := 0
var anchored := false              # 抛锚中：船首前面会画锚链与锚
var crew_dots: Array = []          # 当前层的船员 [{x, y, color, key}]
var show_grid := false
var show_ghost := true

# 姿态：船在世界里的位置（米）与航向（度）。由 ShipDynamics 的快照驱动。
var pose_pos_m := Vector2.ZERO
var pose_heading_deg := 180.0


func setup(ship_path := "res://data/ships/caravel_60.json") -> void:
	ship = JSON.parse_string(FileAccess.get_file_as_string(ship_path))
	tiles = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/defs/tiles.json"))["tiles"]
	prop_defs = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/defs/props.json"))["props"]
	bank = SvgBank.new()
	for l in ship["layers"]:
		# JSON 的数字会解析成 float，字典键必须显式转 int
		layers[int(l["id"])] = l


func world_ppu() -> float:
	"""每个 SVG 单位占多少世界像素。固定值——缩放由摄像机负责。"""
	return CELL / SVG_PER_CELL


func raster_ppu() -> float:
	"""每个 SVG 单位在屏幕上占多少像素。只用来挑栅格化倍率。"""
	return CELL * zoom / SVG_PER_CELL


func layer_name(lid: int) -> String:
	return str(layers[lid]["name"])


func layer_elevation(lid: int) -> float:
	return float(layers[lid]["elevation_m"])


# ------------------------------------------------------------------ 姿态

func apply_pose(pos_m: Vector2, heading_deg: float) -> void:
	"""把船摆到世界坐标 pos_m（米）、航向 heading_deg（度）。

	画布里 x=0 是船首（画布 +x 指向船尾）、y=0 是左舷（画布 +y 是右舷），
	而世界系按 AGENTS.md 铁律 7 是 +x 船首、+y 右舷。两者差一个 x 反号，
	所以"画布 -> 世界"= 先翻转 x，再按航向旋转。
	"""
	pose_pos_m = pos_m
	pose_heading_deg = heading_deg
	var h := deg_to_rad(heading_deg)
	var c := cos(h)
	var s := sin(h)
	var x_axis := Vector2(-c, -s)          # 画布 +x（船尾方向）在世界里的指向
	var y_axis := Vector2(-s, c)           # 画布 +y（右舷方向）在世界里的指向
	var local_origin := _cell_center(_mast_cell())
	var origin := pos_m * CELL - (x_axis * local_origin.x + y_axis * local_origin.y)
	transform = Transform2D(x_axis, y_axis, origin)


func hull_center_world_px() -> Vector2:
	"""船体几何中心在世界里的像素坐标（摄像机用它对准船）。"""
	var cx := float(ship["hull"]["cells_x"]) * CELL * 0.5
	var cy := float(ship["hull"]["cells_y"]) * CELL * 0.5
	return transform * Vector2(cx, cy)


func world_px_to_ship(p: Vector2) -> Vector2:
	"""世界像素 -> 画布像素（鼠标点目标点时会用到）。"""
	return transform.affine_inverse() * p


func _mast_cell() -> Vector2i:
	return Vector2i(int(ship["hull"]["origin_cell"][0]), int(ship["hull"]["origin_cell"][1]))


# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	_draw_sea()
	_draw_layer(layer, 1.0, Vector2.ZERO, false)
	if show_ghost:
		var above := _layer_above(layer)
		if above >= 0:
			var dz: float = absf(layer_elevation(above) - layer_elevation(layer))
			# 高度差越大，虚影偏移越多 —— 这是"层叠"的视觉暗示
			_draw_layer(above, GHOST_ALPHA, Vector2(-2.0, -3.0) * (dz / 2.0), true)
	_draw_anchor_rig()
	_draw_crew()
	if show_grid:
		_draw_grid()


func _draw_crew() -> void:
	"""把当前层的船员画成小圆点：关键船员大一圈、带深色描边。

	这是"12 名关键船员 vs 28 名普通船员"在画面上最直观的差别 ——
	一眼就能认出那个是水手长、那个是刚上船的侍童。
	"""
	for dot in crew_dots:
		var at := _cell_center(Vector2i(int(dot["x"]), int(dot["y"])))
		var col: Color = dot["color"]
		if bool(dot.get("key", false)):
			draw_circle(at, CELL * 0.21, Color(0.05, 0.07, 0.09, 0.85))
			draw_circle(at, CELL * 0.17, col)
		else:
			draw_circle(at, CELL * 0.13, col)


func _draw_anchor_rig() -> void:
	"""抛锚：从船首伸出一条绷直的锚链，末端是落底的锚与两圈涟漪。

	俯视图里"锚在水下"本来看不见，但玩家需要一眼知道船为什么不动 ——
	所以把链和锚画在水面之上，用颜色和涟漪说明它沉在下面。
	"""
	if not anchored:
		return
	var bow := _cell_center(Vector2i(1, 3))
	var tip := bow + Vector2(-2.6 * CELL, 0.7 * CELL)
	var chain := Color(0.36, 0.38, 0.44)
	draw_line(bow, tip, chain, 5.0)
	# 链环：沿着链均匀点几节，比一根实线更像链
	var steps := 7
	for i in range(1, steps):
		var p := bow.lerp(tip, float(i) / float(steps))
		draw_circle(p, 4.0, Color(0.22, 0.24, 0.28))
	# 锚本体（部件坐标系里锚是竖着画的，转过来让它躺在链的末端）
	var wu := world_ppu()
	var ru := raster_ppu()
	if not bank.draw_part(self, "anchor_icon", tip, PI * 0.42, wu, ru,
			Color(1, 1, 1, 0.95)):
		draw_circle(tip, 10.0, chain)
	# 涟漪：两道圈说明它落在水底
	draw_arc(tip, 30.0, 0.0, TAU, 28, Color(0.6, 0.85, 1.0, 0.22), 2.0)
	draw_arc(tip, 46.0, 0.0, TAU, 32, Color(0.6, 0.85, 1.0, 0.13), 2.0)


func _draw_sea() -> void:
	# 海面是**世界**里的东西，不能跟着船转。所以先把这个节点的姿态变换抵消掉，
	# 在世界像素坐标里画一张够大的网，再切回局部坐标画船 —— 船转弯时海面纹丝不动，
	# 玩家才能从网格的移动看出船真的在走。
	draw_set_transform_matrix(transform.affine_inverse())
	var cam_pos: Vector2 = get_viewport().get_canvas_transform().affine_inverse() \
		* (get_viewport_rect().size * 0.5)
	var half := Vector2(6000.0, 6000.0)
	draw_rect(Rect2(cam_pos - half, half * 2.0), Color("#0d1b26"), true)
	var step := CELL * 5.0                       # 网格线每 5 米一条
	var x := floorf((cam_pos.x - half.x) / step) * step
	while x < cam_pos.x + half.x:
		draw_line(Vector2(x, cam_pos.y - half.y), Vector2(x, cam_pos.y + half.y),
			Color(1, 1, 1, 0.03), 1.0)
		x += step
	var y := floorf((cam_pos.y - half.y) / step) * step
	while y < cam_pos.y + half.y:
		draw_line(Vector2(cam_pos.x - half.x, y), Vector2(cam_pos.x + half.x, y),
			Color(1, 1, 1, 0.03), 1.0)
		y += step
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_layer(lid: int, alpha: float, offset: Vector2, is_ghost: bool) -> void:
	var ldef: Dictionary = layers[lid]
	var kind := str(ldef["kind"])
	var tint := Color(1, 1, 1, alpha)
	var wu := world_ppu()
	var ru := raster_ppu()

	bank.draw_part(self, "hull_outline", offset, 0.0, wu, ru, tint)
	if kind == "deck":
		bank.draw_part(self, "deck_planks", offset, 0.0, wu, ru, tint)
		bank.draw_part(self, "deck_bulwark", offset, 0.0, wu, ru, tint)
	else:
		bank.draw_part(self, "interior_floor", offset, 0.0, wu, ru, tint)
		_draw_rooms(lid, alpha, offset)

	for prop in ship["props"]:
		if int(prop["layer"]) == lid:
			_draw_prop(prop, alpha, offset)

	for link in ship["links"]:
		if int(link["from"]) == lid or int(link["to"]) == lid:
			_draw_link(link, alpha, offset)

	# 虚影不画桅装：帆面积大，半透明叠加后是一条斜带，只会干扰读数
	if kind == "deck" and not is_ghost:
		_draw_rig(alpha, offset)


func _draw_rig(alpha: float, offset: Vector2) -> void:
	var at := _cell_center(_mast_cell()) + offset
	var tint := Color(1, 1, 1, alpha)
	var wu := world_ppu()
	var ru := raster_ppu()
	# 先帆后桁再桅杆：桅杆压在最上面，帆从桁下张开
	# 帆要半透明：它物理上确实在甲板之上、会挡住甲板，
	# 但纯俯视视角下必须能看见甲板，否则玩家读不出船的状态。
	var sail_tint := Color(1, 1, 1, alpha * SAIL_ALPHA)
	bank.draw_part(self, _sail_part("sail_main", sail_state), at, sail_main_rad, wu, ru, sail_tint)
	bank.draw_part(self, _sail_part("sail_jib", sail_state), at, sail_jib_rad, wu, ru,
		Color(1, 1, 1, alpha * SAIL_ALPHA * 0.86))
	bank.draw_part(self, "yard", at, sail_main_rad, wu, ru, tint)
	bank.draw_part(self, "mast", at, 0.0, wu, ru, tint)


func _sail_part(base: String, state: int) -> String:
	match state:
		1: return base + "_reefed"
		2: return base + "_furled"
	return base


func _draw_prop(prop: Dictionary, alpha: float, offset: Vector2) -> void:
	var t := str(prop["type"])
	var d: Dictionary = prop_defs.get(t, {})
	var at := _cell_center(Vector2i(int(prop["x"]), int(prop["y"]))) + offset
	var tint := Color(1, 1, 1, alpha)
	var part := str(d.get("part", ""))
	if part != "" and bank.draw_part(self, part, at, 0.0, world_ppu(), raster_ppu(), tint):
		return
	# 没有配 SVG 部件的（主要是舱内小物件）先用简单图形
	var col := Color(str(d.get("color", "#ffffff")))
	col.a = alpha
	if str(d.get("shape", "rect")) == "circle":
		draw_circle(at, CELL * 0.30, col)
		draw_arc(at, CELL * 0.30, 0.0, TAU, 20, Color(0, 0, 0, 0.45 * alpha), 2.0)
	else:
		var r := Rect2(at - Vector2(CELL * 0.28, CELL * 0.28),
			Vector2(CELL * 0.56, CELL * 0.56))
		draw_rect(r, col, true)
		draw_rect(r, Color(0, 0, 0, 0.45 * alpha), false, 2.0)


func _draw_link(link: Dictionary, alpha: float, offset: Vector2) -> void:
	var at := _cell_center(Vector2i(int(link["x"]), int(link["y"]))) + offset
	var part := "ladder" if str(link["type"]) == "ladder" else "hatch"
	bank.draw_part(self, part, at, 0.0, world_ppu(), raster_ppu(), Color(1, 1, 1, alpha))


func _draw_rooms(lid: int, alpha: float, offset: Vector2) -> void:
	for room in ship["rooms"]:
		if int(room["layer"]) != lid:
			continue
		var minp := Vector2(1e9, 1e9)
		var maxp := Vector2(-1e9, -1e9)
		for c in room["cells"]:
			var p := Vector2(float(c[0]) * CELL, float(c[1]) * CELL) + offset
			minp = minp.min(p)
			maxp = maxp.max(p + Vector2(CELL, CELL))
		var r := Rect2(minp, maxp - minp)
		draw_rect(r, Color(0.25, 0.72, 1.0, 0.09 * alpha), true)
		draw_rect(r, Color(0.45, 0.85, 1.0, 0.45 * alpha), false, 2.0)


func room_at(lid: int) -> Array:
	var out := []
	for room in ship["rooms"]:
		if int(room["layer"]) == lid:
			out.append(room)
	return out


func _draw_grid() -> void:
	var nx: int = ship["hull"]["cells_x"]
	var ny: int = ship["hull"]["cells_y"]
	var c := Color(1, 1, 1, 0.10)
	for x in nx + 1:
		draw_line(Vector2(x * CELL, 0), Vector2(x * CELL, ny * CELL), c, 1.0)
	for y in ny + 1:
		draw_line(Vector2(0, y * CELL), Vector2(nx * CELL, y * CELL), c, 1.0)


func _cell_center(c: Vector2i) -> Vector2:
	return Vector2((float(c.x) + 0.5) * CELL, (float(c.y) + 0.5) * CELL)


func _layer_above(lid: int) -> int:
	match lid:
		0: return 1
		1: return 2
		2: return 3
	return -1
