extends SceneTree

# Day 7 的验收测试：三幕剧情 + 开场/教学 + 航海日志 + 结算 + 节奏（docs/02 Day 7）。
#
# 这一天的产出物大多看不见（文案、演出、引导、结算），所以断言只能落在
# **能被数出来的东西**上：第几幕、触发条件、日志里有没有这件事、结算页里有没有那句话。
# 最后一条是节奏：8 公里的海必须能在 ×12 快进下走完 —— 否则"陌生人 15 分钟"是空话。

const DT := 0.5
const FAST := 12.0               # sea_debug.gd 里最大的一档快进
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_story ===")
	_test_script_data()
	_test_opening_and_tutorial()
	_test_three_acts()
	_test_decision_journal()
	_test_settlement()
	_test_pacing()
	_test_stall_hint()
	_finish()


func _voyage() -> Voyage:
	var v := Voyage.new()
	v.setup()
	return v


func _run(v: Voyage, seconds: float) -> void:
	for _i in int(seconds / DT):
		v.tick(DT)


# ---------------------------------------------------------------- 1 剧本数据

func _test_script_data() -> void:
	var s := Story.new()
	_check(s.load_data(), "剧本 data/story/acts.json 读得出来")
	_check(s.title != "", "有标题（%s）" % s.title)
	_check(s.subtitle != "", "有副标题（%s）" % s.subtitle)
	_check(s.opening_heading != "" and s.opening_body != "",
		"开场有日期与背景正文（%d 字的正文）" % s.opening_body.length())
	_check(s.opening_body.find("掌舵") >= 0 or s.opening_body.find("拉帆") >= 0,
		"开场就交代了'玩家不能直接操船'这件事")
	_check(s.acts.size() == 3, "三幕（%d）" % s.acts.size())
	var ids := PackedStringArray()
	for a in s.acts:
		ids.append(str(a.get("id", "")))
	_check(Array(ids) == ["act1", "act2", "act3"], "三幕按 出港 → 发现岛 → 返航 排序")
	# 每一幕都要有 触发条件 / 文本 / 后果 —— docs/02 Day 7 的产出物定义
	for a in s.acts:
		var name := str(a.get("name", "?"))
		_check(not (a.get("trigger", {}) as Dictionary).is_empty(), "%s 有触发条件" % name)
		_check(str(a.get("text", "")) != "", "%s 有正文" % name)
		_check(str(a.get("objective", "")) != "", "%s 有给玩家的一句话目标" % name)
		_check((a.get("effects", []) as Array).size() > 0, "%s 有后果" % name)
	_check(s.steps.size() == 4, "教学有 4 步（%d）" % s.steps.size())
	for want in ["click_target", "open_sail_panel", "tack"]:
		var found := false
		for st in s.steps:
			if str(st["id"]) == want:
				found = true
		_check(found, "教学里有 %s" % want)


# ---------------------------------------------------------------- 2 开场与引导

func _test_opening_and_tutorial() -> void:
	var v := _voyage()
	_check(v.story.head == -1, "开局还没有演到任何一幕（标题卡阶段）")
	v.tick(DT)
	_check(v.story.head == 0, "第一帧就跑起第一幕（head=%d）" % v.story.head)
	_check(v.story.act_name().find("出港") >= 0, "第一幕是出港（%s）" % v.story.act_name())
	# 演出的弹窗由 Voyage 每帧取走并推给界面（story.take_messages 是空的才对）
	_check(v.story.take_messages().is_empty(), "剧情的弹窗由 Voyage 每帧取走，不留在 Story 里")
	_check(v.last_message.find("第一幕") >= 0 and v.message_timer > 0.0,
		"第一幕会弹一条消息给玩家（%s）" % v.last_message)
	_check(v.log_lines.size() > 0 and v.log_lines[0].find("出发") >= 0,
		"航海日志开篇是出港（%s）" % (v.log_lines[0] if v.log_lines.size() > 0 else "空"))
	# 第一幕的目标点：朝东
	_check(v.story.objective.find("目标点") >= 0,
		"第一幕的目标是点一个目标点（%s）" % v.story.objective)

	var steps := v.story.visible_steps()
	_check(steps.size() == 3, "第一幕只露出一开始的 3 步（%d）" % steps.size())
	for st in steps:
		_check(str(st["id"]) != "land", "登陆那一步要等第二幕才出现")

	# ① 点目标点
	_check(not _step_done(v, "click_target"), "还没点目标点 -> 第 1 步未完成")
	v.orders.set_target_point(Vector2(4790, 3600))
	v.tick(DT)
	_check(_step_done(v, "click_target"), "点了目标点 -> 第 1 步完成")

	# ② 打开帆态面板（只有界面知道，所以走 note 接口）
	_check(not _step_done(v, "open_sail_panel"), "还没开面板 -> 第 2 步未完成")
	v.story.note("open_sail_panel")
	_check(_step_done(v, "open_sail_panel"), "打开帆态面板 -> 第 2 步完成")

	# ③ 抢风：目标点顶风，航海官会自己抢
	_check(v.nav.method == Navigator.Method.BEAT,
		"目标点顶风时航海官选择抢风（%s）" % v.nav.method_name())
	_check(not _step_done(v, "tack"), "才刚开始抢风 -> 第 3 步还没完成")
	_run(v, 6.0)
	_check(_step_done(v, "tack"), "在抢风里待满 5 秒 -> 第 3 步完成")
	_check(v.story.objective.find("目标点") >= 0, "第一幕的目标没有提前被换掉")


