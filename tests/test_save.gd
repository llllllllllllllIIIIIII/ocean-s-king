extends SceneTree

# M1 的验收测试：状态分层 + 存档（docs/13 M1 卡片、docs/14）。
#
# 三条线：
#   1. **字段覆盖**：用 get_property_list() 取出每个参与存档的类的脚本变量，
#      和序列化出来的键对比 —— 少一个就报错。这是存档系统不腐化的唯一保障。
#   2. **往返一致**：存 → 读 → 离散状态精确相等、连续状态在容差内。
#   3. **继续跑**：读档后的世界和原世界各跑 300 秒，仍然一致。
#
# 浮点口径见 docs/14 §4.3：Godot 的 JSON 存 double 会掉到 15 位有效数字，
# 所以离散量要求精确、连续量用容差。

const DT := 0.5
const SLOT := "test_roundtrip"
const STAGE_SLOT := "test_stage"
const SCENE := "res://scenes/sea_debug.tscn"
# 阶段扫描跑的是**主场景那个大西洋世界**（48km / 四港），不是 8km 的回归海域
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0
var _scene
var _frame := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_save ===")
	_test_field_coverage()
	_test_roundtrip()
	_test_continue_after_load()
	_test_file_io_and_rejection()
	_test_ai_route_roundtrip()
	_test_stage_roundtrips()
	# 场景那一半要等引擎推过一帧（_ready() 还没跑时场景内部是空的）
	_scene = load(SCENE).instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 3:
		return false
	_test_scene_wiring()
	_finish()
	return true


func _voyage() -> Voyage:
	var v := Voyage.new()
	v.setup()
	return v


func _run(v: Voyage, seconds: float) -> void:
	for _i in int(seconds / DT):
		v.tick(DT)


# ---------------------------------------------------------------- 1 字段覆盖

func _test_field_coverage() -> void:
	"""谁的字段谁负责：每个类 capture_state() 的键必须覆盖它的脚本变量。

	豁免名单 = 静态数据（从 JSON 读进来的表）、纯派生量、明确的瞬时量。
	每一条豁免都在对应脚本的注释里写了理由，这里只列名字。
	"""
	var v := _voyage()
	_run(v, 30.0)          # 让各对象都有点状态（不是空字典）
	var pairs := [
		["Story", v.story, v.story.capture_state(),
			["ready", "title", "subtitle", "opening_heading", "opening_body",
			 "opening_hint", "acts", "steps", "messages"]],
		["VoyageJournal", v.journal, v.journal.capture_state(), []],
		# WindField.season_shift_deg / season_gain 是 M13 的**派生量**：
		# 每帧由 Climate 按"当前纬度 + 日历"算出来灌进去，读档后自然重算 → 不进存档。
		["WindField", v.wind, v.wind.capture_state(), ["season_shift_deg", "season_gain"]],
		["ShipDynamics", v.ship, v.ship.capture_state(),
			# land_shapes 是 M2 加进来的**静态世界数据**（海岸/岛的纯数据形状表），
			# 和 land_center/land_radius 一样由 setup() 重新灌，不进存档。
			# wrap_width 是 M12 加进来的**静态世界数据**（圆柱世界的宽度，
			# 读档时由 Voyage.setup() 按当前海域重新灌）—— 同上。
			["physics", "land_center", "land_radius", "land_shapes", "wrap_width",
			 "last_blocked", "_last"]],
		["ShipOrders", v.orders, v.orders.capture_state(), []],
		# Navigator.wrap_width：同上，静态世界数据（圆柱世界的宽度）
		# shore_distance_m / shore_bearing_deg / blocked：M13 避岸规则的**每帧派生输入**
		# （由 Voyage.tick() 现算现灌），不进存档。
		["Navigator", v.nav, v.nav.capture_state(),
			["orders", "wrap_width", "shore_distance_m", "shore_bearing_deg", "blocked"]],
		["Crew", v.crew, v.crew.capture_state(),
			["ship", "roster", "_tw", "_ta", "_alpha_grid"]],
		["CrewRoster", v.roster, v.roster.capture_state(),
			# fatigue_mult / mood_bias 是 M5 的规则每帧灌进来的派生量，不进存档；
			# _hand_prio 是 M14 从 crew_12.json 读进来的静态数据（招人时抄给新水手）
			["jobs", "needs", "path", "ready", "_grumble_pool", "fatigue_mult", "mood_bias",
			 "_hand_prio"]],
		["CrewMember", v.roster.members[0], v.roster.members[0].capture_state(),
			["id_hash", "is_key", "display_name", "post", "post_es",
			 "traits", "relations", "skills"]],
		["LandingParty", v.party, v.party.capture_state(), []],
		["Cargo", v.cargo, v.cargo.capture_state(),
			# defs 是资源表、capacity_kg 来自船的数据 —— 都是静态的，读档时重新加载
			["defs", "capacity_kg"]],
		["Ports", v.ports, v.ports.capture_state(),
			# 港口表与基准库存是静态的，只有"现在还剩多少"会变
			["defs", "base_stock"]],
		["Rules", v.rules, v.rules.capture_state(), ["defs"]],
		["Society", v.society, v.society.capture_state(),
			# pending 是"这一帧要弹的事件"，每帧被取走，属于瞬时量
			["pending"]],
		# dynamic 是 M17 的**临时卡**（叛乱处置，回答完就清）：它不进存档，
		# 读档后由 `society.mutiny_open` 重新摆一张。
		["Dilemma", v.dilemmas, v.dilemmas.capture_state(), ["defs", "dynamic"]],
		["Culture", v.culture, v.culture.capture_state(), []],
	]
	for p in pairs:
		var label := str(p[0])
		var obj = p[1]
		var dumped: Dictionary = p[2]
		var exempt: Array = p[3]
		var missing := PackedStringArray()
		for name in StateIO.script_vars(obj):
			if not dumped.has(name) and not exempt.has(name):
				missing.append(name)
		_check(missing.is_empty(),
			"%s 的每个可存字段都有归宿（漏了：%s）" % [
				label, "无" if missing.is_empty() else ", ".join(missing)])

	# 顶层容器的字段清单要和契约一致
	var world := v.capture_world_state()
	var shipst := v.capture_ship_state()
	_check(_same_keys(world, WorldState.FIELDS), "WorldState.FIELDS 与 capture_world_state() 一致")
	_check(_same_keys(shipst, ShipState.FIELDS), "ShipState.FIELDS 与 capture_ship_state() 一致")


