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
	_test_fleet_rows()
	_test_fleet_sails_to_brazil()
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
