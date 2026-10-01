extends SceneTree

# M2 的验收测试：世界分块 + 大西洋海图（docs/13 的 M2 卡片、docs/15）。
#
# 四件事，按重要性排：
#   1. **同一坐标在任意 tile 采样结果完全一致** —— 这是这一期的头号硬指标。
#      做法不是"多试几个点"，而是把 tile 索引关掉全量扫描，两边**逐字段精确相等**。
#   2. 地形数据自检：港口在水里、地标在陆地上、航段不穿干地（图不能自相矛盾）。
#   3. 海图发现：雾只会散、不会重新聚起来；认得名字的陆地只增不减。
#   4. 日历：儒略历（1519 年）的日期推进。
#   5. 老海域（v0.1 的 8km）走的是同一套代码，读数不许变。

const DT := 0.5
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_worldmap ===")
	_test_atlantic_data()
	_test_data_selfcheck()
	_test_tile_index_equivalence()
	_test_boundary_continuity()
	_test_synthetic_boundary()
	_test_survey_and_fog()
	_test_real_passage()
	_test_calendar()
	_test_legacy_unchanged()
	_finish()


# ---------------------------------------------------------------- 1 大西洋数据

func _sea() -> Sea:
	var s := Sea.new()
	s.setup(GEO)
	return s


func _test_atlantic_data() -> void:
	var s := _sea()
	_check(s.ready, "大西洋数据读得出来（%s）" % GEO)
	_check(s.tile_m() == 16000.0, "tile 是 16km = 2×瞭望视野（%.0f）" % s.tile_m())
	_check(s.tiles() == Vector2i(3, 3), "3×3 个 tile（%s）" % str(s.tiles()))
	_check(s.size_m() == Vector2(48000, 48000), "48km × 48km 的可航区（%s）" % str(s.size_m()))
	var names := []
	for p in s.ports():
		names.append(str(p["name"]))
	for want in ["圣卢卡尔", "圣克鲁斯（加那利）", "圣地亚哥（佛得角）", "圣阿莱克索（巴西）"]:
		_check(names.has(want), "四港之一在图上：%s" % want)
	_check(s.world.of_kind("land").size() == 5,
		"五块陆地（伊比利亚 / 西非 / 加那利 / 绿岬岛 / 巴西）：%d" % s.world.of_kind("land").size())
	_check(s.world.of_kind("reef").size() == 2, "两处暗礁")
	_check(s.world.of_kind("current").size() == 2, "两条洋流")
	_check(s.routes().size() == 3, "三段建议航段（%d）" % s.routes().size())
	var isl := s.island()
	_check(str(isl["name"]) == "绿岬岛", "主岛是绿岬岛（%s）" % str(isl["name"]))
	_check(s.pois().size() == 4, "主岛有 4 个地标（%d）" % s.pois().size())
	# 主场景开局那一格：圣卢卡尔在东北角那一块
	_check(s.world.tile_key(s.tile_of(s.port_pos())) == "2,0",
		"出发港在 tile 2,0（%s）" % s.world.tile_key(s.tile_of(s.port_pos())))


# ---------------------------------------------------------------- 2 数据自检

