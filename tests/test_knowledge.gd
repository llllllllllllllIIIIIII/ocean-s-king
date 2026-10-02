extends SceneTree

# M18 的验收：探索产出 · 知识解锁 · 三视图 · 海图插旗（docs/23 的 M18 卡片）。
#
# 五件事：
#   1. **六种探险产出**（沉船 / 海底遗迹 / 宝藏 / 新物种 / 新资源 / 未知民族）各自出得来，
#      而且每一条都落到**五类结算**的某一类里；
#   2. **可复现**：同一个地点只出一次，出哪一条由地点 id 决定（跑两遍一样）；
#   3. **知识解锁可选项**：知道"鸟与鲸指的路"之后，缺粮那张卡多出一个选项；
#   4. **三视图**：七处损伤每一处都在图上（`damage_marks()` 逐处断言）；
#   5. **海图插旗**：插了旗，世界状态往返之后还在。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_knowledge ===")
	_test_truth_source()
	_test_six_kinds()
	_test_reproducible()
	_test_knowledge_unlocks_option()
	_test_tri_view_marks()
	_test_chart_flags_saved()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	return v


# ---------------------------------------------------------------- 1 真源

func _test_truth_source() -> void:
	_check(Expedition.kinds().size() == 6, "六类探险产出（%d）" % Expedition.kinds().size())
	for want in ["wreck", "ruins", "treasure", "species", "resource", "people"]:
		_check(not Expedition.kind_def(want).is_empty(), "有「%s」这一类" % want)
		_check(Expedition.finds_of_kind(want).size() >= 2,
			"「%s」至少两条（%d）" % [want, Expedition.finds_of_kind(want).size()])
	for f in Expedition.finds():
		_check(not (f.get("knowledge", {}) as Dictionary).is_empty(),
			"每一条都带一条知识（%s）" % str(f.get("id", "")))


# ---------------------------------------------------------------- 2 六种产出

func _test_six_kinds() -> void:
	var reachable := {}
	for kind in ["wreck", "ruins", "treasure", "species", "resource", "people"]:
		var v := _v()
		# 找一个"按规则会落到这一类"的地点 id（岛上出哪一类由 id 的哈希决定 —— 这正是要验的）
		var where := "reef" if kind == "wreck" else "island"
		var pid := ""
		for i in 300:
			var cand := "place_%s_%d" % [kind, i]
			if Expedition.kind_for_where(where, cand) == kind:
				pid = cand
				break
		_check(pid != "", "找得到一个会出「%s」的地点" % Expedition.kind_name(kind))
		if pid == "":
			continue
		# 真的把它落到船上：知识 / 货物 / 五类结算
		var before_score := v.ending_score.duplicate()
		var before_knowledge := v.knowledge.count()
		var r := v.try_find(pid, where)
		_check(bool(r.get("ok", false)) and str(r.get("kind", "")) == kind,
			"在%s上出的是「%s」（%s）" % [where, Expedition.kind_name(kind), str(r.get("kind", ""))])
		_check(v.knowledge.count() > before_knowledge, "记了一条知识（%d → %d）"
			% [before_knowledge, v.knowledge.count()])
		var moved := false
		for key in before_score.keys():
			if int(v.ending_score.get(key, 0)) != int(before_score[key]):
				moved = true
		_check(moved, "「%s」进了五类结算" % Expedition.kind_name(kind))
		reachable[kind] = true
	_check(reachable.size() == 6, "六类都能真的落到船上（%d）" % reachable.size())
	# 未知民族：新群体是一条新记录，而且真的改当地人的态度
	var v3 := _v()
	var before_locals := v3.factions.value("locals")
	var r3 := v3.try_find("island_people_test", "island")
	if str(r3.get("kind", "")) == "people":
		_check(v3.known_peoples.size() == 1, "记下了一个新的群体（%d）" % v3.known_peoples.size())
		_check(v3.factions.value("locals") > before_locals, "当地人的态度变了（%.2f → %.2f）"
			% [before_locals, v3.factions.value("locals")])


# ---------------------------------------------------------------- 3 可复现

