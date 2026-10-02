extends SceneTree

# M9 的验收测试：全球海图地基（docs/23 的 M9 卡片、docs/22 第 3 章）。
#
# 五件事：
#   1. **同一坐标在任意 tile 采样结果完全一致** —— M2 立的头号硬指标，扩到 200 块
#      之后仍然要成立。做法不变：关掉索引全量扫描，两边逐字段精确相等。
#   2. **整条环球航线不穿干地** —— 圣卢卡尔 → 加那利 → 佛得角 → 巴西 → 拉普拉塔 →
#      圣胡利安 → 麦哲伦海峡 → 太平洋 → 关岛 → 宿务 → 蒂多雷 → 马六甲 → 印度洋 →
#      莫桑比克 → 好望角 → 亚速尔 → 圣卢卡尔，每 250 米采一次。
#   3. **圆柱**：环球的世界 x 轴是卷起来的 —— 接缝两边必须给出同一片地形，
#      距离要走最短的一边。
#   4. 数据自检：港在水里、地标在地上、十三个港与十三段航段都在。
#   5. 索引的代价：建索引耗时、每个 tile 的候选数、逐点采样耗时（数字写进 docs/23）。
#   6. 老海域（8km 迷你海、48km 大西洋）走的是同一套代码，读数不许变。

const ATLANTIC := "res://data/world/atlantic/geography.json"
const MINI := "res://data/world/test_sea.json"
const GLOBAL := "res://data/world/global/geography.json"
const SAMPLE_M := 250.0

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_globalmap ===")
	_test_world_shape()
	_test_data_selfcheck()
	_test_route_passable()
	_test_tile_index_equivalence()
	_test_cylinder()
	_test_index_cost()
	_test_legacy_unchanged()
	_finish()


func _sea(path := GLOBAL) -> Sea:
	var s := Sea.new()
	s.setup(path)
	return s


# ---------------------------------------------------------------- 1 世界的形状

func _test_world_shape() -> void:
	var s := _sea()
	_check(s.ready, "全球数据读得出来（%s）" % GLOBAL)
	_check(s.size_m() == Vector2(320000, 160000),
		"320km × 160km = 整颗地球（%s）" % str(s.size_m()))
	_check(s.tile_m() == 16000.0, "tile 仍是 16km（%.0f）" % s.tile_m())
	_check(s.tiles() == Vector2i(20, 10), "20×10 = 200 块 tile（%s）" % str(s.tiles()))
	_check(s.wraps(), "全球图是圆柱（wrap_x）")
	_check(s.world.has_projection(), "世界数据声明了投影（能写经纬度）")
	# 六个地区文件真的拼进来了：每个地区各抽一个 id
	var ids := {}
	for f in s.world.features:
		ids[str(f["id"])] = true
	for want in ["iberia", "patagonia_east", "guam", "tidore", "madagascar", "azores"]:
		_check(ids.has(want), "六个地区文件都拼进来了：%s" % want)
	_check(s.ports().size() == 13, "十三个停靠点（%d）" % s.ports().size())
	_check(s.routes().size() == 13, "十三段航段（%d）" % s.routes().size())
	# 海图分区图幅（M9）：八个关键海域，各是一块用米写的矩形
	_check(s.world.regions.size() == 8, "八个分区图幅（%d）" % s.world.regions.size())
	var rg_names := {}
	for rg in s.world.regions:
		rg_names[str(rg.get("id", ""))] = true
		_check((rg.get("rect", Rect2()) as Rect2).size.x > 5000.0,
			"分区 %s 的框有实际大小（%s）" % [str(rg.get("id")), str(rg.get("rect"))])
	for want in ["iberia", "canaries_verde", "brazil", "strait", "pacific", "indies", "indian", "azores"]:
		_check(rg_names.has(want), "分区图幅里有 %s" % want)
	var home_tile := s.tile_of(s.lonlat_to_m(-7.5, 36.4))
	_check(str(s.world.region_of_tile(home_tile).get("id", "")) == "iberia",
		"出发港那一格落在「伊比利亚」分区里（%s）" % str(s.world.region_of_tile(home_tile).get("id", "")))
	_check(float(s.data.get("real_km_per_map_km", 0.0)) == 125.0,
		"压缩系数仍是 125（%.1f）" % float(s.data.get("real_km_per_map_km", 0.0)))


# ---------------------------------------------------------------- 2 数据自检

