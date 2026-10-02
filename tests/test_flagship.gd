extends SceneTree

# M16 的验收：旗舰与轻编队（docs/23 的 M16 卡片、docs/22 第 5.5 节）。
#
# 四件事：
#   1. **旗舰沉没**（验收第 1 条）：玩家还在、新船能开、旧船进日志与结算；
#   2. **状态连续**（验收第 2 条）：接管前后的位置/船体/人数连续（一个船身以内）；
#   3. **轻编队**（验收第 3 条）：三条指令各自的阵位可复现，而且不会把船摆到干地上；
#   4. **归属**（验收第 4 条）：换旗舰之后，那条船归本机、别的船仍无人认领；
#      编队与沉船记录进世界状态（联机投影里看得到）。

const DT := 0.5
const SHIP_LENGTH_M := 20.0

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_flagship ===")
	_test_truth_source()
	_test_flagship_lost_and_take_over()
	_test_continuity()
	_test_formation_orders()
	_test_formation_reproducible()
	_test_formation_avoids_land()
	_test_ownership_and_projection()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	return v


# ---------------------------------------------------------------- 1 真源

func _test_truth_source() -> void:
	var v := _v()
	_check(v.fleet.formation_ids().size() >= 5, "编队指令表有 %d 条" % v.fleet.formation_ids().size())
	for mode in ["free", "follow_near", "follow_mid", "follow_far", "hold"]:
		_check(not Fleet.formation_def(mode).is_empty(), "编队表里有 %s" % mode)
	_check(Fleet.formation_def("free").get("astern_m", -1.0) == 0.0,
		"自由巡航没有阵位（astern 0）")
	var near := float(Fleet.formation_def("follow_near").get("astern_m", 0.0))
	var far := float(Fleet.formation_def("follow_far").get("astern_m", 0.0))
	_check(near > 0.0 and far > near, "跟随距离是数据里的（近 %.0f 米 < 远 %.0f 米）" % [near, far])
	_check(v.fleet.flagship == "trinidad", "默认旗舰是数据里标了 flagship 的那条（%s）" % v.fleet.flagship)


# ---------------------------------------------------------------- 2 旗舰沉没

func _test_flagship_lost_and_take_over() -> void:
	var v := _v()
	# 别的船摆在附近（接管要"就近"）
	var here := v.ship.position_m()
	v.fleet.place_ai("san_antonio", v.sea.wrap_pos(here + Vector2(400.0, 0.0)), 90.0)
	v.fleet.place_ai("concepcion", v.sea.wrap_pos(here + Vector2(1200.0, 0.0)), 90.0)
	v.fleet.place_ai("victoria", v.sea.wrap_pos(here + Vector2(2400.0, 0.0)), 90.0)
	var before := v.fleet.local_id
	_check(before == "trinidad", "开局开的是旗舰（%s）" % before)
	var journal_before: int = v.journal.entries.size()
	# 船壳全毁 → 沉
	v.ship.apply_damage("hull", 1.0)
	v.check_flagship_lost()
	_check(v.fleet.local_id != before, "旗舰沉了之后换了船（%s → %s）" % [before, v.fleet.local_id])
	_check(v.fleet.local_id == "san_antonio", "接手的是最近的那条（%s）" % v.fleet.local_id)
	_check(v.fleet.lost.has(before), "旧船记进了船队的损失名单（%s）" % before)
	_check(v.lost_ships.size() == 1 and str((v.lost_ships[0] as Dictionary).get("id", "")) == before,
		"沉船记录进了世界状态（%d 条）" % v.lost_ships.size())
	_check(int(v.memory.get("ships_lost", 0)) == 1, "世界记住了「丢了一条船」")
	_check(v.journal.entries.size() > journal_before, "航海日志里多了一条（%d → %d）"
		% [journal_before, v.journal.entries.size()])
	_check(v.ship.damage_of("hull") < 1.0, "新船没有跟着一起沉（船壳损伤 %.2f）" % v.ship.damage_of("hull"))
	_check(v.fleet.lost[before]["was_flagship"] == true, "记录里写着它原来是旗舰")
	# 新船能开：给个目标，跑一会儿，位置真的变了
	var p0 := v.ship.position_m()
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(v.sea.wrap_pos(p0 + Vector2(800.0, 0.0)))
	for i in 600:
		v.tick(DT)
	_check(v.ship.position_m().distance_to(p0) > 30.0,
		"新船开得动（走了 %.0f 米）" % v.ship.position_m().distance_to(p0))


