extends SceneTree

# M5 的验收测试：规则制度 + 船上社会 + 三个高压抉择。
#
# 三条验收（docs/13 M5 卡片）：
#   1. **改规则 → 行为与数值真的变**：同一场景下把口粮从足量改成严格配给，
#      食物消耗下降、疲劳上升、抱怨变多 —— 三条都要是数；
#   2. **每个抉择 ≥4 条后果不同的选项**：选 A 与选 B 之后的船员状态 / 关系 /
#      纪律 / 结局分数真的不同（不是只在文案上不同）；
#   3. **一次 8 小时游戏时间里，自然出现至少 1 次船员事件**（不靠脚本硬触发）。

# 社会尺度粗，用大一点的步长跑得动：疲劳/心情的累积都是**线性**的，
# 所以步长只影响跑多久，不影响量出来的数。
const DT := 4.0
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_society ===")
	_test_rules_table()
	_test_rules_change_numbers()
	_test_relations_and_groups()
	_test_events_happen_naturally()
	_test_dilemma_options()
	_test_why_unhappy()
	_test_save()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	# 测试里让船停着：关心的是人，不是帆
	v.orders.anchored = true
	v.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
	return v


func _run(v: Voyage, game_seconds: float) -> void:
	var n := int(game_seconds / DT)
	for _i in n:
		v.tick(DT)


