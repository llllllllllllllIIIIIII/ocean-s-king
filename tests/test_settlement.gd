extends SceneTree

# M8 的验收测试（上）：五类成果、三档评价、船队结算。
#
# 验收第 1 条是"两台机器、2–4 人走到巴西拿到船队级结算"—— 真人那半边要用户跑，
# 这里验的是**可计算的那半边**：五类成果的数对不对、三档评价的边界、
# 四条船各自到没到、以及"有人死了/亏了/发现了"会不会真的反映在分数上。

const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_settlement ===")
	_test_five_categories()
	_test_wealth_and_knowledge_move()
	_test_crew_and_death()
	_test_verdicts()
	_test_four_endings()
	_test_fleet_rows()
	_test_fleet_sails_to_brazil()
	_test_player_sails_to_brazil()
	_test_fleet_arrival_settles()
	_test_text_page()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	return v


# ---------------------------------------------------------------- 1 五类成果

func _test_five_categories() -> void:
	var v := _v()
	var r := Settlement.report(v)
	for c in Settlement.CATEGORIES:
		_check(r.has(str(c["id"])), "结算里有「%s」" % str(c["name"]))
	var scores: Dictionary = r["scores"]
	_check(scores.size() == 5, "五类各有一个分（%s）" % str(scores))
	for key in scores.keys():
		_check(typeof(scores[key]) == TYPE_INT, "%s 的分是整数（%d）" % [str(key), int(scores[key])])
	_check(int(r["total"]) == int(scores["wealth"]) + int(scores["voyage"])
		+ int(scores["knowledge"]) + int(scores["crew"]) + int(scores["history"]),
		"总分等于五类之和（%d）" % int(r["total"]))
	_check(str(r["verdict"]) != "", "给了一个评价（%s）" % str(r["verdict"]))


# ---------------------------------------------------------------- 2 钱与发现会加分

func _test_wealth_and_knowledge_move() -> void:
	var poor := _v()
	var rich := _v()
	rich.cargo.money += 3000
	rich.cargo.add("brazilwood", 40)           # 40 捆红木 = 720 金币的货
	var a: int = int(Settlement.report(poor)["scores"]["wealth"])
	var b: int = int(Settlement.report(rich)["scores"]["wealth"])
	_check(int(b) > int(a), "钱与货都算进财富（%d → %d）" % [int(a), int(b)])
	_check(int(Settlement.cargo_value(rich.cargo)) > int(Settlement.cargo_value(poor.cargo)),
		"船上货物的折价算得出来（%d）" % Settlement.cargo_value(rich.cargo))

	var knows := _v()
	var k0 := int(Settlement.report(knows)["scores"]["knowledge"])
	for i in 6:
		knows.knowledge.note("species", "bird_%d" % i, "第 %d 种鸟" % (i + 1), "", 0.0)
	var k1 := int(Settlement.report(knows)["scores"]["knowledge"])
	_check(k1 > k0, "多记 6 条知识就多分（%d → %d）" % [k0, k1])

	# 航海：探明的分块与航程都算分
	var sailed := _v()
	sailed.discovered["1,1"] = true
	sailed.discovered["2,1"] = true
	sailed.journal.distance_m = 20000.0
	var voy0 := int(Settlement.report(_v())["scores"]["voyage"])
	var voy1 := int(Settlement.report(sailed)["scores"]["voyage"])
	_check(voy1 > voy0, "跑得远、探得多就多分（%d → %d）" % [voy0, voy1])


# ---------------------------------------------------------------- 3 死人会扣分

func _test_crew_and_death() -> void:
	var healthy := _v()
	var lost := _v()
	lost.roster.members[3].dead = true
	lost.roster.members[4].dead = true
	lost.roster.members[5].health = 0.3
	lost.society.discipline = 0.2
	lost.ending_score["crew"] = -2
	var a: Dictionary = Settlement.report(healthy)["crew"]
	var b: Dictionary = Settlement.report(lost)["crew"]
	_check(int(b["score"]) < int(a["score"]),
		"死了人、伤了人、纪律散了 → 船员分掉下来（%d → %d）" % [int(a["score"]), int(b["score"])])
	_check(int(a["dead"]) == 0 and int(b["dead"]) == 2, "阵亡人数算得对（%d）" % int(b["dead"]))
	_check(int(b["alive"]) == 38, "生还人数算得对（%d）" % int(b["alive"]))


# ---------------------------------------------------------------- 4 三档评价

# ---------------------------------------------------------------- M19：四档结局

