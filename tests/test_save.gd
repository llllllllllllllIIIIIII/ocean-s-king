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
const SCENE := "res://scenes/sea_debug.tscn"

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
		["WindField", v.wind, v.wind.capture_state(), []],
		["ShipDynamics", v.ship, v.ship.capture_state(),
			# land_shapes 是 M2 加进来的**静态世界数据**（海岸/岛的纯数据形状表），
			# 和 land_center/land_radius 一样由 setup() 重新灌，不进存档。
			["physics", "land_center", "land_radius", "land_shapes", "last_blocked", "_last"]],
		["ShipOrders", v.orders, v.orders.capture_state(), []],
		["Navigator", v.nav, v.nav.capture_state(), ["orders"]],
		["Crew", v.crew, v.crew.capture_state(),
			["ship", "roster", "_tw", "_ta", "_alpha_grid"]],
		["CrewRoster", v.roster, v.roster.capture_state(),
			["jobs", "needs", "path", "ready", "_grumble_pool"]],
		["CrewMember", v.roster.members[0], v.roster.members[0].capture_state(),
			["id_hash", "is_key", "display_name", "post", "post_es",
			 "traits", "relations", "skills"]],
		["LandingParty", v.party, v.party.capture_state(), []],
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
	# 开场标题卡挡在前面：任何键都会把它收起来（这是设计，不是 bug）
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