func _test_data_selfcheck() -> void:
	"""图不能自相矛盾：港得在水里、地标得在陆地上、航段得真的开得过去。"""
	var s := _sea()
	var bad_water := PackedStringArray()
	var bad_harbor := PackedStringArray()
	for p in s.ports():
		var pos := Geom2D.centroid(p["shape"])
		if s.is_land(pos):
			bad_water.append(str(p["name"]))
		if _nearest_land_surface(s, pos) > 3000.0:
			bad_harbor.append(str(p["name"]))
	_check(bad_water.is_empty(), "四个港都不在陆地上（有问题的：%s）" % _list(bad_water))
	_check(bad_harbor.is_empty(), "四个港都紧挨着岸（离岸超过 3km 的：%s）" % _list(bad_harbor))

	var bad_poi := PackedStringArray()
	for poi in s.pois():
		var pos := Vector2(float(poi["pos"][0]), float(poi["pos"][1]))
		if not s.is_land(pos):
			bad_poi.append(str(poi["id"]))
	_check(bad_poi.is_empty(), "四个地标都在陆地上（有问题的：%s）" % _list(bad_poi))
	_check(s.is_beach(Vector2(21800, 26500)), "滩头落在沙滩环上")
	_check(s.is_dry_land(Vector2(23500, 25700)) and s.is_dry_land(Vector2(23900, 26800)),
		"遗迹与溪流在岛内（干地）")

	var blocked := PackedStringArray()
	var samples := 0
	for r in s.routes():
		var pts := s.route_points(r)
		if pts.size() < 2:
			blocked.append(str(r["id"]) + "（端点找不到）")
			continue
		for pos in _along(pts, 250.0):
			samples += 1
			if s.is_dry_land(pos):
				blocked.append("%s@%.0f,%.0f" % [str(r["id"]), pos.x, pos.y])
	_check(blocked.is_empty(),
		"%d 个航段采样点都不穿干地（撞上的：%s）" % [samples, _list(blocked)])
	# 一路有礁、有流、有背风区 —— 航段不是画在空海上的
	var hazards := 0
	for r in s.routes():
		for pos in _along(s.route_points(r), 500.0):
			if s.current_at(pos).length() > 0.1 or s.lee_factor(pos) < 0.99:
				hazards += 1
	_check(hazards >= 10, "航线上真的会遇到洋流或背风区（%d 个采样点）" % hazards)


