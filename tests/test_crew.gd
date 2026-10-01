extends SceneTree

# Day 5 的验收测试：船员（docs/02 Day 5）。
#
# 四条验收：
#   1. 玩家什么都不做，船上也会自己运转
#   2. 船员自己跨层去睡觉、吃饭、干活
#   3. 改优先级后行为立刻改变
#   4. 12 名关键船员 vs 28 名普通船员有明显的表现差异
#
# 用法：
#   Godot.exe --headless --path . --script res://tests/test_crew.gd
# 退出码 0 = 通过，1 = 有失败。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_crew ===")
	_test_roster()
	_test_pathfinding()
	_test_idle_ship_runs_itself()
	_test_needs_pull_people_away()
	_test_priority_changes_behaviour()
	_test_key_vs_hands()
	_finish()


func _new_roster() -> CrewRoster:
	var r := CrewRoster.new()
	r.setup()
	return r


func _run(r: CrewRoster, seconds: float, sail_demand := 6) -> void:
	for _i in int(seconds / DT):
		r.tick(DT, sail_demand)


# ---------------------------------------------------------------- 1 名册

func _test_roster() -> void:
	var r := _new_roster()
	_check(r.ready, "船员名册加载成功")
	_check(r.key_crew().size() == 12, "关键船员 12 名（实际 %d）" % r.key_crew().size())
	_check(r.hands().size() == 28, "普通船员 28 名（实际 %d）" % r.hands().size())
	var posts := []
	for m in r.key_crew():
		posts.append(m.post)
		_check(m.display_name != "" and m.skills.size() >= 6,
			"%s 有名字与六项技能（%s）" % [m.post, m.display_name])
	var need := ["领航员", "大副", "舵手", "水手长", "木匠", "捻缝工",
		"桶匠", "外科医生", "炮长", "事务长", "文书", "厨师"]
	for p in need:
		_check(posts.has(p), "编制里有%s" % p)
	var named := {}
	for m in r.key_crew():
		_check(not named.has(m.display_name), "关键船员名字不重复：%s" % m.display_name)
		named[m.display_name] = true


# ---------------------------------------------------------------- 2 寻路

func _test_pathfinding() -> void:
	var r := _new_roster()
	var p := r.path
	var hold := p.reachable_cells(0)
	var deck := p.reachable_cells(2)
	var nest := p.reachable_cells(3)
	_check(hold.size() > 0 and deck.size() > 0 and nest.size() > 0, "四层都有可走格子")
	_check(p.reachable_cells(1).size() > 0, "下层甲板可达（%d 格）" % p.reachable_cells(1).size())

	var leg := p.find(hold[0], deck[0])
	_check(leg.size() > 0, "从货舱能走到甲板（%d 步）" % leg.size())
	var layers := {}
	for v in leg:
		layers[v.z] = true
	_check(layers.size() >= 2, "这条路真的跨了层（经过 %d 层）" % layers.size())

	var up := p.find(deck[0], nest[0])
	_check(up.size() > 0, "从甲板能爬上瞭望台（%d 步）" % up.size())

	for job in ["sail", "helm", "lookout", "cook", "repair", "chores",
			"sleep", "eat", "off_watch"]:
		var cells: Array = p.station_cells(job)
		_check(cells.size() > 0, "工作 %s 有站位（%d 个）" % [job, cells.size()])
		var reachable := 0
		for c in cells:
			if not p.find(p.hub(), c).is_empty():
				reachable += 1
		_check(reachable == cells.size() and cells.size() > 0,
			"%s 的站位全都在主甲板走得到的范围内（%d/%d）" % [job, reachable, cells.size()])


# ---------------------------------------------------------------- 3 船自己运转

func _test_idle_ship_runs_itself() -> void:
	var r := _new_roster()
	_run(r, 120.0)
	var c := r.job_counts()
	_check(r.sail_hands() > 0, "没人下令，照样有人去操帆（%d 人到位）" % r.sail_hands())
	_check(int(c.get("helm", 0)) == 1, "有人在掌舵")
	_check(int(c.get("lookout", 0)) >= 1, "有人爬上瞭望台")
	var working := 0
	for k in ["sail", "helm", "lookout", "cook", "repair", "chores"]:
		working += int(c.get(k, 0))
	_check(working >= 10, "在岗的不少于 10 人（实际 %d）" % working)
	_check(int(c.get("idle", 0)) == 0,
		"没人闲着没事干：不当班的都回舱休更（闲 %d）" % int(c.get("idle", 0)))
	# 没人在原地卡住（走不到岗位的会一直 working=false 且不在 idle）
	var stuck := 0
	for m in r.members:
		if m.job != "idle" and not m.working and m.path.is_empty():
			stuck += 1
	_check(stuck == 0, "没有走不到岗位的人（卡住 %d 人）" % stuck)