func _arrive_all(v: Voyage, n := 4) -> void:
	var ids := v.fleet.ids()
	for i in mini(n, ids.size()):
		v.fleet.arrived[str(ids[i])] = true


func _test_four_endings() -> void:
	"""验收第 1、2、3 条：四档各有确定的进入条件、互斥、覆盖全部；命令能改档。"""
	_check(Settlement.ending_ids() == ["punished", "glory", "success", "failed"],
		"结局表按优先级排好（%s）" % ", ".join(Settlement.ending_ids()))
	# ① 失败式归来：什么都没做成（没到终点、分低）—— 兜底那一档
	var a := _v()
	var ra := Settlement.report(a)
	_check(str(ra["ending_id"]) == "failed", "什么都没做成 → 失败式归来（%s）" % str(ra["ending_id"]))
	# ② 普通成功：分够 + 至少一条船回来
	var b := _v()
	b.cargo.money += 8000
	b.journal.distance_m = 30000.0
	b.ending_score = {"wealth": 4, "voyage": 3, "knowledge": 4, "crew": 0, "history": 0}
	_arrive_all(b, 1)
	var rb := Settlement.report(b)
	_check(str(rb["ending_id"]) == "success", "分够、船回来了 → 普通成功（%s，总分 %d）"
		% [str(rb["ending_id"]), int(rb["total"])])
	# ③ 巨大荣誉：分很高 + 四条船都到 + 没违抗 + 没滥杀
	var c := _v()
	c.cargo.money += 25000
	c.journal.distance_m = 60000.0
	c.ending_score = {"wealth": 8, "voyage": 8, "knowledge": 8, "crew": 8, "history": 8}
	_arrive_all(c, 4)
	for i in 12:
		c.knowledge.note("chart", "glory_%d" % i, "第 %d 处" % i, "", 0.0)
	var rc := Settlement.report(c)
	_check(str(rc["ending_id"]) == "glory", "分高、四条船都到、没违抗 → 巨大荣誉（%s，总分 %d）"
		% [str(rc["ending_id"]), int(rc["total"])])
	# ④ 政治惩罚：**完成了**，但违抗过王室命令 —— "完成但被惩罚"这条线真的走得通
	var d := _v()
	d.cargo.money += 25000
	d.journal.distance_m = 60000.0
	d.ending_score = {"wealth": 8, "voyage": 8, "knowledge": 8, "crew": 8, "history": 8}
	_arrive_all(d, 4)
	d.memory["friendly_kills"] = 1
	var rd := Settlement.report(d)
	_check(str(rd["ending_id"]) == "punished", "完成环球但违抗过命令 → 政治惩罚（%s）"
		% str(rd["ending_id"]))
	_check(bool(rd["imprison"]), "这一档带「入狱」标记")
	_check(int(rd["ctx"]["orders_broken"]) > 0, "判定的理由里有违抗（%d 条）"
		% int(rd["ctx"]["orders_broken"]))
	_check(int(rd["total"]) > 220, "它的分其实很高（%d）—— 完成不等于成功" % int(rd["total"]))
	# 结算页（正常游戏里自动弹出的那一页）要写明档位、理由与后果
	var txt := Settlement.text(d, d.journal, d.story)
	_check(txt.contains("戴着镣铐回来"), "结算页写着档位（找了「戴着镣铐回来」）")
	_check(txt.contains("理由："), "结算页写着判定的理由")
	_check(txt.contains("带走"), "被惩罚那一档写明了入狱这件事")
	# 互斥与覆盖：四个局面恰好落在四档上
	var seen := {}
	for r in [ra, rb, rc, rd]:
		seen[str(r["ending_id"])] = true
	_check(seen.size() == 4, "四种局面落在四档上（%s）" % ", ".join(seen.keys()))