func _test_data_selfcheck() -> void:
	"""图不能自相矛盾：港在水里、地标在干地上。"""
	var s := _sea()
	var wet_ports := 0
	for p in s.ports():
		if not s.world.is_dry_land(Geom2D.centroid(p["shape"])):
			wet_ports += 1
		else:
			_check(false, "港口不能落在干地上：%s" % str(p.get("name", "?")))
	_check(wet_ports == s.ports().size(), "十三个港都在水里（%d）" % wet_ports)
	var off_land := PackedStringArray()
	for f in s.world.features:
		for poi in f.get("pois", []):
			var pos := Vector2.ZERO
			var raw = poi.get("pos", [])
			if typeof(raw) == TYPE_ARRAY and (raw as Array).size() >= 2:
				pos = Vector2(float(raw[0]), float(raw[1]))
			if bool(poi.get("water", false)) or str(poi.get("id", "")) == "pacific_void":
				continue                      # 这些地标故意在海面上（峡口 / 空旷的海）
			if not s.world.is_land(pos):
				off_land.append(str(poi.get("id", "?")))
	_check(off_land.is_empty(), "地标都落在陆地上（%s）" % ", ".join(off_land))
	# 洋流带不许有退化线段（两个端点重合）—— 画面上的箭头会因此三角化失败
	var bad_current := PackedStringArray()
	for f in s.world.of_kind("current"):
		var pts: PackedVector2Array = f["shape"].get("points", PackedVector2Array())
		if pts.size() < 2:
			bad_current.append(str(f.get("id")) + "（端点不足）")
			continue
		for i in range(pts.size() - 1):
			if pts[i].distance_to(pts[i + 1]) < 1.0:
				bad_current.append("%s[%d]" % [str(f.get("id")), i])
	_check(bad_current.is_empty(), "洋流带没有退化线段（%s）" % ", ".join(bad_current))


# ---------------------------------------------------------------- 3 航段不穿干地

func _test_route_passable() -> void:
	var s := _sea()
	var bad := PackedStringArray()
	var sampled := 0
	for r in s.routes():
		var pts := s.route_points(r)
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			# 接缝那一段要走**最短的一边**（这正是环球时的走法）
			var step := s.delta(a, b)
			var n := maxi(1, int(ceil(step.length() / SAMPLE_M)))
			for k in range(n + 1):
				var p := s.wrap_pos(a + step * (float(k) / float(n)))
				sampled += 1
				if s.world.is_dry_land(p):
					bad.append("%s@%.0f,%.0f" % [str(r.get("id", "?")), p.x, p.y])
	_check(bad.is_empty(), "十三段航段不穿干地（采样 %d 点，%d 处踩到干地：%s）"
		% [sampled, bad.size(), ", ".join(bad.slice(0, 6))])
	_check(sampled > 2000, "航线采样点够密（%d 个）" % sampled)
	# 三条关键水道：海峡口、马六甲口、好望角外海
	_check(not s.world.is_dry_land(s.lonlat_to_m(-71.5, -52.6)), "麦哲伦海峡的水道是通的")
	_check(not s.world.is_dry_land(s.lonlat_to_m(103.0, 0.5)), "马六甲海峡是通的")
	_check(not s.world.is_dry_land(s.lonlat_to_m(28.0, -38.0)), "好望角外海是通的")


# ---------------------------------------------------------------- 4 索引 vs 全扫

func _test_tile_index_equivalence() -> void:
	"""头号硬指标：同一点，索引版与全扫版逐字段相等 —— 在整套环球航线上。"""
	var s := _sea()
	var w := s.world
	var n := 0
	var mismatch := PackedStringArray()
	for r in s.routes():
		var pts := s.route_points(r)
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var step := s.delta(a, b)
			var steps := maxi(1, int(ceil(step.length() / SAMPLE_M)))
			for k in range(steps + 1):
				var p := s.wrap_pos(a + step * (float(k) / float(steps)))
				w.force_full_scan = true
				var full := w.sample(p)
				w.force_full_scan = false
				var idx := w.sample(p)
				n += 1
				if full != idx:
					mismatch.append("%s@%.0f,%.0f" % [str(r.get("id", "?")), p.x, p.y])
	_check(n > 2000, "航线上的采样点够多（%d）" % n)
	_check(mismatch.is_empty(), "索引版与全扫版逐字段相等（%d 处不一致%s）"
		% [mismatch.size(), "" if mismatch.is_empty() else "：" + ", ".join(mismatch.slice(0, 6))])
	# 接缝两侧：同一个物理点的两种写法必须给同一份答案
	var east := s.lonlat_to_m(179.5, 10.0)
	var same := s.lonlat_to_m(-180.5, 10.0)      # 同一个物理点，经度写法差 360°
	_check(s.dist(east, same) < 1.0, "经度差 360° 的两种写法是同一个点（%.1f 米）" % s.dist(east, same))
	_check(w.sample(east) == w.sample(same), "接缝两侧的采样签名一致")
	var one_deg_west := s.lonlat_to_m(-179.5, 10.0)
	_check(absf(s.dist(east, one_deg_west) - 888.9) < 2.0,
		"跨缝 1° 的距离是 889 米（不是 319 公里）：%.0f 米" % s.dist(east, one_deg_west))


# ---------------------------------------------------------------- 5 圆柱

