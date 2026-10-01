extends SceneTree

# M3 的船队验收（不联网的那一半）：世界里四艘船，每台机器只细化自己那一条。
#
# 五件事：
#   1. 单机 = 1 条细化 + 3 条 AI，**和联机走同一条代码路径**；
#   2. 抽象船只有摘要（上网的就是那一份，逐人细节不在里面）；
#   3. AI 船真的会走，而且不会把船开上干地；
#   4. 抽象 ↔ 细化的升降级：接手时继承摘要、掉线时转回 AI 而且**船不消失**；
#   5. 远端船按 100ms 插值、**不外推**；船队进存档、读回来接着跑。

const DT := 0.5
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_fleet ===")
	_test_slots()
	_test_abstract_shape()
	_test_ai_sails()
	_test_attach_detach()
	_test_interpolation()
	_test_save_roundtrip()
	_finish()


func _voyage() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	return v


func _run(v: Voyage, seconds: float) -> void:
	for _i in int(seconds / DT):
		v.tick(DT)


# ---------------------------------------------------------------- 1 船位

func _test_slots() -> void:
	var v := _voyage()
	_check(v.fleet.count() == 4, "世界里固定 4 艘远征船（%d）" % v.fleet.count())
	var names := PackedStringArray()
	for s in v.fleet.slots:
		names.append(str(s["name"]))
	_check(v.fleet.local_id == "trinidad", "本机开的是旗舰特立尼达（%s）" % v.fleet.local_id)
	_check(v.fleet.ids_of_kind(Fleet.KIND_LOCAL).size() == 1, "只有一条是「本机细化」")
	_check(v.fleet.ids_of_kind(Fleet.KIND_AI).size() == 3, "单机时其余三条是 AI（%d）" % v.fleet.ids_of_kind(Fleet.KIND_AI).size())
	_check("圣安东尼奥" in names and "维多利亚" in names,
		"四条船的名字来自 data/defs/fleet.json（%s）" % ", ".join(names))
	# 本机那条是细化的：有 40 个人的名册
	_check(v.roster.members.size() == 40, "本机那条有 40 人逐人名册（%d）" % v.roster.members.size())
	# 别的船没有名册这个概念
	var ai_id: String = v.fleet.ids_of_kind(Fleet.KIND_AI)[0]
	var slot := v.fleet.slot_of(ai_id)
	_check(slot["ship"] is AbstractShip and slot["ship"].to_summary().size() == 9,
		"AI/别人的船只是一个 9 键摘要，没有名册（%d 键）" % slot["ship"].to_summary().size())
	_check(v.local_summary()["id"] == "trinidad", "本机的摘要是从细化运行时压出来的")
	_check(v.local_summary()["crew_count"] == 40, "摘要里有船上人数（%d）" % v.local_summary()["crew_count"])


# ---------------------------------------------------------------- 2 摘要的形状

func _test_abstract_shape() -> void:
	"""上网的那一份必须**只有**这几个键：多一个键就等于多传了不该传的东西。"""
	var want := ["id", "name", "pos", "heading", "sail_level", "anchored",
		"hull_pct", "crew_count", "action"]
	var a := AbstractShip.new()
	a.setup("victoria", "维多利亚", Vector2(100, 200), 45.0)
	var d := a.to_summary()
	var missing := PackedStringArray()
	for k in want:
		if not d.has(k):
			missing.append(k)
	var extra := PackedStringArray()
	for k in d.keys():
		if not want.has(str(k)):
			extra.append(str(k))
	_check(missing.is_empty(), "摘要里有全部该有的键（缺：%s）" % _list(missing))
	_check(extra.is_empty(), "摘要里没有多余的键（多：%s）" % _list(extra))
	# 逐人细节**不在**摘要里（这是"不许进入别人的船的内部视图"的技术形态）
	var text := str(d)
	_check(not text.contains("fatigue") and not text.contains("roster") and not text.contains("member"),
		"摘要里没有疲劳/名册这类逐人细节")
	var b := AbstractShip.new()
	b.apply_summary(d)
	_check(b.pos == a.pos and b.heading_deg == a.heading_deg and b.hull_pct == a.hull_pct,
		"摘要能原样吃回去（%s）" % str(b.pos))