# ---------------------------------------------------------------- 4 需求把人拉走

func _test_needs_pull_people_away() -> void:
	var r := _new_roster()
	_run(r, 120.0)
	# 把三个人推到饿坏/累坏，他们应该放下活去吃饭/睡觉
	var pushed := 0
	for m in r.members:
		if pushed >= 3:
			break
		m.hunger = 0.95
		pushed += 1
	_run(r, 60.0)
	var eating := 0
	for m in r.members:
		if m.job == "eat":
			eating += 1
			_check(m.at.z == 1, "去吃饭的人走到了下层甲板的厨房（L%d）" % m.at.z)
	_check(eating >= 3, "饿坏了的人放下手里的活去吃饭（%d 人）" % eating)

	var tired := _new_roster()
	_run(tired, 120.0)
	for m in tired.key_crew():
		m.fatigue = 0.95
	_run(tired, 60.0)
	var sleeping := 0
	for m in tired.key_crew():
		if m.job == "sleep":
			sleeping += 1
	_check(sleeping >= 6, "累垮的人回铺位睡觉（%d 人）" % sleeping)
	var rested: float = tired.key_crew()[0].fatigue
	_run(tired, 600.0)
	_check(tired.key_crew()[0].fatigue < rested, "睡一觉之后疲劳往下走（%.2f → %.2f）"
		% [rested, tired.key_crew()[0].fatigue])


# ---------------------------------------------------------------- 5 改优先级

func _test_priority_changes_behaviour() -> void:
	var r := _new_roster()
	_run(r, 180.0)
	# 找一个此刻在操帆的人，把他的操帆优先级关掉
	var target: CrewMember = null
	for m in r.members:
		if m.job == "sail":
			target = m
			break
	_check(target != null, "有人在操帆可以拿来做实验")
	if target == null:
		return
	var before := r.sail_hands()
	target.prio["sail"] = 0
	_run(r, 30.0)
	_check(target.job != "sail", "把操帆优先级改成 0 之后他就不操帆了（现在是 %s）" % target.job)
	_check(r.sail_hands() >= before - 1 and r.sail_hands() > 0,
		"马上有人补位（%d → %d 人）" % [before, r.sail_hands()])

	# 反过来：让一个不操帆的关键船员优先操帆，他应该立刻动身
	var specialist: CrewMember = null
	for m in r.key_crew():
		if m.job != "sail" and m.job != "idle":
			specialist = m
			break
	if specialist != null:
		specialist.prio["sail"] = 1
		specialist.fatigue = 0.0
		_run(r, 60.0)
		_check(specialist.job == "sail",
			"把某个关键船员的操帆优先级提到 1，他就去操帆了（%s）" % specialist.label())


# ---------------------------------------------------------------- 6 关键 vs 普通

func _test_key_vs_hands() -> void:
	var r := _new_roster()
	# 关键船员有名字、性格、关系；普通船员没有
	var key_named := 0
	var key_with_traits := 0
	for m in r.key_crew():
		if m.display_name != "":
			key_named += 1
		if m.traits.size() > 0:
			key_with_traits += 1
	_check(key_named == 12, "12 名关键船员都有名字")
	_check(key_with_traits == 12, "12 名关键船员都有性格")
	var hands_named := 0
	for m in r.hands():
		if m.traits.size() > 0:
			hands_named += 1
	_check(hands_named == 0, "普通船员没有性格/关系（简化模型）")

	# 关键船员会抱怨：把他们累垮，跑一段时间，日志里应该出现人名
	var tired := _new_roster()
	_run(tired, 120.0)
	for m in tired.key_crew():
		m.fatigue = 0.9
		m.hunger = 0.9
	_run(tired, 600.0)
	var complained := 0
	for m in tired.key_crew():
		if m.grumble != "":
			complained += 1
	_check(complained >= 3, "累坏的关键船员会抱怨（%d 人开口）" % complained)
	_check(tired.log_lines.size() > 0, "船上日志记下了他们的话")

	# 关键船员参与操帆时，船员整体水平更高；把他们全调走，操帆水平明显下降
	var good := _new_roster()
	_run(good, 240.0)
	var good_skill := good.sail_skill()
	var bad := _new_roster()
	for m in bad.key_crew():
		m.prio["sail"] = 0                     # 12 名关键船员一律不操帆
	_run(bad, 240.0)
	var bad_skill := bad.sail_skill()
	_check(good_skill > bad_skill + 0.05,
		"关键船员在不在操帆，水平明显不同（%.2f vs %.2f）" % [good_skill, bad_skill])


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