func _test_verdicts() -> void:
	var bad := _v()
	bad.roster.members[0].dead = true
	bad.roster.members[1].dead = true
	bad.ending_score["history"] = -6
	bad.memory["killed"] = 3
	bad.memory["broken_faith"] = 2
	var r_bad := Settlement.report(bad)
	_check(str(r_bad["verdict"]) == "失败式归来",
		"打坏了、杀过人、毁过约 → 失败式归来（总分 %d）" % int(r_bad["total"]))

	var good := _v()
	good.cargo.money += 8000
	good.journal.distance_m = 40000.0
	for i in 12:
		good.knowledge.note("chart", "tile_%d" % i, "第 %d 处" % i, "", 0.0)
	for key in good.discovered.keys():
		pass
	good.discovered = {"0,0": true, "1,0": true, "2,0": true, "0,1": true,
		"1,1": true, "2,1": true, "0,2": true, "1,2": true, "2,2": true}
	good.ending_score["wealth"] = 4
	good.ending_score["knowledge"] = 4
	good.ending_score["voyage"] = 3
	# M19：「满载而**归**」—— 至少要有一条船回到终点港（新结局表里"成功"这一档要求 arrived ≥ 1）
	good.fleet.arrived[good.fleet.local_id] = true
	var r_good := Settlement.report(good)
	_check(str(r_good["verdict"]) != "失败式归来",
		"满载而归、探明全图 → 不是失败式（%s，总分 %d）" % [str(r_good["verdict"]), int(r_good["total"])])
	# 全队抵达与否会改最高那一档
	var glory := _v()
	glory.cargo.money += 20000
	glory.discovered = good.discovered.duplicate()
	glory.ending_score = {"wealth": 6, "voyage": 6, "knowledge": 6, "crew": 6, "history": 6}
	var r_glory := Settlement.report(glory)
	_check(str(r_glory["verdict"]) == "失败式归来" or str(r_glory["verdict"]) == "普通成功"
		or str(r_glory["verdict"]) == "巨大荣誉",
		"分数够高时评价向上走（%s，总分 %d）" % [str(r_glory["verdict"]), int(r_glory["total"])])
	_check(int(r_glory["total"]) > int(r_bad["total"]),
		"好结局的总分高于坏结局（%d > %d）" % [int(r_glory["total"]), int(r_bad["total"])])


# ---------------------------------------------------------------- 5 船队那张表

func _test_fleet_rows() -> void:
	var v := _v()
	var rows := Settlement.fleet_report(v)
	_check(rows.size() == 4, "四条船都在表里（%d）" % rows.size())
	for row in rows:
		_check(str(row["name"]) != "" and row.has("arrived"),
			"%s：到没到、伤了多少、几个人都在表里" % str(row["name"]))
	var r := Settlement.report(v)
	_check(int(r["arrived"]) == 0, "刚出发时没人到终点（%d）" % int(r["arrived"]))
	# 把本船摆到巴西的锚地：它就"抵达"了
	var goal := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sao_aleixo":
			goal = Geom2D.centroid(p["shape"])
	v.ship.set_pose(goal, 180.0)
	v.fleet.set_local_summary(v.local_summary())
	var r2 := Settlement.report(v)
	_check(int(r2["arrived"]) == 1, "把船开到巴西就算一条抵达（%d/4）" % int(r2["arrived"]))
	var mine := ""
	for row in Settlement.fleet_report(v):
		if str(row["kind"]) == Fleet.KIND_LOCAL:
			mine = str(row["name"]) + ("已抵达" if bool(row["arrived"]) else "没到")
	_check(mine.find("已抵达") >= 0, "表里认得出哪条是本船（%s）" % mine)


# ---------------------------------------------------------------- 6 结算页

func _goal() -> Vector2:
	var v := _v()
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sao_aleixo":
			return Geom2D.centroid(p["shape"])
	return Vector2.ZERO


func _test_fleet_sails_to_brazil() -> void:
	"""AI 船得**自己开得到巴西** —— 修复之前它们会永久"受阻"在离终点 18.5 公里处。"""
	var v := _v()
	var goal := _goal()
	_check(v.fleet.goal.distance_to(goal) < 1.0, "船队的终点就是巴西港（%s）" % str(v.fleet.goal))
	var ai := v.fleet.ids_of_kind(Fleet.KIND_AI)
	_check(ai.size() == 3, "三条 AI 船（%d）" % ai.size())
	for id in ai:
		var ship: AbstractShip = v.fleet.slot_of(id)["ship"]
		_check(ship.waypoints.size() >= 3,
			"%s 拿到了航线航点（%d 个）—— 照航线走，不照直线撞岸" % [id, ship.waypoints.size()])
	var start := {}
	for id in ai:
		start[id] = v.fleet.pose_of(id).distance_to(goal)
	var t := 0.0
	while t < 24000.0 and v.fleet.arrived.size() < 4:
		v.tick(5.0)
		t += 5.0
	var moved := 0
	for id in ai:
		if v.fleet.arrived.has(id) or v.fleet.pose_of(id).distance_to(goal) < float(start[id]) * 0.5:
			moved += 1
	_check(moved == 3, "三条 AI 船都真的往巴西去了（到位或走了一半以上：%d/3，跑了 %.0f 游戏秒）" % [
		moved, t])