func _test_cylinder() -> void:
	var s := _sea()
	var w := s.world
	var p := s.lonlat_to_m(-30.0, 20.0)
	_check(w.sample(p) == w.sample(p + Vector2(w.world_m.x, 0.0)),
		"x 加一整圈之后是同一个点")
	_check(w.tile_of(p) == w.tile_of(p + Vector2(w.world_m.x, 0.0)), "tile 也跟着卷")
	_check(w.wrap_pos(Vector2(-10.0, 500.0)).x == w.world_m.x - 10.0, "wrap_pos 把负数卷到右边")
	_check(w.wrap_pos(Vector2(w.world_m.x + 25.0, 500.0)).x == 25.0, "wrap_pos 把超出的卷回左边")
	# 距离走最短的一边：a 在缝东 1km，b 在缝西 1km，真实距离是 2km 而不是 318km
	var a := Vector2(1000.0, 80000.0)
	var b := Vector2(w.world_m.x - 1000.0, 80000.0)
	_check(absf(w.dist(a, b) - 2000.0) < 1.0, "跨缝距离走最短的一边（%.0f 米）" % w.dist(a, b))
	_check(w.dist(Vector2(1000.0, 0.0), Vector2(50000.0, 0.0)) == 49000.0, "不跨缝时距离照常")
	# 经纬度回读
	var q := s.lonlat_to_m(127.4, 0.7)
	var back := s.m_to_lonlat(q)
	_check(absf(back.x - 127.4) < 0.01 and absf(back.y - 0.7) < 0.01,
		"经纬度能原样读回来（%.2f,%.2f）" % [back.x, back.y])


# ---------------------------------------------------------------- 6 索引的代价

func _test_index_cost() -> void:
	var t0 := Time.get_ticks_usec()
	var s := _sea()
	var build_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var w := s.world
	# 索引里一共挂了多少条"特征 → tile"的引用（内存的代理指标）
	var refs := 0
	var busiest := 0
	for t in range(w.tiles.x * w.tiles.y):
		var c := (w.features_in_tile(Vector2i(t % w.tiles.x, int(t / w.tiles.x))) as Array).size()
		refs += c
		busiest = maxi(busiest, c)
	print("  全球索引：%d 个特征、%d 块 tile、%d 条引用（平均 %.1f/块，最忙 %d/块）"
		% [w.features.size(), w.tiles.x * w.tiles.y, refs,
		   float(refs) / float(w.tiles.x * w.tiles.y), busiest])
	print("  建索引耗时：%.1f ms（含读文件与投影换算）" % build_ms)
	_check(refs > 0 and refs < w.features.size() * w.tiles.x * w.tiles.y,
		"索引是按影响范围登记的（%d 条引用，远小于全挂的 %d）"
		% [refs, w.features.size() * w.tiles.x * w.tiles.y])
	# 逐点采样耗时：4000 个点，看平均每次查询多少钱
	var pts := []
	for i in range(4000):
		var x := float(i) * w.world_m.x / 4000.0
		var y := 40000.0 + float(i % 97) * 900.0
		pts.append(Vector2(x, y))
	var q0 := Time.get_ticks_usec()
	for p in pts:
		w.sample(p)
	var per_us := float(Time.get_ticks_usec() - q0) / float(pts.size())
	print("  逐点采样（十个查询一起）：平均 %.1f µs/点（%d 点）" % [per_us, pts.size()])
	_check(per_us < 2000.0, "单点采样便宜（%.1f µs）" % per_us)
	# 建索引不该比大西洋那份慢一个数量级（同一套代码，只是数据多）
	var t1 := Time.get_ticks_usec()
	var small := _sea(ATLANTIC)
	var small_ms := float(Time.get_ticks_usec() - t1) / 1000.0
	print("  对照：大西洋（3×3）建索引 %.1f ms" % small_ms)
	_check(build_ms < maxf(200.0, small_ms * 40.0),
		"全球建索引没有爆炸（%.1f ms vs 大西洋 %.1f ms）" % [build_ms, small_ms])


# ---------------------------------------------------------------- 7 老海域不变

func _test_legacy_unchanged() -> void:
	var a := _sea(ATLANTIC)
	_check(a.tiles() == Vector2i(3, 3), "大西洋仍是 3×3（%s）" % str(a.tiles()))
	_check(not a.wraps(), "大西洋不是圆柱（wrap_x 关着）")
	_check(a.ports().size() == 4, "大西洋仍是四港（%d）" % a.ports().size())
	_check(a.routes().size() == 3, "大西洋仍是三段航段（%d）" % a.routes().size())
	_check(a.world.tile_key(a.tile_of(a.port_pos())) == "2,0", "出发港仍在 tile 2,0")
	var m := _sea(MINI)
	_check(m.tiles() == Vector2i(1, 1), "8km 迷你海仍是 1×1（%s）" % str(m.tiles()))
	_check(not m.wraps(), "迷你海不是圆柱")
	_check(m.is_land(m.primary_center()), "迷你海的岛还在")


# ---------------------------------------------------------------- 收尾

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
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