# ---------------------------------------------------------------- 3 AI 会走

func _test_ai_sails() -> void:
	var v := _voyage()
	var ids := v.fleet.ids_of_kind(Fleet.KIND_AI)
	var before := {}
	for id in ids:
		before[id] = v.fleet.pose_of(id)
	var grounded := 0
	for _i in int(900.0 / DT):
		v.tick(DT)
		for id in ids:
			if v.sea.is_dry_land(v.fleet.pose_of(id)):
				grounded += 1
	var moved := 0
	for id in ids:
		if v.fleet.pose_of(id).distance_to(before[id] as Vector2) > 100.0:
			moved += 1
	_check(moved == 3, "三条 AI 船都真的在走（%d/3）" % moved)
	_check(grounded == 0, "AI 船一次都没被开上干地（%d 次）" % grounded)
	var s := v.fleet.summary_of(ids[0])
	_check(str(s["action"]) != "" and float(s["hull_pct"]) == 1.0,
		"AI 船的摘要在动（%s，船体 %.0f%%）" % [str(s["action"]), float(s["hull_pct"]) * 100.0])
	# AI 不吃本机的算力：它没有气动积分，只有一行"朝目标走"
	_check(v.fleet.slot_of(ids[0])["ship"] is AbstractShip,
		"AI 是抽象船，不是第二条细化船")


# ---------------------------------------------------------------- 4 升降级

func _test_attach_detach() -> void:
	var v := _voyage()
	var id := "victoria"
	# 这条 AI 船先自己走一段，攒出"当前位置 / 船体%"这类抽象数值
	v.fleet.slot_of(id)["ship"].apply_damage("hull", 0.3)
	_run(v, 300.0)
	var pos_before := v.fleet.pose_of(id)
	# 有人接手：抽象 → 细化
	var summary := v.fleet.attach_player(id, 42, "小明")
	_check(v.fleet.kind_of(id) == Fleet.KIND_REMOTE, "接手之后这个船位是「别人的船」")
	_check(str(summary["id"]) == id and float(summary["hull_pct"]) < 1.0,
		"接手拿到的是摘要（船体 %.0f%%）" % (float(summary["hull_pct"]) * 100.0))
	_check(Vector2(float(summary["pos"][0]), float(summary["pos"][1])).distance_to(pos_before) < 1.0,
		"接手时位置是接着的（差 %.1f 米）" % Vector2(float(summary["pos"][0]), float(summary["pos"][1])).distance_to(pos_before))
	# 新接手的那台机器照摘要把船生出来（这里直接验"生出来之后数值一致"）
	var fresh := Voyage.new()
	fresh.setup(GEO, id, summary)
	_check(fresh.fleet.local_id == id, "新窗口开的是被接手的那条船（%s）" % fresh.fleet.local_id)
	_check(absf(1.0 - fresh.ship.damage_of("hull") - float(summary["hull_pct"])) < 1e-6,
		"新船继承了船体损伤（%.0f%%）" % (fresh.ship.damage_of("hull") * 100.0))
	_check(fresh.ship.position_m().distance_to(pos_before) < 1.0,
		"新船出生在被接手的位置上（差 %.1f 米）" % fresh.ship.position_m().distance_to(pos_before))
	_check(fresh.roster.members.size() == 40,
		"接手后名册按同一份数据集重新生成（%d 人）" % fresh.roster.members.size())
	# 掉线：**船不消失**，就地转 AI 继续走
	var pos_at_drop := v.fleet.pose_of(id)
	v.fleet.detach_player(id, v.default_destination())
	_check(v.fleet.kind_of(id) == Fleet.KIND_AI, "掉线之后这条船回到 AI 手上")
	_check(v.fleet.pose_of(id).distance_to(pos_at_drop) < 1e-6, "掉线的瞬间位置一点没动")
	_run(v, 400.0)
	_check(v.fleet.pose_of(id).distance_to(pos_at_drop) > 50.0,
		"掉线之后它自己接着走（走了 %.0f 米）" % v.fleet.pose_of(id).distance_to(pos_at_drop))