func _same_keys(d: Dictionary, fields: Array) -> bool:
	for f in fields:
		if not d.has(str(f)):
			return false
	return d.size() == fields.size()


# ---------------------------------------------------------------- 2 往返一致

func _test_roundtrip() -> void:
	var a := _voyage()
	a.orders.set_target_point(Vector2(4790, 3600))
	_run(a, 300.0)
	a.ship.apply_damage("hull", 0.28)
	a.ship.apply_damage("rudder", 0.10)
	a.orders.set_sail_level(ShipOrders.SailLevel.REEF)
	_run(a, 60.0)

	var b := _voyage()
	b.apply_world_state(a.capture_world_state())
	b.apply_ship_state(a.capture_ship_state())

	# 离散状态：精确相等
	_check(b.t == a.t, "时间一致（%.1f 秒）" % a.t)
	_check(b.story.head == a.story.head, "剧情演到同一幕（第 %d 幕）" % (a.story.head + 1))
	_check(str(b.story.steps) == str(a.story.steps), "教学进度一致")
	_check(str(b.fired.keys()) == str(a.fired.keys()),
		"事件旗标一致（%d 个）" % a.fired.size())
	_check(str(b.visited.keys()) == str(a.visited.keys()), "到过的地标一致")
	_check(b.orders.sail_level == a.orders.sail_level, "帆档一致（%s）" % a.orders.sail_level_name())
	_check(b.orders.has_target_point == a.orders.has_target_point, "目标点有无一致")
	_check(str(b.journal.decisions) == str(a.journal.decisions),
		"航海日志的决定一致（%d 条）" % a.journal.decisions.size())
	for part in ["hull", "mast", "rudder"]:
		_check(is_equal_approx(b.ship.damage_of(part), a.ship.damage_of(part)),
			"损伤 %s 一致（%.0f%%）" % [part, a.ship.damage_of(part) * 100.0])
	# 船员：逐人的格子、岗位、上岸标记必须一模一样（这些是离散量）
	var crew_diff := 0
	for i in a.roster.members.size():
		var ma: CrewMember = a.roster.members[i]
		var mb: CrewMember = b.roster.members[i]
		if ma.at != mb.at or ma.job != mb.job or ma.ashore != mb.ashore or ma.id != mb.id:
			crew_diff += 1
	_check(crew_diff == 0, "40 名船员的格子/岗位/上岸标记逐人一致（%d 人不一致）" % crew_diff)
	_check(str(a.roster.job_counts()) == str(b.roster.job_counts()),
		"全船岗位分布一致（%s）" % a.roster.describe())

	# 连续状态：容差（JSON 存 double 会掉精度）
	var dpos := b.ship.position_m().distance_to(a.ship.position_m())
	var dhead := absf(ShipPhysics.normalize180(b.ship.heading_deg() - a.ship.heading_deg()))
	_check(dpos < 0.001, "船位一致（差 %s 米）" % str(dpos))
	_check(dhead < 1e-6, "艏向一致（差 %s 度）" % str(dhead))
	_check(absf(b.ship.speed_ms() - a.ship.speed_ms()) < 1e-6,
		"船速一致（差 %s m/s）" % str(absf(b.ship.speed_ms() - a.ship.speed_ms())))