# ---------------------------------------------------------------- 3 状态连续

func _test_continuity() -> void:
	var v := _v()
	var here := v.ship.position_m()
	var target := v.sea.wrap_pos(here + Vector2(600.0, 0.0))
	v.fleet.place_ai("san_antonio", target, 137.0)
	# 别的两条摆远一点：接管时必须挑中 san_antonio（就近接管）
	v.fleet.place_ai("concepcion", v.sea.wrap_pos(here + Vector2(20000.0, 0.0)), 90.0)
	v.fleet.place_ai("victoria", v.sea.wrap_pos(here + Vector2(-24000.0, 0.0)), 90.0)
	var taken := v.fleet.summary_of("san_antonio")
	v.ship.apply_damage("hull", 1.0)
	v.check_flagship_lost()
	_check(v.fleet.local_id == "san_antonio", "接手了 san_antonio")
	_check(v.ship.position_m().distance_to(target) <= SHIP_LENGTH_M,
		"接管前后的位置连续（差 %.1f 米）" % v.ship.position_m().distance_to(target))
	_check(absf(v.ship.heading_deg() - 137.0) < 1.0, "艏向也接上了（%.0f°）" % v.ship.heading_deg())
	_check(is_equal_approx(v.ship.damage_of("hull"), 1.0 - float(taken.get("hull_pct", 1.0))),
		"船体%从摘要里继承（损伤 %.2f）" % v.ship.damage_of("hull"))
	_check(v.roster.members.size() >= 40, "名册按船 id 重新生成（%d 人）" % v.roster.members.size())
	_check(v.roster.seed_offset == absi("san_antonio".hash()) % 97,
		"名册带的是那条船 id 的种子（%d）" % v.roster.seed_offset)


# ---------------------------------------------------------------- 4 编队

func _test_formation_orders() -> void:
	var v := _v()
	var lead := v.ship.position_m()
	var heading := v.ship.heading_deg()
	var counts := {}
	for mode in ["follow_near", "follow_mid", "follow_far"]:
		_check(bool(v.set_formation(mode).get("ok", false)), "下得了「%s」这条指令" % mode)
		var astern_m := float(Fleet.formation_def(mode).get("astern_m", 0.0))
		var idx := 0
		var ok := true
		for id in v.fleet.alive_ids():
			if id == v.fleet.flagship:
				continue
			idx += 1
			var want := v.fleet.formation_target(id, idx, lead, heading)
			if v.sea.dist(want, lead) < astern_m * 0.5:
				ok = false
		_check(ok, "「%s」的阵位点在旗舰后方 %.0f 米量级" % [mode, astern_m])
		counts[mode] = astern_m
	_check(counts["follow_near"] < counts["follow_mid"] and counts["follow_mid"] < counts["follow_far"],
		"三条跟随指令的远近是分开的（%.0f / %.0f / %.0f）"
		% [counts["follow_near"], counts["follow_mid"], counts["follow_far"]])
	# 保持阵位：把当时的相对位置记下来，之后不跟着转
	_check(bool(v.set_formation("hold").get("ok", false)), "下得了「保持阵位」")
	var held := v.fleet.formation_target("san_antonio", 1, lead, heading)
	var held2 := v.fleet.formation_target("san_antonio", 1, lead, fposmod(heading + 90.0, 360.0))
	_check(held.distance_to(held2) < 0.001, "保持阵位不随旗舰转向而变")
	# 自由巡航：没有阵位（照航线走）
	_check(bool(v.set_formation("free").get("ok", false)), "回得到「自由巡航」")
	_check(v.fleet.formation_target("san_antonio", 1, lead, heading).distance_to(lead) < 0.001,
		"自由巡航时不给阵位点")
	_check(not bool(v.set_formation("nonsense").get("ok", false)), "不认识的指令会被拒")