# ---------------------------------------------------------------- 5 插值

func _test_interpolation() -> void:
	var f := Fleet.new()
	f.setup()
	f.claim_local("trinidad")
	f.attach_player("victoria", 7, "小明")
	var sea := Sea.new()
	sea.setup(GEO)
	f.t = 0.0
	f.receive_summary({"id": "victoria", "pos": [0.0, 0.0], "heading": 0.0,
		"sail_level": 0, "anchored": false, "hull_pct": 1.0, "crew_count": 40, "action": "巡航"})
	f.t = 0.2
	f.receive_summary({"id": "victoria", "pos": [200.0, 0.0], "heading": 10.0,
		"sail_level": 0, "anchored": false, "hull_pct": 1.0, "crew_count": 40, "action": "巡航"})
	# 本机时间 0.25，插值延迟 0.1 -> 取 0.15 那一刻：两次摘要之间 75% 的位置
	f.t = 0.25
	f.step_game(0.0, sea)
	var at := f.pose_of("victoria")
	_check(absf(at.x - 150.0) < 2.0, "远端船按 100ms 延迟插值（期望 150，实得 %.1f）" % at.x)
	_check(absf(f.heading_of("victoria") - 7.5) < 0.5,
		"艏向也是插出来的（期望 7.5°，实得 %.1f°）" % f.heading_of("victoria"))
	# 不外推：把时间推过最后一个摘要很久，船应该停在最后一个摘要的位置上
	f.t = 5.0
	f.step_game(0.0, sea)
	_check(absf(f.pose_of("victoria").x - 200.0) < 0.01,
		"没有新摘要时**不外推**，停在最后一个已知位置（%.1f）" % f.pose_of("victoria").x)


# ---------------------------------------------------------------- 6 存档

func _test_save_roundtrip() -> void:
	var a := _voyage()
	_run(a, 400.0)
	a.fleet.slot_of("concepcion")["ship"].apply_damage("hull", 0.25)
	var cap := a.capture_fleet()
	_check(cap.size() == 4, "存档里的 ships[] 是 4 条（%d）" % cap.size())
	_check(str(cap[0]["kind"]) == "detailed", "第一条是本机的细化存档")
	var abstracts := 0
	for i in range(1, cap.size()):
		if str(cap[i]["kind"]) == "abstract":
			abstracts += 1
	_check(abstracts == 3, "其余三条是抽象存档（%d）" % abstracts)
	_check((cap[0] as Dictionary).has("roster") and not (cap[1] as Dictionary).has("roster"),
		"细化存档有 40 人名册、抽象存档没有")

	var b := Voyage.new()
	b.setup(GEO)
	b.apply_world_state(a.capture_world_state())
	b.apply_fleet(cap)
	var worst := 0.0
	for id in a.fleet.others():
		worst = maxf(worst, b.fleet.pose_of(id).distance_to(a.fleet.pose_of(id)))
	_check(worst < 0.01, "读档后 AI/远端船的位置一致（最大差 %.4f 米）" % worst)
	_check(absf(float(b.fleet.summary_of("concepcion")["hull_pct"])
		- float(a.fleet.summary_of("concepcion")["hull_pct"])) < 1e-6,
		"读档后 AI 船的船体%%一致（%.0f%%）" % (float(b.fleet.summary_of("concepcion")["hull_pct"]) * 100.0))
	# 读档之后两边继续跑，船队仍然一致
	_run(a, 300.0)
	_run(b, 300.0)
	var worst2 := 0.0
	for id in a.fleet.others():
		worst2 = maxf(worst2, b.fleet.pose_of(id).distance_to(a.fleet.pose_of(id)))
	_check(worst2 < 2.0, "读档后继续跑 300 秒，船队仍一致（最大差 %.3f 米）" % worst2)


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