func _test_reproducible() -> void:
	var a := _v()
	var b := _v()
	var ra := a.try_find("island_repro", "island")
	var rb := b.try_find("island_repro", "island")
	_check(str(ra.get("id", "")) == str(rb.get("id", "")),
		"同一个地点两次得到同一样东西（%s = %s）" % [str(ra.get("id", "")), str(rb.get("id", ""))])
	var again := a.try_find("island_repro", "island")
	_check(not bool(again.get("ok", false)), "同一个地点不会出第二次（%s）"
		% str(again.get("reason", "")))


# ---------------------------------------------------------------- 4 知识解锁

func _test_knowledge_unlocks_option() -> void:
	var v := _v()
	var id := "pacific_thirst"
	var locked := v.dilemmas.locked_options(id, v)
	_check(locked.has("follow_birds_to_island"), "不知道「鸟与鲸指的路」时那个选项锁着（%s）"
		% ", ".join(locked))
	var r := v.dilemmas.resolve(v, id, "follow_birds_to_island")
	_check(not bool(r.get("ok", false)), "锁着的选项选不了（%s）" % str(r.get("reason", "")))
	# 学到那条知识之后再试
	v.knowledge.note("chart", "birds_point_land", "鸟与鲸指的路", "", v.t)
	_check(v.dilemmas.locked_options(id, v).is_empty(), "知道之后那个选项解锁了")
	v.dilemmas.resolved.clear()
	var r2 := v.dilemmas.resolve(v, id, "follow_birds_to_island")
	_check(bool(r2.get("ok", false)), "解锁之后选得动（%s）" % str(r2.get("reason", "")))


# ---------------------------------------------------------------- 5 三视图

func _test_tri_view_marks() -> void:
	var v := _v()
	var tv := TriView.new()
	tv.configure(v)
	var marks := tv.damage_marks()
	_check(marks.size() == 8, "七处损伤 + 起火/进水两种状态都有一条（%d）" % marks.size())
	var parts := []
	for m in marks:
		parts.append(str(m["part"]))
	for want in ["hull", "mast", "rudder", "sail", "hold", "magazine", "fire", "flood"]:
		_check(parts.has(want), "图上管着「%s」这一处" % want)
	# 贴上损伤之后，每一条都"真的画出来"（drawn = true）
	v.ship.apply_damage("hull", 0.4)
	v.ship.apply_damage("mast", 0.3)
	v.ship.apply_damage("rudder", 0.2)
	v.ship.apply_damage("sail", 0.35)
	v.ship.apply_damage("hold", 0.25)
	v.ship.apply_damage("magazine", 0.3)
	v.ship.apply_hazard("fire", 0.4)
	v.ship.apply_hazard("flood", 0.3)
	tv.configure(v)
	var drawn := 0
	for m in tv.damage_marks():
		if bool(m["drawn"]):
			drawn += 1
	_check(drawn == 8, "八处都画上了（%d/8）" % drawn)
	for m in tv.damage_marks():
		_check((m["views"] as Array).size() > 0, "%s 至少在一个视图里" % str(m["label"]))
	tv.free()


# ---------------------------------------------------------------- 6 海图插旗

func _test_chart_flags_saved() -> void:
	var v := _v()
	var f := v.add_chart_flag("补给点", "supply")
	_check(v.chart_flags.size() == 1 and str(f.get("name", "")) == "补给点", "插了一面旗")
	_check((f.get("pos", []) as Array).size() == 2, "旗上带着位置（%s）" % str(f.get("pos", [])))
	# 世界状态往返（存档与联机都是这一份）
	var st := v.capture_world_state()
	var v2 := _v()
	v2.apply_world_state(st)
	_check(v2.chart_flags.size() == 1, "读回来旗还在（%d 面）" % v2.chart_flags.size())
	_check(str(v2.chart_flags[0].get("name", "")) == "补给点", "旗上的名字也在")
	# 探索产出与民族记录同样跟着世界状态走
	var v3 := _v()
	v3.try_find("island_roundtrip", "island")
	var st3 := v3.capture_world_state()
	var v4 := _v()
	v4.apply_world_state(st3)
	_check(v4.find_log.size() == v3.find_log.size() and v4.find_log.size() > 0,
		"探索产出跟着世界状态走（%d 处）" % v4.find_log.size())


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