func _step_done(v: Voyage, id: String) -> bool:
	for st in v.story.steps:
		if str(st["id"]) == id:
			return bool(st["done"])
	return false


# ---------------------------------------------------------------- 3 三幕顺序

func _test_three_acts() -> void:
	var v := _voyage()
	_run(v, DT)
	_check(v.story.head == 0, "先是第一幕")

	# 第二幕的触发条件是"见过岛"，在那之前不许乱触发
	_run(v, 120.0)
	_check(str(v.story.current_act().get("id", "")) == "act1",
		"还没看见岛，第二幕不许抢戏（现在是 %s）" % v.story.act_name())

	v.orders.set_target_point(Vector2(4520, 3600))
	_run(v, 1500.0)
	_check(v.island_known, "瞭望员报告了陆地")
	_check(str(v.story.current_act().get("id", "")) == "act2",
		"见过岛之后第二幕落下（%s）" % v.story.act_name())
	_check(v.story.objective.find("抛锚") >= 0,
		"第二幕的目标是开到滩头抛锚登陆（%s）" % v.story.objective)
	var texts := ""
	for line in v.log_lines:
		texts += str(line) + "\n"
	_check(texts.find("绿岬岛") >= 0, "第二幕的正文进了航海日志")

	# 还没到港：第三幕不许触发
	_check(not v.story.fired("act3"), "没回港之前第三幕不触发")
	_check(v.story.head == 1, "head 停在第 2 幕（%d）" % v.story.head)


# ---------------------------------------------------------------- 4 抉择与日志

func _test_decision_journal() -> void:
	var v := _voyage()
	var beach := Vector2(4790, 3600)
	v.ship.set_pose(beach + Vector2(-300, 0), 0.0)
	v.orders.set_target_point(beach)
	_run(v, 90.0)
	v.orders.anchored = true
	v.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
	_run(v, 60.0)
	_check(v.story.fired("act2") or v.island_known, "到滩头时第二幕已经在演")
	_check(_step_done(v, "land") == false, "还没登陆 -> 第 4 步未完成")
	var ids := ["piloto", "carpintero", "cirujano", "escribano"]
	v.land(ids, 6)
	_check(v.ashore, "带人上岸")
	_run(v, 1.0)
	_check(_step_done(v, "land"), "登陆之后教学第 4 步完成（第二幕才露出的那一步）")
	_check(v.story.visible_steps().size() <= 4,
		"教学列表不会越堆越长（%d 步）" % v.story.visible_steps().size())

	# 岸上：走到地标 -> 记进航海日志（结算页的"到过的地方"就是它）
	v.move_party_to(Vector2(5620, 3320))
	_run(v, 240.0)
	_check(v.visited.has("ruins"), "走到了内陆遗迹")
	_check(v.journal.landfalls.size() >= 2,
		"航海日志记下了到过的地方（%d 个）" % v.journal.landfalls.size())
	var names := PackedStringArray()
	for lf in v.journal.landfalls:
		names.append(str(lf["name"]))
	_check(Array(names).has("内陆遗迹"), "其中一个是内陆遗迹（%s）" % ", ".join(names))
	_check(v.journal.decisions.size() >= 1,
		"带人上岸被记成一条决定（%d 条）" % v.journal.decisions.size())

	# 回船 -> 目标是返航
	v.move_party_to(beach)
	_run(v, 300.0)
	v.return_to_ship()
	_run(v, 80.0)
	_check(not v.ashore, "全队回到船上")
	_check(v.story.objective.begins_with("返航"),
		"抉择做完，目标换成返航（%s）" % v.story.objective)
	# 回归：回船时**每个人**的上岸标记都要清掉。只清关键船员的话，6 名水手会
	# 永远挂在岸上 —— 船此后一直少 6 双手，结算页还会写"岸上还有 6 人"。
	var still_ashore := 0
	for m in v.roster.members:
		if m.ashore:
			still_ashore += 1
	_check(still_ashore == 0,
		"回船之后所有人都回岗位（关键船员 + 水手，还挂着上岸的有 %d 人）" % still_ashore)
	_check(v.journal.settlement(v, v.story).find("岸上还有") < 0,
		"结算页不会写出'岸上还有 N 人'")

	# 抉择的另一半：不下船 = 也是决定，也要被记下来
	var v2 := _voyage()
	v2.island_known = true
	v2.fired["lookout"] = true
	v2.ship.set_pose(Vector2(700, 1000), 0.0)
	_run(v2, 2.0)
	_check(v2.fired.has("passed_by"), "把岛甩在身后 = 决定不上岸")
	_check(v2.journal.decisions.size() >= 1, "绕过岛也被记成一条决定")
	_check(v2.story.objective.begins_with("返航"), "不下船也会被叫回港结算")