func _test_formation_reproducible() -> void:
	"""同样的初始条件跑两遍，AI 船的位置逐位相同（可复现）。"""
	var a := _run_formation(900)
	var b := _run_formation(900)
	var same := true
	for id in a.keys():
		if (a[id] as Vector2).distance_to(b[id] as Vector2) > 0.001:
			same = false
	_check(same, "同一条编队跑两遍，四条船的位姿一样")
	_check(a.size() == 4, "四条船都在（%d）" % a.size())


func _run_formation(steps: int) -> Dictionary:
	var v := _v()
	v.set_formation("follow_mid")
	var start := v.ship.position_m()
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(v.sea.wrap_pos(start + Vector2(6000.0, 0.0)))
	for i in steps:
		v.tick(DT)
	var out := {}
	for id in v.fleet.alive_ids():
		out[id] = v.fleet.pose_of(id)
	return out


func _test_formation_avoids_land() -> void:
	"""阵位点要是落在干地上，就得挪开 —— 不然那条船会一头顶住岸。"""
	var v := _v()
	# 找一处贴着岸的水面当旗舰位置
	var spot := Vector2.ZERO
	var found := false
	for land in v.sea.lands():
		var c := Geom2D.centroid(land["shape"])
		for k in 24:
			var p := c + Vector2(cos(TAU * float(k) / 24.0), sin(TAU * float(k) / 24.0)) * 1200.0
			if v.sea.world.is_dry_land(p):
				continue
			if float(v.sea.nearest_shore(p)["distance_m"]) < 200.0:
				spot = p
				found = true
				break
		if found:
			break
	_check(found, "找得到一处贴岸的旗舰位置")
	if not found:
		return
	v.ship.set_pose(spot, 0.0)          # 艏向朝东：阵位点在正后方（西边，很可能在岸上）
	v._publish_local_summary()
	v.set_formation("follow_far")
	var safe := true
	var moved := true
	var p0 := v.fleet.pose_of("san_antonio")
	for step in 400:
		v.fleet.step_game(DT, v.sea)
		var tgt: Vector2 = (v.fleet.slot_of("san_antonio")["ship"] as AbstractShip).target
		if v.sea.world.is_dry_land(tgt):
			safe = false
	_check(safe, "阵位点不在干地上（会被挪到水里）")
	moved = v.fleet.pose_of("san_antonio").distance_to(p0) > 5.0
	_check(moved, "那条船真的在走（没有顶住岸停死）")


# ---------------------------------------------------------------- 5 归属与世界状态

func _test_ownership_and_projection() -> void:
	var v := _v()
	var here := v.ship.position_m()
	v.fleet.place_ai("victoria", v.sea.wrap_pos(here + Vector2(300.0, 0.0)), 90.0)
	v.ship.apply_damage("hull", 1.0)
	v.check_flagship_lost()
	var new_id := v.fleet.local_id
	_check(new_id == "victoria", "接手了 victoria（%s）" % new_id)
	_check(v.fleet.kind_of(new_id) == Fleet.KIND_LOCAL, "新旗舰在本机是 local（%s）"
		% v.fleet.kind_of(new_id))
	_check(v.fleet.owner_name_of(new_id) == "我", "归属写的是本机（%s）" % v.fleet.owner_name_of(new_id))
	_check(v.fleet.owner_peer_of(new_id) == 1, "拥有者 peer = 1（%d）" % v.fleet.owner_peer_of(new_id))
	# 世界投影里带着编队与沉船记录（联机时客户端照这个只读覆盖）
	v.set_formation("follow_near")
	var proj := NetProtocol.world_projection(v)
	_check(str(proj.get("formation", "")) == "follow_near", "世界投影里有编队指令（%s）"
		% str(proj.get("formation", "")))
	_check((proj.get("lost_ships", []) as Array).size() == 1, "世界投影里有沉船记录")
	# 另一台机器照投影覆盖之后，看到的是同一个编队与同一条沉船
	var v2 := _v()
	NetProtocol.apply_world_projection(v2, proj)
	_check(v2.formation == "follow_near", "客户端覆盖到同一条编队（%s）" % v2.formation)
	_check(v2.lost_ships.size() == 1, "客户端也有了那条沉船记录")


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