# ---------------------------------------------------------------- 3 继续跑

func _test_continue_after_load() -> void:
	var a := _voyage()
	a.orders.set_target_point(Vector2(4790, 3600))
	_run(a, 600.0)
	var b := _voyage()
	b.apply_world_state(a.capture_world_state())
	b.apply_ship_state(a.capture_ship_state())
	_run(a, 300.0)
	_run(b, 300.0)
	# 又跑了 5 分钟：剧情、损伤、帆档必须还在同一条线上
	_check(b.story.head == a.story.head, "再跑 300 秒后仍演在同一幕（第 %d 幕）" % (a.story.head + 1))
	_check(str(b.fired.keys()) == str(a.fired.keys()),
		"再跑 300 秒后事件旗标仍一致（%d 个）" % a.fired.size())
	_check(b.orders.sail_level == a.orders.sail_level, "再跑 300 秒后帆档仍一致")
	_check(str(a.roster.job_counts()) == str(b.roster.job_counts()),
		"再跑 300 秒后岗位分布仍一致（%s）" % a.roster.describe())
	var dpos := b.ship.position_m().distance_to(a.ship.position_m())
	var dhead := absf(ShipPhysics.normalize180(b.ship.heading_deg() - a.ship.heading_deg()))
	var dspd := absf(b.ship.speed_kn() - a.ship.speed_kn())
	_check(dpos < 2.0, "再跑 300 秒后船位仍在 2 米内（差 %.4f 米）" % dpos)
	_check(dhead < 0.5, "再跑 300 秒后艏向仍在 0.5° 内（差 %.5f°）" % dhead)
	_check(dspd < 0.05, "再跑 300 秒后船速仍在 0.05 节内（差 %.5f 节）" % dspd)


# ---------------------------------------------------------------- 4 文件与拒绝