func _avg(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var s := 0.0
	for x in values:
		s += float(x)
	return s / float(values.size())


# ---------------------------------------------------------------- 1 规则表

func _test_rules_table() -> void:
	var r := Rules.new()
	r.setup()
	_check(r.rule_ids().size() == 6, "六条规矩都在（%s）" % ", ".join(r.rule_ids()))
	for want in ["ration", "water", "watch", "liquor", "curfew", "punish"]:
		var d := r.rule_def(want)
		_check(not d.is_empty() and (d.get("options", []) as Array).size() >= 2,
			"%s 至少有两个档位（%d）" % [str(d.get("name", want)),
				(d.get("options", []) as Array).size()])
	# 档位之间在数值上必须真的不同，否则"改了没用"
	_check(r.food_mult() == 1.0, "默认是足量（食物 ×%.2f）" % r.food_mult())
	r.set_rule("ration", "strict")
	_check(absf(r.food_mult() - 0.35) < 1e-6, "严格配给：食物 ×%.2f" % r.food_mult())
	_check(r.fatigue_mult() > 1.2, "严格配给让疲劳攒得更快（×%.2f）" % r.fatigue_mult())
	_check(r.mood_bias() < -0.05, "严格配给压心情（%+.2f/天）" % r.mood_bias())
	r.set_rule("watch", "all")
	_check(r.fatigue_mult() > 1.6, "全员当值再叠一层（×%.2f）" % r.fatigue_mult())
	r.set_rule("punish", "brutal")
	_check(r.discipline_bonus() > 0.15, "严刑把纪律抬起来（%+.2f）" % r.discipline_bonus())
	_check(r.tension_mult() > 1.2, "严刑也把紧张度推高（×%.2f）" % r.tension_mult())
	r.set_rule("liquor", "forbidden")
	_check(r.tension_mult() > 1.5, "禁酒再叠一层（×%.2f）" % r.tension_mult())
	_check(r.changed == 4, "改过几次规矩记得住（%d）" % r.changed)


# ---------------------------------------------------------------- 2 验收第 1 条

func _test_rules_change_numbers() -> void:
	"""同一场景，只有口粮制度不同：消耗、疲劳、抱怨三条都要变。"""
	var full := _v()
	var strict := _v()
	for v in [full, strict]:                 # 先补足：不然两局都会"吃光就停"、看起来一样
		v.cargo.add("food", 900)
		v.cargo.add("water", 60)
	strict.set_rule("ration", "strict")
	strict.set_rule("watch", "two")
	var food0_full := full.cargo.qty("food")
	var food0_strict := strict.cargo.qty("food")
	_run(full, 2.5 * 3600.0)          # 2.5 个游戏小时 = 6.5 个航程日
	_run(strict, 2.5 * 3600.0)
	var eaten_full := food0_full - full.cargo.qty("food")
	var eaten_strict := food0_strict - strict.cargo.qty("food")
	_check(eaten_strict < eaten_full * 0.6,
		"严格配给吃得少：%d 份 vs 足量 %d 份" % [eaten_strict, eaten_full])
	var fat_full := _avg(full.roster.members.map(func(m): return m.fatigue))
	var fat_strict := _avg(strict.roster.members.map(func(m): return m.fatigue))
	_check(fat_strict > fat_full * 1.15,
		"严格配给更累：疲劳 %.3f vs %.3f（+%.0f%%）" % [
			fat_strict, fat_full, (fat_strict / maxf(fat_full, 1e-6) - 1.0) * 100.0])
	var mood_full := _avg(full.roster.members.map(func(m): return m.mood))
	var mood_strict := _avg(strict.roster.members.map(func(m): return m.mood))
	_check(mood_strict < mood_full - 0.05,
		"严格配给心情更差：%.3f vs %.3f" % [mood_strict, mood_full])
	_check(strict.roster.grumble_count > full.roster.grumble_count,
		"抱怨变多：%d 次 vs %d 次" % [strict.roster.grumble_count, full.roster.grumble_count])
	# 饮水制度同理（水的消耗也要能被规矩改）
	var dry := _v()
	dry.cargo.add("water", 60)
	dry.set_rule("water", "cook_only")
	var w0 := dry.cargo.qty("water")
	var wet := _v()
	wet.cargo.add("water", 60)
	var w0_wet := wet.cargo.qty("water")
	_run(dry, 2.0 * 3600.0)
	_run(wet, 2.0 * 3600.0)
	_check(w0 - dry.cargo.qty("water") < w0_wet - wet.cargo.qty("water"),
		"只够做饭的饮水制度：水消耗 %d 桶 vs 足量 %d 桶" % [
			w0 - dry.cargo.qty("water"), w0_wet - wet.cargo.qty("water")])


# ---------------------------------------------------------------- 3 关系与派系

func _test_relations_and_groups() -> void:
	var v := _v()
	var keys: Array = v.roster.key_crew()
	_check(v.society.relations.size() == keys.size() * (keys.size() - 1) / 2,
		"12 名关键船员之间两两有关系（%d 对）" % v.society.relations.size())
	var a: CrewMember = keys[0]
	var b: CrewMember = keys[1]
	var r0 := float(v.society.relation_between(a.id, b.id)["affinity"])
	var g0 := int(v.society.relation_between(a.id, b.id)["grudge"])
	v.society.bump_relation(a.id, b.id, 0.2, 1)
	var r1 := float(v.society.relation_between(a.id, b.id)["affinity"])
	_check(r1 > r0, "关系能往好处走（%.2f → %.2f）" % [r0, r1])
	_check(int(v.society.relation_between(a.id, b.id)["grudge"]) == g0 + 1,
		"结下的梁子记着（%d → %d）" % [g0, int(v.society.relation_between(a.id, b.id)["grudge"])])
	var report := v.society.faction_report(v.roster)
	_check(report.size() == 3, "三个小群体各有凝聚力与心情（%s）" % report[0])
	# 一起值班 → 关系变好；饿着 → 关系变差（各跑一段，比较方向）
	var warm := _v()
	warm.cargo.add("food", 900)              # 别让人饿着：饿着的话什么关系都会变差
	warm.cargo.add("water", 60)
	for m in warm.roster.key_crew():
		m.job = "sail"
		m.working = true
		warm.society.tension = 0.1
	var before := _avg_affinity(warm)
	_run(warm, 1.0 * 3600.0)
	var after := _avg_affinity(warm)
	_check(after > before,
		"一起干活的人越走越近：全船平均好感 %.3f → %.3f" % [before, after])


func _avg_affinity(v: Voyage) -> float:
	var sum := 0.0
	for k in v.society.relations.keys():
		sum += float(v.society.relations[k]["affinity"])
	return sum / maxf(1.0, float(v.society.relations.size()))


# ---------------------------------------------------------------- 4 验收第 3 条

func _test_events_happen_naturally() -> void:
	"""8 个游戏小时里，事件要**自己**冒出来 —— 不喊任何脚本接口。"""
	var v := _v()
	_run(v, 8.0 * 3600.0)
	_check(v.society.event_count >= 1,
		"8 个游戏小时里自然发生了 %d 次船员事件（最后一条：%s）" % [
			v.society.event_count, v.society.last_event])
	_check(v.society.log_lines.size() > 0, "事件进了船上日志（%s）" % v.society.log_lines[0])
	_check(v.society.tension > 0.1, "紧张度被推起来了（%.0f%%）" % (v.society.tension * 100.0))
	# 逐级递进：同一个社会状态下，紧张度越高，能触发的事件越重
	var v2 := _v()
	v2.society.tension = 0.40
	var e1 := v2.society.pick_event(v2.rules, v2.cargo, false)
	v2.society.tension = 0.70
	var e2 := v2.society.pick_event(v2.rules, v2.cargo, false)
	_check(int(e2.get("severity", 0)) > int(e1.get("severity", 0)),
		"紧张度越高，挑中的事件越重（%s %d → %s %d）" % [
			str(e1.get("id", "")), int(e1.get("severity", 0)),
			str(e2.get("id", "")), int(e2.get("severity", 0))])
	# 严刑 + 禁酒 + 严格配给 = 更快出事（规则真的在推社会）
	var harsh := _v()
	harsh.set_rule("punish", "brutal")
	harsh.set_rule("liquor", "forbidden")
	harsh.set_rule("ration", "strict")
	var mild := _v()
	_run(harsh, 0.5 * 3600.0)
	_run(mild, 0.5 * 3600.0)
	_check(harsh.society.tension > mild.society.tension * 1.2,
		"规矩越紧，紧张度涨得越快（%.3f vs %.3f）" % [
			harsh.society.tension, mild.society.tension])
	var t_harsh := _hours_to_first_event(harsh)
	var t_mild := _hours_to_first_event(mild)
	_check(t_harsh <= t_mild,
		"规矩紧的那一局不晚于宽松的那一局出事（%.1f 小时 vs %.1f 小时）" % [t_harsh, t_mild])


func _hours_to_first_event(v: Voyage) -> float:
	var hours := 0.0
	while hours < 6.0:
		_run(v, 0.25 * 3600.0)
		hours += 0.25
		if v.society.event_count > 0:
			return hours
	return 99.0


# ---------------------------------------------------------------- 5 验收第 2 条

func _test_dilemma_options() -> void:
	var d := Dilemma.new()
	d.setup()
	_check(d.ids().size() == 3, "三个高压抉择（%s）" % ", ".join(d.ids()))
	for id in d.ids():
		var def := d.def_of(id)
		var opts: Array = def.get("options", [])
		_check(opts.size() >= 4, "%s 有 %d 条选项（≥4）" % [str(def.get("name", id)), opts.size()])
		for o in opts:
			_check((o.get("effects", {}) as Dictionary).size() >= 2,
				"%s·%s 的后果是一组数，不是一段文案（%d 项）" % [
					str(def.get("name", id)), str(o.get("name", "")),
					(o.get("effects", {}) as Dictionary).size()])
	# 触发条件：三种都能自己成立
	var food := _v()
	food.cargo.starving = true
	food.dilemmas.check(food)
	_check(food.dilemmas.current() == "food_crisis", "缺粮会弹出「缺粮」（%s）" % food.dilemmas.current())
	var hurt := _v()
	for i in 2:
		hurt.roster.key_crew()[i].health = 0.5
	hurt.dilemmas.check(hurt)
	_check(hurt.dilemmas.current() == "grave_wound", "有人重伤会弹出「重伤病」（%s）" % hurt.dilemmas.current())
	var trib := _v()
	trib.fired["village"] = true
	trib.dilemmas.check(trib)
	_check(trib.dilemmas.current() == "tribal_clash", "接触部落会弹出「部落冲突」（%s）" % trib.dilemmas.current())

	# 选 A 与选 B：状态必须真的不同（拿「缺粮」和「部落冲突」各试一次）
	var a := _v()
	a.cargo.starving = true
	a.dilemmas.check(a)
	var res_a := a.answer_dilemma("share_all")
	_check(bool(res_a.get("ok", false)), "选了「官兵同份」（%s）" % str(res_a.get("text", "")))
	var b := _v()
	b.cargo.starving = true
	b.dilemmas.check(b)
	var res_b := b.answer_dilemma("key_first")
	_check(bool(res_b.get("ok", false)), "另一局选了「先保关键岗位」")
	var mood_a := _avg(a.roster.members.map(func(m): return m.mood))
	var mood_b := _avg(b.roster.members.map(func(m): return m.mood))
	var disc_a := a.society.discipline
	var disc_b := b.society.discipline
	_check(absf(mood_a - mood_b) > 0.05,
		"两个选法的士气不同（%.3f vs %.3f）" % [mood_a, mood_b])
	_check(absf(disc_a - disc_b) > 0.02,
		"两个选法的纪律不同（%.3f vs %.3f）" % [disc_a, disc_b])
	_check(str(a.ending_score) != str(b.ending_score),
		"两个选法的结局分数不同（%s vs %s）" % [str(a.ending_score), str(b.ending_score)])
	_check(a.dilemmas.is_resolved("food_crisis") and b.dilemmas.is_resolved("food_crisis"),
		"答过的抉择会被记住，不会反复问")
	# 部落冲突：交换 vs 开火
	var t1 := _v()
	t1.fired["village"] = true
	t1.dilemmas.check(t1)
	t1.answer_dilemma("trade")
	var t2 := _v()
	t2.fired["village"] = true
	t2.dilemmas.check(t2)
	t2.answer_dilemma("fire")
	_check(int(t1.ending_score["history"]) > int(t2.ending_score["history"]),
		"交换与开火的「历史」分数不同（%d vs %d）" % [
			int(t1.ending_score["history"]), int(t2.ending_score["history"])])
	_check(t1.fired.has("traded_with_locals") and t2.fired.has("shot_at_locals"),
		"两种选法各自留下旗标（%s / %s）" % [
			str(t1.fired.has("traded_with_locals")), str(t2.fired.has("shot_at_locals"))])
	# 开火要真的消耗弹药（M4 的账接上）
	_check(t2.cargo.qty("powder") < t1.cargo.qty("powder"),
		"开火消耗了火药（%d vs %d）" % [t2.cargo.qty("powder"), t1.cargo.qty("powder")])


# ---------------------------------------------------------------- 6 面板要说人话

func _test_why_unhappy() -> void:
	var v := _v()
	var m: CrewMember = v.roster.key_crew()[0]
	m.hunger = 0.8
	m.fatigue = 0.9
	m.health = 0.6
	var why := v.society.why_unhappy(m, v.roster, v.rules)
	_check(why.find("饿") >= 0 and why.find("累") >= 0 and why.find("带伤") >= 0,
		"面板说得出他为什么心情差：%s" % why)
	v.set_rule("ration", "strict")
	var why2 := v.society.why_unhappy(m, v.roster, v.rules)
	_check(why2.find("规矩") >= 0, "规矩压得紧也会写进理由：%s" % why2)
	var happy: CrewMember = v.roster.key_crew()[2]
	happy.hunger = 0.1
	happy.fatigue = 0.1
	happy.health = 1.0
	_check(v.society.why_unhappy(happy, v.roster, v.rules) != "", "心情好的人也有一句话")


# ---------------------------------------------------------------- 7 进存档

func _test_save() -> void:
	var a := _v()
	a.set_rule("ration", "strict")
	_run(a, 3.0 * 3600.0)
	a.cargo.starving = true
	a.dilemmas.check(a)
	a.answer_dilemma("share_all")
	var b := Voyage.new()
	b.setup(GEO)
	b.apply_world_state(a.capture_world_state())
	b.apply_ship_state(a.capture_ship_state())
	_check(b.rules.option_name("ration") == "严格配给", "读档后规矩还在（%s）" % b.rules.option_name("ration"))
	_check(absf(b.society.tension - a.society.tension) < 1e-6,
		"读档后紧张度一致（%.4f）" % b.society.tension)
	_check(str(b.society.relations) == str(a.society.relations), "读档后关系一致")
	_check(str(b.ending_score) == str(a.ending_score), "读档后结局分数一致（%s）" % str(b.ending_score))
	_check(b.dilemmas.is_resolved("food_crisis"), "读档后「答过的抉择」还记着")
	_check(b.roster.grumble_count == a.roster.grumble_count,
		"读档后抱怨计数一致（%d）" % b.roster.grumble_count)


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