func _along(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	"""沿着折线每隔 step 米取一个点（含首尾）。"""
	var out := PackedVector2Array()
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var n := maxi(1, int(a.distance_to(b) / step))
		for j in range(n):
			out.append(a.lerp(b, float(j) / float(n)))
	out.append(pts[-1])
	return out


func _nearest_land_surface(s: Sea, pos: Vector2) -> float:
	var best := INF
	for f in s.lands():
		best = minf(best, Geom2D.surface_dist(f["shape"], pos))
	return best


# ---------------------------------------------------------------- 3 头号硬指标

func _test_tile_index_equivalence() -> void:
	"""把 tile 索引关掉全量扫描，两边必须**逐字段精确相等**。

	这是"同一坐标在任意 tile 采样结果一致"的可执行版本：
	索引只决定"算哪些候选"，不该改变任何一个答案。
	"""
	var s := _sea()
	var w := s.world
	var mism := PackedStringArray()
	var n := 0
	var step := 700.0
	var y := 0.0
	while y <= w.world_m.y:
		var x := 0.0
		while x <= w.world_m.x:
			var pos := Vector2(x, y)
			n += 1
			var diff := _sample_diff(w, pos)
			if diff != "":
				mism.append("(%.0f,%.0f)：%s" % [x, y, diff])
			x += step
		y += step
	_check(mism.is_empty(),
		"全图 %d 个采样点：索引版与全扫版逐字段相等（不一致 %d 处：%s）" % [
			n, mism.size(), _list(mism.slice(0, 3))])

	# 索引完整性：一个形状碰到的每个 tile 里都必须有它
	var missing := 0
	for f in w.features:
		# 按**影响范围**核对（背风区在岸外，光看外形会漏）
		var box := w.influence_aabb(f)
		for ty in w.tiles.y:
			for tx in w.tiles.x:
				var t := Vector2i(tx, ty)
				if not box.intersects(w.tile_rect(t)):
					continue
				if not w.features_in_tile(t).has(f):
					missing += 1
	_check(missing == 0, "每个形状都登记进了它碰到的每一个 tile（漏 %d 处）" % missing)

	# 跨块的形状确实存在：不然上面那条断言是空转的
	var spans := []
	for id in ["iberia", "africa", "brazil", "guinea_current", "canary_current"]:
		for f in w.features:
			if str(f["id"]) == id:
				spans.append("%s→%d 块" % [id, w.tiles_of_feature(f).size()])
	_check(spans.size() == 5 and not spans[0].ends_with("1 块"),
		"跨块形状（%s）" % ", ".join(spans))


func _sample_diff(w: WorldMap, pos: Vector2) -> String:
	w.force_full_scan = false
	var a := w.sample(pos)
	w.force_full_scan = true
	var b := w.sample(pos)
	w.force_full_scan = false
	for k in a.keys():
		if typeof(a[k]) == TYPE_FLOAT:
			if a[k] != b[k]:
				return "%s: %s != %s" % [k, str(a[k]), str(b[k])]
		elif str(a[k]) != str(b[k]):
			return "%s: %s != %s" % [k, str(a[k]), str(b[k])]
	return ""


# ---------------------------------------------------------------- 4 缝上不许有断口

func _test_boundary_continuity() -> void:
	"""贴着缝取一圈点：缝两边都不许"看不见对面那块里的地形"。"""
	var s := _sea()
	var w := s.world
	var mism := PackedStringArray()
	var n := 0
	var offsets := [-3000.0, -800.0, -60.0, -1.0, 0.0, 1.0, 60.0, 800.0, 3000.0]
	for b in [16000.0, 32000.0]:
		var along := 0.0
		while along <= 48000.0:
			for o in offsets:
				n += 1
				var px := Vector2(b + o, along)
				var py := Vector2(along, b + o)
				for pos in [px, py]:
					var diff := _sample_diff(w, pos)
					if diff != "":
						mism.append("(%.0f,%.0f)：%s" % [pos.x, pos.y, diff])
			along += 500.0
	_check(mism.is_empty(),
		"缝上 %d 个点：跨块采样与全扫一致（不一致 %d 处：%s）" % [
			n, mism.size(), _list(mism.slice(0, 3))])

	# 两条洋流是真的**横跨** tile 缝的：缝两边都摸得到它
	var x := 16000.0
	var on_seam := Vector2(16000.0 - 2.0, 30714.0)     # 几内亚洋流穿过 x=16000 的位置
	var on_seam2 := Vector2(16000.0 + 2.0, 30714.0)
	_check(s.current_at(on_seam).length() > 0.1 and s.current_at(on_seam2).length() > 0.1,
		"洋流横跨 x=16000 的缝：两边都有流速（%.2f / %.2f m/s）" % [
			s.current_at(on_seam).length(), s.current_at(on_seam2).length()])
	_check(s.current_at(on_seam).distance_to(s.current_at(on_seam2)) < 0.5,
		"缝两边的流速几乎一样（差 %.4f）" % s.current_at(on_seam).distance_to(s.current_at(on_seam2)))
	# 缝的另一侧不该凭空多出陆地
	_check(s.is_land(Vector2(15998.0, 30714.0)) == s.is_land(Vector2(16002.0, 30714.0)),
		"缝上不会凭空冒出陆地")
	_check(not s.is_land(Vector2(15998.0, 30714.0)), "那里本来就没陆地")


func _test_synthetic_boundary() -> void:
	"""人造小世界：一条**压着缝**的岸 + 一条横穿全图的流。

	"按形状中心归块"这类索引一定会在这里露馅：岸的中心在 tile 1，
	于是在 tile 0 里查不到它。
	"""
	var d := {
		"name": "合成海域", "tile_m": 1000, "world_m": [2000, 1000],
		"wind": { "base_tws_ms": 8.0, "base_from_deg": 0.0, "lee_factor": 0.4 },
		"features": [
			{ "id": "wall", "kind": "land", "name": "压缝的岸",
			  "points": [[950, 200], [1050, 800]], "half_width_m": 120, "beach_width_m": 30 },
			{ "id": "stream", "kind": "current", "name": "横穿的流",
			  "points": [[100, 900], [1900, 100]], "width_m": 200, "speed_ms": 1.0 },
		],
	}
	var s := Sea.new()
	s.setup_data(d)
	_check(s.tiles() == Vector2i(2, 1), "合成海域是 2 个 tile（%s）" % str(s.tiles()))
	_check(s.world.tiles_of_feature(_feature(s, "wall")).size() == 2,
		"压缝的岸登记进了两个 tile")
	_check(s.is_land(Vector2(900, 500)), "缝左边也看得见这条岸（按中心归块会在这里漏）")
	_check(s.is_land(Vector2(1100, 500)), "缝右边看得见这条岸")
	_check(not s.is_land(Vector2(850, 500)), "离岸远一点就是水")
	_check(s.is_beach(Vector2(900, 500)) or s.is_dry_land(Vector2(900, 500)),
		"缝左边的岸有自己的沙滩/干地判定")
	# 岸与两个采样点关于缝对称 -> 缝两边的判定必须一模一样（这就是"不跳变"）
	_check(s.is_beach(Vector2(900, 500)) == s.is_beach(Vector2(1100, 500))
		and s.is_dry_land(Vector2(900, 500)) == s.is_dry_land(Vector2(1100, 500)),
		"缝两边对称的点判定一致，没有跳变")
	# 流的中心线穿过 x=1000 的缝：两边各取中心线上的一点
	_check(s.current_at(Vector2(900, 545)).length() > 0.5, "流在缝左边也摸得到")
	_check(s.current_at(Vector2(1100, 456)).length() > 0.5, "流在缝右边也摸得到")
	var mism := 0
	for pos in [Vector2(900, 500), Vector2(1100, 500), Vector2(1000, 500),
			Vector2(1500, 300), Vector2(500, 700), Vector2(1999, 999)]:
		if _sample_diff(s.world, pos) != "":
			mism += 1
	_check(mism == 0, "合成海域里索引版与全扫版也一致（%d 处不一致）" % mism)


func _feature(s: Sea, id: String) -> Dictionary:
	for f in s.world.features:
		if str(f["id"]) == id:
			return f
	return {}


# ---------------------------------------------------------------- 5 海图与雾

func _test_survey_and_fog() -> void:
	var v := Voyage.new()
	v.setup(GEO)
	# 这一段测的是"航线本身不用蹭滩"：把天气按成晴天，免得风暴磨损混进来
	# （风暴会真的造成船体损伤是 M7 的事，另外有断言）
	v.weather.force("clear", 9999.0)
	_check(v.total_tiles() == 9, "海图上 9 个分块（%d）" % v.total_tiles())
	_check(v.discovered_tiles() >= 1 and v.discovered_tiles() <= 4,
		"开局只亮了身边那几块（%d / 9）" % v.discovered_tiles())
	_check(v.is_tile_discovered(v.sea.tile_of(v.ship.position_m())), "出发港那一块是亮的")
	_check(not v.is_tile_discovered(Vector2i(0, 2)), "巴西那一角开局还在雾里")
	_check(v.known_places.has("iberia"), "出发港旁边的陆地认得名字")
	_check(not v.known_places.has("green_cape"), "绿岬岛还没被发现")

	var before := v.discovered.duplicate()
	var start := v.discovered_tiles()
	# 从东北角开到中部偏南（这一段路上会跨两块）
	v.ship.set_pose(Vector2(30000, 20000), 180.0)
	for _i in 8:
		v.tick(DT)
	_check(v.discovered_tiles() > start, "开出去以后发现的块变多了（%d → %d）" % [
		start, v.discovered_tiles()])
	_check(v.is_tile_discovered(Vector2i(1, 1)), "船所在的那一块亮了")
	var lost := 0
	for k in before.keys():
		if not v.discovered.has(k):
			lost += 1
	_check(lost == 0, "雾只会散不会重新聚起来（丢了 %d 块）" % lost)

	# 靠近绿岬岛：名字进地图
	v.ship.set_pose(Vector2(23000, 24000), 180.0)
	for _i in 8:
		v.tick(DT)
	_check(v.known_places.has("green_cape"), "走到跟前就认得绿岬岛了")
	_check(not v.known_places.has("brazil"), "没去过的陆地还是没名字")

	# 存档：发现记录也要跟着走（房主权威的那一块，docs/14）
	var b := Voyage.new()
	b.setup(GEO)
	b.apply_world_state(v.capture_world_state())
	_check(b.discovered_tiles() == v.discovered_tiles(),
		"读档后发现的块数一致（%d）" % b.discovered_tiles())
	_check(b.known_places.size() == v.known_places.size(), "读档后认得的陆地一致")


# ---------------------------------------------------------------- 6 日历

func _test_real_passage() -> void:
	"""真航程：从外海一路开进滩头 —— 这不是摆过去，是航海官真的把船开过去的。

	它同时证明两件事：第二幕的触发距离（2500m）在路上一定经过，
	以及这条航线**不必蹭滩**就能进入登陆距离（不然玩家一设目标点就先掉 6% 船体）。
	"""
	var v := Voyage.new()
	v.setup(GEO)
	v.ship.set_pose(Vector2(29000, 22500), 200.0)
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(Vector2(21800, 26500))     # 滩头
	var reach := false
	var secs := 0.0
	while secs < 6000.0:
		v.tick(DT)
		secs += DT
		if v.can_land():
			reach = true
			break
	_check(reach, "从外海真的开进了登陆距离（%.0f 秒游戏时间，离岸 %.0f 米）" % [
		secs, float(v.sea.nearest_shore(v.ship.position_m())["distance_m"])])
	# 低于一次蹭滩（6%）就说明这条路线上没有被 ashore 挡住过；
	# （M7 起天气与事件也会造成损伤，所以不写成"必须等于 0"）
	_check(v.ship.damage_of("hull") < 0.06,
		"这条航线不用蹭滩（船体损伤 %.0f%%，低于一次蹭滩的 6%%）" % (
			v.ship.damage_of("hull") * 100.0))
	_check(v.fired.has("lookout") and v.island_known,
		"路上瞭望员报告了陆地 —— 第二幕在这条航线上会落下来")
	# 上岸也真的走得通
	var msg := v.land(["piloto"], 6)
	_check(v.ashore, "按 L 能带人上岸（%s）" % msg)
	v.move_party_to(Vector2(23500, 25700))
	for _i in int(300.0 / DT):
		v.tick(DT)
	_check(v.visited.has("ruins"), "上岸后走得到内陆遗迹")
	_check(v.party.count_ashore() > 5, "岸上是一支真的队伍（%d 人）" % v.party.count_ashore())


# ---------------------------------------------------------------- 6 日历

func _test_calendar() -> void:
	# 纯函数的检查用 1:1 的尺度（日期换算本身与压缩系数无关）
	VoyageJournal.voyage_time_scale = 1.0
	_check(VoyageJournal.date_of(0.0) == "1519-09-20", "第一天是 1519-09-20")
	_check(VoyageJournal.clock_of_day(0.0) == "00:00", "零点（%s）" % VoyageJournal.clock_of_day(0.0))
	_check(VoyageJournal.clock_of_day(7.0 * 3600.0 + 5.0 * 60.0) == "07:05", "当天时刻")
	_check(VoyageJournal.date_of(86400.0) == "1519-09-21", "过一天（%s）" % VoyageJournal.date_of(86400.0))
	_check(VoyageJournal.date_of(11.0 * 86400.0) == "1519-10-01",
		"跨月（%s）" % VoyageJournal.date_of(11.0 * 86400.0))
	_check(VoyageJournal.date_of(161.0 * 86400.0) == "1520-02-28",
		"跨年（%s）" % VoyageJournal.date_of(161.0 * 86400.0))
	_check(VoyageJournal.date_of(163.0 * 86400.0) == "1520-03-01",
		"儒略历 1520 是闰年，二月有 29 天（%s）" % VoyageJournal.date_of(163.0 * 86400.0))
	_check(VoyageJournal.date_cn(0.0) == "1519 年 9 月 20 日", "中文日期（%s）" % VoyageJournal.date_cn(0.0))

	var v := Voyage.new()
	v.setup(GEO)
	_check(v.date_string() == "1519-09-20" and v.day == 0, "一局从 1519-09-20 开始")
	_check(VoyageJournal.voyage_time_scale == 125.0,
		"大西洋是压缩过的：日历按真实航程翻页（×%.0f）" % VoyageJournal.voyage_time_scale)
	var leg := v.voyage_days_for(
		v.sea.port_pos().distance_to(Vector2(36000, 12800)))
	_check(leg > 4.0 and leg < 6.0,
		"圣卢卡尔→加那利 ≈ %.1f 个航程日（图上 8.5km × 125 = 1059 真实公里）" % leg)
	for _i in int(200.0 / DT):
		v.tick(DT)
	_check(v.clock_string() == VoyageJournal.clock_of_day(v.t), "时钟跟着游戏时间走（%s）" % v.clock_string())
	# 把时间推过午夜（×125 之下的午夜 = 691.2 游戏秒）：日期要翻页，day 要加一
	v.t = 86400.0 / VoyageJournal.voyage_time_scale - 60.0
	for _i in int(120.0 / DT):
		v.tick(DT)
	_check(v.date_string() == "1519-09-21", "跨过午夜就翻页（%s）" % v.date_string())
	_check(v.day == 1, "day 跟着翻（%d）" % v.day)
	VoyageJournal.voyage_time_scale = 1.0


# ---------------------------------------------------------------- 7 老海域不退化

func _test_legacy_unchanged() -> void:
	"""v0.1 的 8km 海域走的是同一套 WorldMap 代码，读数必须一个不差。"""
	var s := Sea.new()
	s.setup()
	_check(s.ready and s.tiles() == Vector2i(1, 1), "迷你海域仍然是 1 个 tile")
	_check(s.size_m() == Vector2(8000, 8000), "还是 8km × 8km")
	_check(s.is_land(Vector2(5600, 3600)) and not s.is_beach(Vector2(5600, 3600)),
		"岛心是干地不是沙滩")
	_check(s.is_beach(Vector2(4790, 3600)), "滩头还是沙滩")
	_check(s.is_reef(Vector2(3400, 2050)), "暗礁还在")
	_check(s.is_port(Vector2(700, 4000)), "出发港还在")
	_check(s.current_at(Vector2(2750, 2000)).length() > 0.5, "洋流还在")
	var up := s.lee_factor(Vector2(6600, 2800))
	var down := s.lee_factor(Vector2(4700, 4400))
	_check(down < up - 0.1, "背风区还是软的（上风 %.2f vs 下风 %.2f）" % [up, down])
	var mism := 0
	for pos in [Vector2(5600, 3600), Vector2(4790, 3600), Vector2(3400, 2050),
			Vector2(700, 4000), Vector2(2750, 2000), Vector2(6600, 2800)]:
		if _sample_diff(s.world, pos) != "":
			mism += 1
	_check(mism == 0, "迷你海域也是索引版 = 全扫版（%d 处不一致）" % mism)


# ---------------------------------------------------------------- 断言框架

func _list(a) -> String:
	return "无" if a.is_empty() else ", ".join(a)


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] " + msg)
	else:
		_fails.append(msg)
		print("  [FAIL] " + msg)


func _finish() -> void:
	var ms := Time.get_ticks_msec() - _t0
	if _fails.is_empty():
		print("全部通过：%d 项断言，耗时 %.0f ms" % [_checks, ms])
		quit(0)
	else:
		print("失败 %d / %d 项：" % [_fails.size(), _checks])
		for f in _fails:
			print("  - " + f)
		quit(1)