func _test_file_io_and_rejection() -> void:
	var a := _voyage()
	a.orders.set_target_point(Vector2(3600, 3600))
	_run(a, 120.0)
	var r := SaveGame.save_game(a, SLOT)
	_check(bool(r.get("ok", false)), "写存档成功（%s，%d 字节）" % [
		str(r.get("path", "")), int(r.get("bytes", 0))])
	_check(SaveGame.has_slot(SLOT), "存档槽位能被列出来")
	_check(SaveGame.list_slots().has(SLOT), "list_slots() 里有 %s" % SLOT)

	var b := _voyage()
	var r2 := SaveGame.load_into(b, SLOT)
	_check(bool(r2.get("ok", false)), "读存档成功")
	_check(absf(b.t - a.t) < 1e-6, "读回来的时间与存的时候一致（%.1f 秒）" % b.t)
	_check(b.ship.position_m().distance_to(a.ship.position_m()) < 0.001,
		"读回来的船位与存的时候一致")

	# 版本不符 → 拒绝，而且说人话
	_write_raw("badver", '{"version": 99, "world": {}, "ships": [{}]}')
	var r3 := SaveGame.load_into(_voyage(), "badver")
	_check(not bool(r3.get("ok", true)), "版本不符的存档被拒绝")
	_check(str(r3.get("reason", "")).find("v99") >= 0,
		"拒绝理由说得清版本（%s）" % str(r3.get("reason", "")))
	# 坏 JSON → 拒绝
	_write_raw("broken", "这不是 JSON")
	var r4 := SaveGame.load_into(_voyage(), "broken")
	_check(not bool(r4.get("ok", true)), "损坏的存档被拒绝")
	# 不存在的槽位 → 拒绝
	var r5 := SaveGame.load_into(_voyage(), "no_such_slot_at_all")
	_check(not bool(r5.get("ok", true)), "不存在的槽位被拒绝")

	# 收尾：把测试写的槽位删掉，别污染 user://
	for slot in [SLOT, "badver", "broken"]:
		var p := ProjectSettings.globalize_path(SaveGame.slot_path(slot))
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _write_raw(slot: String, text: String) -> void:
	SaveGame.ensure_dir()
	var f := FileAccess.open(SaveGame.slot_path(slot), FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---------------------------------------------------------------- 4.5 AI 船的航点

func _test_ai_route_roundtrip() -> void:
	"""AI 船的航点必须能过一遍 JSON。

	为什么单独拎出来测：`Vector2` 不是 JSON 类型，`JSON.stringify()` 会把它写成
	字符串 `"(3000, 1200)"`。读档回来 `waypoints[0]` 就成了 String，而
	`AbstractShip.step()` 第一件事就是 `target = waypoints[0]`（target 是 Vector2）
	—— 当场 "Trying to assign value of type 'String' to a variable of type 'Vector2'",
	而且**每帧刷一次**，三条 AI 船全停在原地。实测踩过一次（M8 收尾）。
	"""
	var a := _voyage()
	_run(a, 60.0)
	var ai: AbstractShip = null
	for s in a.fleet.slots:
		if str(s.get("kind", "")) == Fleet.KIND_AI and s.get("ship") != null:
			ai = s["ship"]
			break
	_check(ai != null, "单机世界里带着 AI 船（船队 = 1 条细化 + 3 条 AI）")
	if ai == null:
		return
	# 挂一串**确定的**航点（不依赖海图数据，免得换了海域这条测试就悬空）
	ai.waypoints = [ai.pos + Vector2(3000.0, 0.0), ai.pos + Vector2(6000.0, 2000.0)]
	ai.has_target = true

	var r := SaveGame.save_game(a, "test_ai_route")
	_check(bool(r.get("ok", false)), "带着航点写存档成功（%d 字节）" % int(r.get("bytes", 0)))
	var b := _voyage()
	var r2 := SaveGame.load_into(b, "test_ai_route")
	_check(bool(r2.get("ok", false)), "带着航点读存档成功")

	var got: AbstractShip = null
	for s in b.fleet.slots:
		if str(s.get("kind", "")) == Fleet.KIND_AI and s.get("ship") != null:
			got = s["ship"]
			break
	_check(got != null, "读档后 AI 船还在")
	if got == null:
		return
	_check(got.waypoints.size() == 2, "读档后航点个数没丢（%d 个）" % got.waypoints.size())
	var bad := 0
	for p in got.waypoints:
		if typeof(p) != TYPE_VECTOR2:
			bad += 1
	_check(bad == 0, "读档后每个航点都是 Vector2（坏点 %d 个 —— 字符串就是那个 bug）" % bad)
	# 真正的复现点：step() 的第一句就是 target = waypoints[0]
	got.step(DT, b.sea)
	if got.waypoints.size() > 0 and typeof(got.waypoints[0]) == TYPE_VECTOR2:
		var w0: Vector2 = got.waypoints[0]
		_check(got.target.distance_to(w0) < 0.001,
			"step() 把航点接上了目标（差 %.4f 米）" % got.target.distance_to(w0))

	var p := ProjectSettings.globalize_path(SaveGame.slot_path("test_ai_route"))
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


# ---------------------------------------------------------------- 4.6 阶段扫描

func _test_stage_roundtrips() -> void:
	"""在**五个阶段**各存一次读一次。

	为什么单独扫一遍：M8 收尾那个真 bug（AI 航点被 JSON 写成字符串）只在"读档之后"发作，
	而当时所有断言都在存/读的当口就结束了，`test_save` 的退出码还是 0。
	只看"存的时候对不对"不够 —— 要按游戏进程一段一段验。
	"""
	var v := Voyage.new()
	v.setup(GEO)
	_run(v, 120.0)
	_stage_roundtrip(v, "A 刚出海")

	# B 跟着航线走：这一段专门验 M8 收尾新加的 following_route / route_waypoints
	v.start_route_follow()
	_run(v, 300.0)
	var b := _stage_roundtrip(v, "B 沿航线走")
	_check(b != null and b.following_route,
		"「沿航线走」这个开关活过了存档（不然读档回来船开到下一段就停）")
	if b != null:
		_check(b.route_waypoints.size() == v.route_waypoints.size(),
			"剩下的航点也活过了存档（%d 段）" % b.route_waypoints.size())

	# C 靠港 / 买卖
	var port := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "santa_cruz":
			port = Geom2D.centroid(p["shape"])
	v.stop_route_follow()
	v.ship.set_pose(port, 180.0)
	v.orders.anchored = true
	var money_before := v.cargo.money
	v.dock()
	var bought := v.port_buy("water", 3)
	_check(bool(bought.get("ok", false)), "在加那利买到了淡水（%s）" % str(bought.get("reason", "")))
	var c := _stage_roundtrip(v, "C 靠港 / 买卖")
	if c != null:
		_check(c.docked_port == v.docked_port, "靠港的状态活过了存档（%s）" % c.docked_port)
		_check(c.cargo.money == money_before - int(bought.get("cost", 0)),
			"买完水的钱数也活过了存档（%d）" % c.cargo.money)

	# D 上岸打一仗：**战斗中不许存档**（战斗不在存档契约里，明说比静默丢好）
	var spot := _landing_spot(v, port)
	_check(spot != Vector2.ZERO, "在加那利外海找得到一个能上岸的浅水点")
	if spot != Vector2.ZERO:
		v.undock()
		v.ship.set_pose(spot, 180.0)
		v.orders.anchored = true
		var ids := []
		for m in v.landing_candidates():
			ids.append(m.id)
		v.land(ids, 6)
		_check(v.ashore, "船长带人上岸了（%d 个人）" % v.party_size())
		var br := v.begin_land_battle(8, "clear")
		_check(bool(br.get("ok", false)), "打起来了（%s）" % str(br.get("reason", "")))
		var refused := SaveGame.save_game(v, STAGE_SLOT)
		_check(not bool(refused.get("ok", true)), "战斗中存档被拒绝，不是静默丢东西")
		_check(str(refused.get("reason", "")).find("打完") >= 0,
			"拒绝的理由说得清（%s）" % str(refused.get("reason", "")))
		var bt := 0.0
		while v.battle != null and not v.battle.over and bt < 3600.0:
			v.tick(DT)
			bt += DT
		_check(v.battle != null and v.battle.over, "这一仗打完了（%.0f 游戏秒）" % bt)
		_run(v, 60.0)
		var d := _stage_roundtrip(v, "D 打完仗 / 人在岸上")
		if d != null:
			_check(d.party_size() == v.party_size(),
				"岸上那队人活过了存档（%d 个）" % d.party_size())

	# E 风暴 + 事件
	v.weather.force("storm", 24.0)
	v.events.try_fire("storm_wreck", v)
	_run(v, 300.0)
	var e := _stage_roundtrip(v, "E 风暴 / 事件")
	if e != null:
		_check(e.weather.state_id == v.weather.state_id,
			"天气活过了存档（%s）" % e.weather.state_id)

	var path := ProjectSettings.globalize_path(SaveGame.slot_path(STAGE_SLOT))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _landing_spot(v: Voyage, near: Vector2) -> Vector2:
	"""从 `near` 往外扫 500 米一格的网格，挑一个"不是干地、离岸 380 米以内"的点。"""
	for gx in range(-40, 41):
		for gy in range(-40, 41):
			var p := near + Vector2(float(gx) * 500.0, float(gy) * 500.0)
			if v.sea.is_dry_land(p):
				continue
			if float(v.sea.nearest_shore(p)["distance_m"]) < 380.0:
				return p
	return Vector2.ZERO


func _stage_snapshot(v: Voyage) -> Dictionary:
	"""阶段扫描要比的量：跨阶段都拿得到、而且"读档后必须一样"的那些。"""
	return {
		"t": v.t,
		"day": v.day,
		"docked": v.docked_port,
		"ashore": v.ashore,
		"party": v.party_size(),
		"money": v.cargo.money,
		"head": v.story.head,
		"sail": int(v.orders.sail_level),
		"anchored": v.orders.anchored,
		"pos": v.ship.position_m(),
		"heading": v.ship.heading_deg(),
		"crew": v.crew_on_board(),
		"tiles": v.discovered_tiles(),
		"know": v.knowledge.count(),
		"weather": v.weather.state_id,
		"following_route": v.following_route,
	}


func _stage_roundtrip(v: Voyage, label: String) -> Voyage:
	"""存 → 读 → 比关键量 → 让读回来的世界再跑 2 分钟游戏时间。"""
	var before := _stage_snapshot(v)
	var r := SaveGame.save_game(v, STAGE_SLOT)
	_check(bool(r.get("ok", false)), "%s：存得下去（%s）" % [label, str(r.get("reason", ""))])
	if not bool(r.get("ok", false)):
		return null
	var b := Voyage.new()
	b.setup(GEO)
	var r2 := SaveGame.load_into(b, STAGE_SLOT)
	_check(bool(r2.get("ok", false)), "%s：读得回来（%s）" % [label, str(r2.get("reason", ""))])
	if not bool(r2.get("ok", false)):
		return null
	var after := _stage_snapshot(b)
	var diff := PackedStringArray()
	for k in before.keys():
		var a = before[k]
		var c = after[k]
		if typeof(a) == TYPE_VECTOR2:
			if (a as Vector2).distance_to(c) > 0.05:
				diff.append("%s %s→%s" % [str(k), str(a), str(c)])
		elif typeof(a) == TYPE_FLOAT:
			if absf(float(a) - float(c)) > 0.005:
				diff.append("%s %.3f→%.3f" % [str(k), float(a), float(c)])
		elif a != c:
			diff.append("%s %s→%s" % [str(k), str(a), str(c)])
	_check(diff.is_empty(), "%s：存/读后 %d 个关键量一致%s" % [
		label, before.size(), "" if diff.is_empty() else "（不一致：%s）" % ", ".join(diff)])
	_run(b, 120.0)
	return b


func _key(scene, code: int) -> void:
	"""构造真实按键喂给场景（沿用 test_ship_debug_logic 的做法：可复现、不依赖真实输入）。"""
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	scene._unhandled_input(e)


# ---------------------------------------------------------------- 5 场景接线

func _test_scene_wiring() -> void:
	"""真正的 F5 / F9 走的是场景里的那两个键，不是 Voyage 的方法。

	这一节专门验"键 → SaveGame → Voyage"这条线接对了没有（逻辑对但没接线，
	是这类功能最常见的失败方式）。
	"""
	var sc = _scene
	_check(sc.voyage != null, "场景起来了，voyage 存在")
	# M3 起开场先摆**房间界面**（单机 / 开房间 / 加入），按 1 = 单机出海
	_check(sc._room != null and sc._room.visible, "开局先摆房间界面")
	_key(sc, KEY_1)
	_check(not sc._room.visible, "选了单机，房间界面收起")
	# 然后是开场标题卡：任何键都会把它收起来（这是设计，不是 bug）
	_check(sc._title.visible, "开局标题卡是摊开的")
	_key(sc, KEY_F1)
	_check(not sc._title.visible, "按了一下键，标题卡收起、游戏开始")

	# 直接把模拟推进 120 秒（这里验的是存档接线，不是帧循环）
	for _i in 240:
		sc.voyage.tick(DT)
	var t_saved: float = sc.voyage.t
	var pos_saved: Vector2 = sc.voyage.ship.position_m()
	_key(sc, KEY_F5)
	_check(str(sc.voyage.last_message).find("存档") >= 0,
		"按 F5 之后界面收到了存档消息（%s）" % sc.voyage.last_message)
	_check(SaveGame.has_slot("auto"), "F5 真的写出了 auto 槽位")

	# 继续跑，让状态离开存档那一刻
	for _i in 240:
		sc.voyage.tick(DT)
	_check(sc.voyage.t > t_saved + 100.0,
		"又跑了 120 秒（%.0f → %.0f 秒）" % [t_saved, sc.voyage.t])

	# F9 把它拉回来
	_key(sc, KEY_F9)
	_check(str(sc.voyage.last_message).find("读档") >= 0,
		"按 F9 之后界面收到了读档消息（%s）" % sc.voyage.last_message)
	_check(absf(sc.voyage.t - t_saved) < 1e-6,
		"读档后游戏时间回到存的那一刻（%.3f → %.3f）" % [t_saved, sc.voyage.t])
	_check(sc.voyage.ship.position_m().distance_to(pos_saved) < 0.001,
		"读档后船回到存的位置（差 %.6f 米）" % sc.voyage.ship.position_m().distance_to(pos_saved))

	# 读档后继续跑不能炸
	for _i in 60:
		sc.voyage.tick(DT)
	_check(sc.voyage.t > t_saved, "读档后还能继续推进（%.0f 秒）" % sc.voyage.t)

	# F9 之后 AI 船的航点还得是 Vector2（这条线走到过上面那个 String 崩法）
	var wp_bad := 0
	var wp_total := 0
	for s in sc.voyage.fleet.slots:
		if str(s.get("kind", "")) != Fleet.KIND_AI or s.get("ship") == null:
			continue
		var ai_ship: AbstractShip = s["ship"]
		for wp in ai_ship.waypoints:
			wp_total += 1
			if typeof(wp) != TYPE_VECTOR2:
				wp_bad += 1
	_check(wp_bad == 0,
		"F9 读档后 AI 船的航点仍是 Vector2（%d 个里 %d 个变成了字符串）" % [wp_total, wp_bad])

	# 结局 → 结算页（M8 验收第 1 条的"拿到**船队级结算页**"）
	# 为什么要在这里验：v0.1 起 `Settlement.text()` 就一直算得对、也有断言，
	# 但**正常游戏里从来没接过线**（只有截图时间线会铺开它）—— 玩家按遍键也看不到那本账。
	# "逻辑对但没接线"正是这一节要抓的东西。
	sc.voyage.story.ending_ready = true
	sc._ending_auto_shown = false
	sc._process(0.016)                 # 让场景自己走一帧
	_check(sc._ending.visible, "结局一到，结算页自己铺开（不用玩家按键）")
	_check(str(sc._ending.text).find("船队结算") >= 0,
		"铺开的是船队结算那本账（%s…）" % str(sc._ending.text).substr(0, 16))
	_check(str(sc._ending.text).find("【船队】") >= 0, "账里有船队那张表")
	_key(sc, KEY_ESCAPE)
	_check(not sc._ending.visible, "Esc 能把账收起来（继续看海）")
	_key(sc, KEY_S)
	_check(sc._ending.visible, "S 能再把账摊开看一遍")
	_key(sc, KEY_ESCAPE)

	# —— 客户端那条路（M8 收尾补的三条）——
	# 房主那条路是"单机出海"，客户端走的是 `_on_welcome()`；它以前少两步，
	# 于是"没 UI、按键没反应、看不见房主那条船"。这里就盯这两步。
	var host := Voyage.new()
	host.setup(GEO)
	host.orders.set_target_point(Vector2(36000, 20000))
	for _i in 300:
		host.tick(0.5)
	var world := NetProtocol.world_projection(host)
	world["region"] = host.region_path
	sc._on_welcome("san_antonio", host.fleet.summary_of("san_antonio"), world)
	_check(sc._hud_layer.visible and sc._panel_layer.visible,
		"客户端拿到船位后有了 HUD 与面板层（否则就是没有 UI、按键没反应）")
	_check(not sc._room.visible, "客户端那屏的房间界面收起来了")
	_check(sc.voyage.fleet.local_id == "san_antonio",
		"本机开的是房主分的那条船（%s）" % sc.voyage.fleet.local_id)
	var missing := PackedStringArray()
	for id in sc.voyage.fleet.others():
		if not sc._fleet_views.has(str(id)):
			missing.append(str(id))
	_check(missing.is_empty(), "别人的船每条都有渲染器（缺：%s）" % (
		"无" if missing.is_empty() else ", ".join(missing)))
	_check(sc._fleet_views.has("trinidad"),
		"房主那条船在渲染器名单里 —— 客户端看得见它")
	_check(not sc._fleet_views.has("san_antonio"),
		"自己那条船不在「别人的船」名单里（不然会画两遍）")

	var p := ProjectSettings.globalize_path(SaveGame.slot_path("auto"))
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


# ---------------------------------------------------------------- 断言框架

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