# ---------------------------------------------------------------- 5 结算

func _test_settlement() -> void:
	var v := _voyage()
	# 走一遍：发现岛 → 登陆 → 上岸 → 回船 → 回港
	v.ship.set_pose(Vector2(4790 - 300, 3600), 0.0)
	v.orders.set_target_point(Vector2(4790, 3600))
	_run(v, 120.0)
	v.orders.anchored = true
	v.land(["piloto", "carpintero"], 4)
	_run(v, 120.0)
	v.move_party_to(Vector2(4790 + 830, 3600 - 280))     # 内陆遗迹
	_run(v, 240.0)
	v.ship.apply_damage("hull", 0.28)
	v.move_party_to(Vector2(4790, 3600))
	_run(v, 300.0)
	v.return_to_ship()
	_run(v, 80.0)
	_check(not v.ashore, "回到船上")
	_check(v.journal.distance_m > 0.0, "航程被累计了（%.0f 米）" % v.journal.distance_m)

	# 回港：第三幕的触发条件是"见过岛 + 船开进港区"
	var p0 := v.ship.position_m()
	var u0 := v.ship.speed_ms()
	v.orders.anchored = false
	v.orders.set_target_point(Vector2(700, 4000))
	v.ship.set_pose(Vector2(1000, 4000), 180.0)
	var p1 := v.ship.position_m()
	v.tick(DT)
	_check(v.story.fired("act3"), "船回到出发港 -> 第三幕")
	_check(v.story.ending_ready, "第三幕的后果里带 ending -> 该摊开结算页了")
	# 铁律 5：剧情不许动船。这一帧船确实在动（物理），但绝不能被瞬移
	var moved := v.ship.position_m().distance_to(p1)
	_check(moved < 20.0, "剧情触发没有把船瞬移（这一帧动了 %.1f 米）" % moved)
	_check(absf(v.ship.speed_ms() - u0) < 1.0, "剧情触发没有把船速清零")
	_check(p0 != p1, "（测试自己摆过一次船，所以航程要靠瞬移过滤）")
	_check(v.journal.teleports >= 1, "瞬移没被算进航程（过滤掉 %d 次）" % v.journal.teleports)

	var text := v.journal.settlement(v, v.story)
	for want in ["环球航行 · 航行结算", "【到过的地方】", "【你做的决定】",
			"【船与人】", "【文书最后写下的一条】"]:
		_check(text.find(want) >= 0, "结算页有 %s" % want)
	_check(text.find("内陆遗迹") >= 0, "结算页写出了到过的地标")
	_check(text.find("登陆") >= 0, "结算页写出了玩家的决定")
	_check(text.find("船体 28%") >= 0, "结算页写出了船体损伤")
	_check(text.find("累") >= 0, "结算页写出了船员状态")
	_check(text.find("风把帆吹平了") >= 0, "结算页最后一条来自剧本（不是现编的）")
	_check(text.split("\n").size() > 12, "结算页是有内容的一页（%d 行）" % text.split("\n").size())


# ---------------------------------------------------------------- 6 节奏