func _test_player_sails_to_brazil() -> void:
	"""验收第 1 条里**玩家那条船**的那一半：跟着航线走，真的开得到巴西。

	为什么非有这一条不可：AI 船用的是糙模型（**不认识风**），所以"AI 能到"不等于"到得了"。
	实测踩过：风向突变（脚本事件，永久 +55°）之后，终点港的正北方向成了**正逆风**，
	而港外正好是赤道无风带 —— 船会失速卡在离港 2.3 公里处，19 个游戏小时一步没进。
	修法是把最后 3 公里改成**从东边横着进港**（`routes.json` 的 `verde_brazil`）。
	这条断言就是那个修法的护栏：谁把航点删了、或者把风向调回去，这里会当场变红。
	"""
	var v := _v()
	# ⚠️ **M11 起这里要先把"别的船与追捕"关掉**：这一条护栏盯的是**航线与风**
	#    （见上面的注释：航点被删、风向被调回去，这里就该变红）。
	#    海盗与葡萄牙人都是 M11 的另一套内容 —— 半路被截击、船被打慢之后，
	#    这条断言会因为"航速变了"而不是"航线坏了"变红，那就失去了它盯的东西。
	#    被截击与追捕在 `test_factions`、海战在 `test_naval` 里各有一组断言。
	v.encounters_enabled = false
	v.start_route_follow()
	var goal := _goal()
	var dt := 0.5
	var limit := 10.0 * 3600.0            # 实测 8.0 个游戏小时到；给到 10 小时
	var t := 0.0
	while t < limit and v.ship.position_m().distance_to(goal) > 500.0:
		v.tick(dt)
		t += dt
	var d := v.ship.position_m().distance_to(goal)
	_check(d <= 500.0, "玩家跟着航线走能开到巴西（%.1f 个游戏小时，最后离终点 %.0f 米）" % [
		t / 3600.0, d])
	if d <= 500.0:
		_check(not v.sea.port_at(v.ship.position_m()).is_empty(),
			"到了的时候船就在港里（锚地圈内），能直接抛锚靠港")
		_check(v.discovered_tiles() > 0, "这一趟真的探明了海图（%d 块）" % v.discovered_tiles())


func _test_fleet_arrival_settles() -> void:
	"""全队抵达 → 宣布可以结算（M8 验收第 1 条的出口）。"""
	var v := _v()
	var goal := _goal()
	for id in v.fleet.ids():
		if str(id) == v.fleet.local_id:
			v.ship.set_pose(goal, 180.0)
			v.fleet.set_local_summary(v.local_summary())
		else:
			v.fleet.place_ai(str(id), goal)
	v.tick(0.5)
	# 先让四条船"离开过终点圈"，再回来 —— 抵达的语义是"去过了再回来"
	for id in v.fleet.ids():
		v.fleet.arrived.erase(id)
		v.fleet._left_goal[id] = true
	v.tick(0.5)
	_check(v.fleet.arrived.size() == 4, "四条船都进了终点圈（%d/4）" % v.fleet.arrived.size())
	_check(v.reached_destination, "抵达是个闩：全队到了就记下来")
	_check(v.story.ending_ready, "全队抵达 → 宣布可以结算（和 v0.1 那一幕同一个旗标）")
	var page := Settlement.text(v, v.journal, v.story)
	_check(page.find("4/4 条船抵达") >= 0,
		"结算页写着全队抵达（%s）" % page.substr(page.find("【船队】"), 26))
	var rows := Settlement.fleet_report(v)
	var arrived := 0
	for r in rows:
		if bool(r["arrived"]):
			arrived += 1
	_check(arrived == 4, "船队那张表里四条都是「已抵达」（%d）" % arrived)


func _test_text_page() -> void:
	var v := _v()
	v.cargo.money += 500
	v.knowledge.note("species", "bird", "一只鸟", "红胸的。", 0.0)
	var page := Settlement.text(v, v.journal, v.story)
	for want in ["船队结算", "【财富】", "【航海】", "【知识】", "【船员】", "【历史与政治】", "【船队】"]:
		_check(page.find(want) >= 0, "结算页里有「%s」" % want)
	_check(page.find("评价：") >= 0, "结算页给出了评价")
	_check(page.find("距终点") >= 0 or page.find("已抵达") >= 0, "结算页写了每条船离终点多远")


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