func _test_pacing() -> void:
	"""8 公里的海，×12 快进下必须能在 15 分钟里走完。

	这是 docs/01 支柱 6 的最终验收"陌生人 15 分钟玩完"的**可计算的那一半**：
	航程时间 ÷ 最大快进倍率 = 玩家真的坐在屏幕前等的时间。
	"""
	var v := _voyage()
	v.orders.set_target_point(Vector2(4790, 3600))
	var t := 0.0
	while t < 4000.0 and v.ship.position_m().distance_to(Vector2(4790, 3600)) > 400.0:
		v.tick(DT)
		t += DT
	_check(t < 4000.0, "船能自己开到滩头（用了 %.1f 分钟游戏时间）" % (t / 60.0))
	var outbound := t

	v.orders.anchored = true
	v.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
	_run(v, 20.0)
	v.orders.anchored = false
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(Vector2(700, 4000))
	var t2 := 0.0
	while t2 < 4000.0 and v.ship.position_m().distance_to(Vector2(700, 4000)) > 340.0:
		v.tick(DT)
		t2 += DT
	_check(t2 < 4000.0, "船也能自己开回港（用了 %.1f 分钟游戏时间）" % (t2 / 60.0))

	var real := (outbound + t2) / FAST / 60.0
	print("  航程合计 %.1f 分钟游戏时间；×%.0f 快进 = %.1f 分钟真实时间" % [
		(outbound + t2) / 60.0, FAST, real])
	_check(real < 6.0, "来回航程在 ×%.0f 下只要 %.1f 分钟真实时间 —— 15 分钟够用" % [FAST, real])
	# 来回的直线距离约 8.2 公里，但船在离滩头 400 米 / 离港 340 米处就算"到了"
	_check(v.journal.distance_km() > 7.0,
		"航程累计正确（%.1f 公里）" % v.journal.distance_km())
	_check(v.nav.beat_count > 0,
		"这一趟真的抢过风（%d 段）—— 面板与结算页上的数字不再是死的" % v.nav.beat_count)


# ---------------------------------------------------------------- 6 卡住了要说人话

func _test_stall_hint() -> void:
	"""船朝目标点磨不出前进的时候，界面必须说一句人话。

	背景：v0.5 验收第 4 条是"陌生人 15 分钟能上手"，而实测过一种卡法 —— 目标点正好在
	正逆风上时，航海官在离港 2–3 公里处磨不出净前进（`docs/21` 第 4.6 节）。
	**要不要改操法是用户的决定**（`docs/07` 待决问题），这里守的是另一半：
	玩家不该卡住了还不知道自己卡住了。
	"""
	# ① 无风带：船根本走不动 → 说"没什么风"
	var a := Voyage.new()
	a.setup(GEO)
	a.wind.time_scale = 0.0
	a.wind.gust_gain = 0.0
	a.wind.base_tws = 1.0
	a.wind.tws_ms = 1.0
	# 目标点摆在**洋流的上游**：不然船会被水流带着慢慢"前进"，就不算卡住了
	var cur := a.sea.current_at(a.ship.position_m())
	var away := Vector2(3000.0, 0.0) if cur.length() < 1e-6 else -cur.normalized() * 3000.0
	a.orders.set_target_point(a.ship.position_m() + away)
	var t0 := a.ship.position_m().distance_to(a.orders.target_point)
	_run(a, 600.0)
	var t1 := a.ship.position_m().distance_to(a.orders.target_point)
	_check(_count_text(a.log_lines, "没什么风") == 1,
		"没风的时候说一次\"没什么风\"（净前进 %.0f m，日志 %d 行）" % [t0 - t1, a.log_lines.size()])

	# ② 正逆风：目标点就在风来的方向上 → 说"点偏一点，或者按 N 沿航线走"
	var b := Voyage.new()
	b.setup(GEO)
	b.wind.time_scale = 0.0
	b.wind.gust_gain = 0.0
	b.wind.base_tws = 8.0
	b.wind.tws_ms = 8.0
	var goal := b.default_destination()
	var bearing := rad_to_deg((goal - b.ship.position_m()).angle())
	b.wind.base_from_dir = bearing
	b.wind.from_dir_deg = bearing
	b.orders.set_target_point(goal)
	var d0 := b.ship.position_m().distance_to(goal)
	var t := 0.0
	while t < 2400.0 and _count_text(b.log_lines, "正对着风") == 0:
		b.tick(DT)
		t += DT
	var d1 := b.ship.position_m().distance_to(goal)
	print("  正逆风：%.0f 秒里离目标 %.0f m → %.0f m（净前进 %.0f m）" % [
		t, d0, d1, d0 - d1])
	_check(_count_text(b.log_lines, "正对着风") == 1,
		"正逆风磨不出前进时给出提示（%.0f 秒，净前进 %.0f m）" % [t, d0 - d1])
	# 提示只出一次：再跑一段，不该刷屏
	_run(b, 600.0)
	_check(_count_text(b.log_lines, "正对着风") == 1,
		"卡住期间只提示一次，不刷屏（%d 行）" % _count_text(b.log_lines, "正对着风"))


func _count_text(lines: Array, needle: String) -> int:
	var n := 0
	for line in lines:
		if str(line).find(needle) >= 0:
			n += 1
	return n


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
