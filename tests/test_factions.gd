extends SceneTree

# M11 的验收测试：势力 · 追捕 · 外交（docs/23 的 M11 卡片、docs/22 第 8–9 章）。
#
# 六件事：
#   1. 真源自检：六类势力、三档阈值、三条王室命令、六环追捕、四种手段。
#   2. **态度必须"有后果"**：行为跨过阈值 → 换档 → 行为跟着变（可断言的链）。
#   3. 追捕六环：每一环都能进、能出；同样的输入必得同样的环（确定性）。
#   4. 四种手段：改线/伪装/谈判各退几环、各付什么；付不起就不生效；"战斗"交给海战。
#   5. 王室命令：完成与违抗**两条路**都能改结局档位。
#   6. 存档：态度、命令状态、追捕环往返一致；游戏里接得上。

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_factions ===")
	_test_truth_source()
	_test_attitude_matters()
	_test_pursuit_rings()
	_test_pursuit_actions()
	_test_royal_orders()
	_test_save_contract()
	_test_voyage_wiring()
	_test_npc_ships()
	_test_eastern_outposts()
	_finish()


func _money(n := 2000) -> Cargo:
	var c := Cargo.new()
	c.setup(27.0, false)
	c.money = n
	c.add("canvas", 10)
	c.add("spice_free_slot", 0)
	return c


# ---------------------------------------------------------------- 1 真源

func _test_truth_source() -> void:
	_check(Factions.ids().size() == 6, "六类势力（%d）" % Factions.ids().size())
	for want in ["castile", "portugal", "locals", "merchants", "pirates", "sailors"]:
		_check(Factions.ids().has(want), "势力表里有 %s" % want)
	var b := Factions.bands()
	_check(float(b.get("hostile_max", 0.0)) < float(b.get("friendly_min", 1.0)),
		"三档阈值是单调的（敌对 < %.2f < 友善）" % float(b.get("hostile_max", 0.0)))
	_check(Factions.orders().size() == 3, "三条王室命令（%d）" % Factions.orders().size())
	_check(Pursuit.ring_count() == 6, "追捕六环（%d）" % Pursuit.ring_count())
	_check(Pursuit.waters().size() >= 3, "葡萄牙水域有 %d 处据点" % Pursuit.waters().size())
	_check(Pursuit.actions().size() == 4, "四种手段（%d）" % Pursuit.actions().size())
	# 每一环都写了节奏（进下一环要待多少天）
	for i in Pursuit.ring_count():
		var r: Dictionary = Pursuit.rings()[i]
		_check(r.has("after_days"), "第 %d 环 %s 有节奏" % [i + 1, str(r.get("id"))])


# ---------------------------------------------------------------- 2 态度有后果

func _test_attitude_matters() -> void:
	var f := Factions.new()
	f.setup()
	var castile0 := f.value("castile")
	_check(f.stance("castile") == Culture.FRIENDLY or f.stance("castile") == Culture.NEUTRAL,
		"开局卡斯蒂利亚不是敌对（%s）" % f.stance("castile"))
	# 毁一次约：态度掉，而且跨档
	var changed := []
	for i in 6:
		changed = f.react_all("break_faith", 1)
	_check(f.value("castile") < castile0, "毁约会掉卡斯蒂利亚的态度（%.2f → %.2f）"
		% [castile0, f.value("castile")])
	_check(f.stance("castile") == Culture.HOSTILE, "毁得够多就翻脸（%s，%.2f）"
		% [f.stance("castile"), f.value("castile")])
	_check(changed.size() >= 2, "同一个行为会被多个势力看见（%d 家变了）" % changed.size())
	# 每个势力**各自**的反应不一样：葡萄牙对"打"比卡斯蒂利亚敏感
	_check(absf(Factions.reaction("portugal", "kill")) > absf(Factions.reaction("castile", "kill")),
		"葡萄牙比卡斯蒂利亚更在乎你动手（%.2f vs %.2f）"
		% [Factions.reaction("portugal", "kill"), Factions.reaction("castile", "kill")])
	# 当地文明：多群体各自一条记录，汇总成"总体印象"
	var cu := Culture.new()
	cu.setup()
	cu.ensure("green_cape", "绿岬岛")
	cu.ensure("inland_folk", "内陆的人")
	cu.react("green_cape", "trade", "换东西")
	cu.react("inland_folk", "kill", "打了一架")
	var overall := f.locals_overall(cu)
	_check(cu.stance("green_cape") != cu.stance("inland_folk"),
		"同一座岛上两个群体的态度可以不一样（%s vs %s）"
		% [cu.stance("green_cape"), cu.stance("inland_folk")])
	_check(overall > 0.0 and overall < 1.0, "总体印象是两个群体的平均（%.2f）" % overall)


# ---------------------------------------------------------------- 3 追捕六环

func _test_pursuit_rings() -> void:
	var p := Pursuit.new()
	p.setup()
	_check(not p.active(), "开局没被盯上")
	# 进水域 → 一环一环往上
	var seq := []
	p.tick(0.0, true)
	seq.append(p.ring)
	for i in 3:
		p.tick(1.0, true)
		seq.append(p.ring)
	_check(seq[0] == 1, "进水域第一刻就被发现（第 %d 环）" % seq[0])
	_check(p.ring >= 3, "在他們的水域里待三天，环数往上走（第 %d 环）" % p.ring)
	# 一直待到被攻击
	var guard := 0
	while p.ring < Pursuit.ring_count() and guard < 60:
		p.tick(1.0, true)
		guard += 1
	_check(p.ring == Pursuit.ring_count(), "待下去最终会被攻击（第 %d 环 = %s）"
		% [p.ring, Pursuit.ring_name(p.ring)])
	_check(p.times_attacked == 1, "被攻击记一次（%d）" % p.times_attacked)
	# 离开水域够久 → 甩掉
	p.tick(float(Pursuit.config().get("escape_days", 3.0)) + 0.1, false)
	_check(not p.active(), "离开水域够久就甩掉了（第 %d 环）" % p.ring)
	_check(p.times_escaped == 1, "甩掉记一次（%d）" % p.times_escaped)
	# 确定性：同样的输入必得同样的环
	var a := Pursuit.new()
	var b := Pursuit.new()
	a.setup()
	b.setup()
	for i in 5:
		a.tick(0.7, true)
		b.tick(0.7, true)
	_check(a.ring == b.ring and is_equal_approx(a.days_in_ring, b.days_in_ring),
		"同样的输入 → 同样的环与天数（%d / %.2f vs %d / %.2f）"
		% [a.ring, a.days_in_ring, b.ring, b.days_in_ring])
	# 中途走开：环不会自己涨
	var c := Pursuit.new()
	c.setup()
	c.tick(0.5, true)
	var ring_at := c.ring
	c.tick(10.0, false)
	_check(c.ring < ring_at or not c.active(), "走开了就不会继续往上（第 %d 环）" % c.ring)


# ---------------------------------------------------------------- 4 四种手段

func _test_pursuit_actions() -> void:
	var p := Pursuit.new()
	p.setup()
	while p.ring < 4:
		p.tick(1.0, true)
	var before := p.ring
	var cargo := _money(2000)
	# 谈判：退三环，花 300 金币
	var money_before := cargo.money
	var r := p.act("negotiate", cargo)
	_check(bool(r.get("ok", false)), "能谈（%s）" % str(r))
	_check(p.ring == before - 3, "谈判退三环（%d → %d）" % [before, p.ring])
	_check(cargo.money < money_before, "谈判要花钱（%d → %d）" % [money_before, cargo.money])
	# 伪装：退两环，花一匹帆布
	p.ring = 4
	var canvas_before := cargo.qty("canvas")
	var r2 := p.act("disguise", cargo)
	_check(bool(r2.get("ok", false)) and p.ring == 2, "伪装退两环（→ %d）" % p.ring)
	_check(cargo.qty("canvas") < canvas_before, "伪装要动帆布（%d → %d）"
		% [canvas_before, cargo.qty("canvas")])
	# 改线：退一环，不花钱
	p.ring = 3
	var r3 := p.act("dodge", cargo)
	_check(bool(r3.get("ok", false)) and p.ring == 2, "改线退一环（→ %d）" % p.ring)
	# 战斗：交给海战
	p.ring = 5
	var r4 := p.act("fight", cargo)
	_check(bool(r4.get("ok", false)) and bool(r4.get("battle", false)), "战斗这一条交给海战")
	# 付不起就不生效（一点不扣）
	var poor := Cargo.new()
	poor.setup(27.0, false)
	poor.money = 10
	p.ring = 5
	var r5 := p.act("negotiate", poor)
	_check(not bool(r5.get("ok", false)), "付不起就谈不成（%s）" % str(r5.get("reason", "")))
	_check(p.ring == 5, "谈不成环数不动（%d）" % p.ring)


# ---------------------------------------------------------------- 5 王室命令

func _test_royal_orders() -> void:
	# 完成：把货备够 + 到过香料群岛
	var done := Factions.new()
	done.setup()
	var ctx_ok := {"visited_ports": ["tidore"], "goods_value": 900.0, "friendly_kills": 0}
	var score_ok := {"history": 0.0}
	var r := done.settle_orders(ctx_ok, score_ok)
	_check((r.get("done", []) as Array).size() == 3, "三条都做到就全部结算（%d）"
		% (r.get("done", []) as Array).size())
	_check(float(score_ok["history"]) > 0.0, "做到命令 → 历史与政治成果加（%.3f）"
		% float(score_ok["history"]))
	# 违抗：动过手 + 没到香料群岛 + 货舱空
	var broken := Factions.new()
	broken.setup()
	var ctx_bad := {"visited_ports": [], "goods_value": 0.0, "friendly_kills": 2}
	var score_bad := {"history": 0.0}
	var r2 := broken.settle_orders(ctx_bad, score_bad)
	_check((r2.get("broken", []) as Array).has("不得私自改变远征目的"),
		"动过手就记违抗（%s）" % str(r2.get("broken")))
	_check(float(score_bad["history"]) < 0.0, "违抗 → 历史与政治成果扣（%.3f）"
		% float(score_bad["history"]))
	_check(str(broken.order_state["hold_course"]) == "broken", "违抗那条被标成 broken")
	# 只结算一次（再结算不重复加）
	var before := float(score_ok["history"])
	done.settle_orders(ctx_ok, score_ok)
	_check(is_equal_approx(before, float(score_ok["history"])), "同一条命令不重复结算（%.3f）"
		% float(score_ok["history"]))


# ---------------------------------------------------------------- 6 存档契约

func _test_save_contract() -> void:
	var f := Factions.new()
	f.setup()
	f.react_all("trade", 2)
	f.order_state["find_passage"] = "done"
	var p := Pursuit.new()
	p.setup()
	p.tick(1.0, true)
	p.tick(1.0, true)
	var d := {"factions": f.capture_state(), "pursuit": p.capture_state()}
	var f2 := Factions.new()
	var p2 := Pursuit.new()
	f2.apply_state(d["factions"])
	p2.apply_state(d["pursuit"])
	_check(is_equal_approx(f2.value("castile"), f.value("castile")),
		"态度往返一致（%.3f）" % f2.value("castile"))
	_check(str(f2.order_state["find_passage"]) == "done", "命令状态往返一致")
	_check(p2.ring == p.ring and is_equal_approx(p2.days_in_ring, p.days_in_ring),
		"追捕环往返一致（第 %d 环 / %.2f 天）" % [p2.ring, p2.days_in_ring])
	# 老存档缺一家势力 → 补默认值，而不是让它没有这家
	var f3 := Factions.new()
	f3.apply_state({"attitude": {"castile": 0.9}, "order_state": {}, "history": []})
	_check(f3.attitude.size() >= Factions.ids().size(),
		"缺的势力会补默认值（%d 家）" % f3.attitude.size())


# ---------------------------------------------------------------- 7 游戏里接得上

func _test_voyage_wiring() -> void:
	var v := Voyage.new()
	# 用大西洋：这一节要验"船在葡萄牙的水域里 → 追捕一环一环往上 → 最后打起来"，
	# 而迷你海域里没有佛得角（也没有别的船）。
	v.setup(Sea.ATLANTIC_PATH)
	_check(v.factions.attitude.size() == 6, "Voyage 里带着六家势力（%d）"
		% v.factions.attitude.size())
	_check(not v.pursuit.active(), "开局没被追")
	# 世界状态里有这两块（存档契约；test_save 会逐字段核对）
	var ws := v.capture_world_state()
	_check(ws.has("factions") and ws.has("pursuit"), "世界状态里有 factions 与 pursuit")
	# 追捕：直接喂"在葡萄牙水域里"的天数（航程日）
	v.pursuit.tick(2.5, true)
	_check(v.pursuit.active(), "在葡萄牙水域待了 2.5 天 → 被盯上（%s）" % v.pursuit.describe())
	var r := v.pursuit_action("dodge")
	_check(bool(r.get("ok", false)), "游戏里能下令改线（%s）" % str(r))
	# 追到最后一环就是"被攻击" —— 该真的打起来（追捕与海战接上）
	# 把船摆到**佛得角**（葡萄牙的水域），然后让 Voyage 自己一天一天地推 ——
	# 走的是真实的那条链：位置 → 在不在水域 → 环 → 开火。
	var day := 86400.0 / VoyageJournal.voyage_time_scale
	var santiago := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "santiago":
			santiago = Geom2D.centroid(p["shape"])
	v.ship.set_pose(santiago, 0.0)
	_check(v.in_portuguese_waters(), "佛得角外海算葡萄牙的水域")
	var guard := 0
	while v.pursuit.ring < Pursuit.ring_count() and guard < 20:
		v._pursuit_tick(day)
		guard += 1
	_check(v.pursuit.ring == Pursuit.ring_count(), "一天一天推到最后那一环（第 %d 环）"
		% v.pursuit.ring)
	_check(v.naval != null, "追到「被攻击」那一环，葡萄牙人真的开火（naval=%s）"
		% ("有" if v.naval != null else "没有"))
	# 王室命令：货舱里备够值钱的东西 → 那条命令能结出来
	var ctx := v.royal_order_ctx()
	_check(ctx.has("visited_ports") and ctx.has("goods_value") and ctx.has("friendly_kills"),
		"命令的判定材料齐（%s）" % str(ctx.keys()))
	v.cargo.add("brazilwood", 40)          # 40 捆 × 18 = 720 杜卡特
	var before := float(v.ending_score.get("history", 0.0))
	var res := v.settle_royal_orders()
	_check((res.get("done", []) as Array).has("带回足以证明这次远征的东西"),
		"货舱值 600 以上就是交得出账（%s）" % str(res.get("done")))
	_check(float(v.ending_score.get("history", 0.0)) > before,
		"结算把分加进了历史与政治成果（%.3f → %.3f）"
		% [before, float(v.ending_score.get("history", 0.0))])


# ---------------------------------------------------------------- 收尾

func _test_eastern_outposts() -> void:
	"""M14：葡萄牙在东方的**据点**、据点外的**巡逻**、以及**通行许可**。

	追捕线本来就有"四个水域"，这一节验的是：那三处东方据点真的接在同一条状态机上，
	而且"花钱买路"这条手段能**关掉**巡逻的眼睛。
	"""
	var ops := Pursuit.outposts()
	_check(ops.size() == 3, "三处东方据点（%d）" % ops.size())
	var ids := []
	for o in ops:
		ids.append(str(o.get("port", "")))
	for want in ["mozambique", "malacca", "tidore"]:
		_check(ids.has(want), "据点名单里有 %s" % want)
	_check(Pursuit.permit_days() > 0.0, "通行许可有期限（%.0f 天）" % Pursuit.permit_days())

	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	# 把船摆在马六甲据点**水域之内**
	var malacca := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "malacca":
			malacca = Geom2D.centroid(p["shape"])
	v.ship.set_pose(malacca, 90.0)
	_check(v.in_portuguese_waters(), "马六甲据点水域里就算被看见")
	# 挪到水域之外、但还在**巡逻**的发现距离里。
	# ⚠️ 这个世界是**压缩**的（1 经度 = 889 米），几个据点彼此只隔十几公里 ——
	# 所以不能"朝东挪 15 公里"就算了，得找一个真的在**所有**水域圈之外的点。
	var offshore := Vector2.ZERO
	var found_spot := false
	var probes := [malacca]
	for p in v.sea.ports():
		if str(p.get("id", "")) in ["tidore", "mozambique"]:
			probes.append(Geom2D.centroid(p["shape"]))
	for c in probes:
		for k in 72:
			var p2 := v.sea.wrap_pos((c as Vector2) + Vector2(
				cos(TAU * float(k) / 72.0), sin(TAU * float(k) / 72.0))
				* (Pursuit.water_radius_m() + 1500.0))
			v.ship.set_pose(p2, 90.0)
			var w1 := v._portuguese_watch()
			if not bool(w1["in_waters"]) and bool(w1["by_patrol"]):
				offshore = p2
				found_spot = true
				break
		if found_spot:
			break
	_check(found_spot, "找得到一处「在水域外、仍在巡逻范围内」的水面")
	v.ship.set_pose(offshore, 90.0)
	var watch := v._portuguese_watch()
	_check(bool(watch["by_patrol"]) and not bool(watch["in_waters"]),
		"绕到水域外一千五百米，巡逻还看得见（%s）" % str(watch["outpost"]))
	# 追捕线真的会因此启动（连着待够一天就进第一环）
	v.encounters_enabled = true          # `_pursuit_tick` 尊重这个开关（世界事件那条线）
	v._pursuit_tick(60.0 * 86400.0 / VoyageJournal.voyage_time_scale)
	_check(v.pursuit.active(), "巡逻看见你 → 追捕线启动（%s）" % v.pursuit.describe())

	# 通行许可：在据点买，三十天之内巡逻当没看见你
	v.docked_port = "malacca"
	v.cargo.money = 2000
	var money_before := v.cargo.money
	var r := v.buy_permit()
	_check(bool(r.get("ok", false)), "在据点买得到通行许可（%s）" % str(r.get("reason", "")))
	_check(v.cargo.money == money_before - int(r.get("cost", 0)), "许可花了 %d 杜卡特" % int(r.get("cost", 0)))
	_check(v.pursuit.has_permit(), "许可生效（还剩 %.0f 天）" % v.pursuit.permit_days_left)
	_check(not bool(v._portuguese_watch()["by_patrol"]), "有许可时巡逻不再报你")
	var ring_before := v.pursuit.ring
	v._pursuit_tick(2.0 * 86400.0 / VoyageJournal.voyage_time_scale)
	_check(v.pursuit.ring <= ring_before, "有许可时追捕线不往前推（第 %d 环）" % v.pursuit.ring)
	var again := v.buy_permit()
	_check(not bool(again.get("ok", false)), "许可没到期不能再买（%s）" % str(again.get("reason", "")))
	# 许可到期之后，巡逻重新看得见
	v.pursuit.permit_days_left = 0.0
	v.ship.set_pose(offshore, 90.0)
	_check(bool(v._portuguese_watch()["by_patrol"]), "许可到期后巡逻又看得见你")

	# 存档：许可的剩余天数跟着世界状态走
	var d := v.pursuit.capture_state()
	var v2 := Voyage.new()
	v2.setup(Sea.GLOBAL_PATH)
	v2.pursuit.apply_state(d)
	_check(is_equal_approx(v2.pursuit.permit_days_left, v.pursuit.permit_days_left),
		"许可剩余天数进得了存档（%.1f → %.1f）" % [
			v.pursuit.permit_days_left, v2.pursuit.permit_days_left])

# ---------------------------------------------------------------- 8 NPC 船与"被截击"

func _test_npc_ships() -> void:
	var v := Voyage.new()
	# ⚠️ 用**大西洋**：NPC 船是**世界数据**（世界文件的邻居 npcs.json），
	#    8km 的迷你海域（教程与回归用）里一条别的船都没有 —— 这是有意的。
	v.setup(Sea.ATLANTIC_PATH)
	_check(v.npcs.ships.size() == 4, "海上有四条别的船（%d）" % v.npcs.ships.size())
	_check(v.npcs.count_of("pirate") == 2, "其中两条海盗（%d）" % v.npcs.count_of("pirate"))
	_check(v.npcs.count_of("merchant") == 1, "一条商船（%d）" % v.npcs.count_of("merchant"))
	# 巡逻：动起来，而且不出界
	var before: Vector2 = v.npcs.ships[0]["pos"]
	for i in 20:
		v.npcs.tick(1.0, v.sea)
	var after: Vector2 = v.npcs.ships[0]["pos"]
	_check(before.distance_to(after) > 1.0, "NPC 船在动（%.0f 米）" % before.distance_to(after))
	_check(v.sea.in_bounds(after), "走完还在世界里（%s）" % str(after))
	# 确定性：同样的一段时间 → 同样的位置
	var v2 := Voyage.new()
	v2.setup(Sea.ATLANTIC_PATH)
	for i in 20:
		v2.npcs.tick(1.0, v2.sea)
	_check((v2.npcs.ships[0]["pos"] as Vector2).distance_to(after) < 0.001,
		"同样的时间走同样的路（差 %.4f 米）"
		% (v2.npcs.ships[0]["pos"] as Vector2).distance_to(after))
	# **被海盗截击**：把船摆到海盗边上，一 tick 就该打起来
	var pirate_pos: Vector2 = v.npcs.ships[0]["pos"]
	v.ship.set_pose(pirate_pos, 90.0)
	v.tick(0.5)
	_check(v.naval != null, "海盗够近就咬上来（naval=%s）" % ("有" if v.naval != null else "没有"))
	# 商人不会动手：换一条船，摆到商船边上
	var v3 := Voyage.new()
	v3.setup(Sea.ATLANTIC_PATH)
	var merch := {}
	for s in v3.npcs.ships:
		if str(s["kind"]) == "merchant":
			merch = s
	_check(not merch.is_empty(), "找得到那条商船")
	v3.ship.set_pose(merch["pos"], 90.0)
	v3.tick(0.5)
	_check(v3.naval == null, "商船不会开打（只是擦肩而过）")
	# 但如果你把商人惹到翻脸，他也会拦你（态度链接上了"谁算敌人"）
	for i in 8:
		v3.factions.react_all("fire", 1)
	_check(v3.factions.stance("merchants") == Culture.HOSTILE,
		"动手够多 → 商人也翻脸（%s）" % v3.factions.stance("merchants"))
	v3.npcs.ships[2]["cooldown"] = 0.0
	v3._npc_cooldown = 0.0
	v3.tick(0.5)
	_check(v3.naval != null, "翻脸之后的商船会拦你（naval=%s）"
		% ("有" if v3.naval != null else "没有"))
	# 遭遇之后有冷却：不会一直咬
	_check(float(v.npcs.ships[0]["cooldown"]) > 0.0,
		"打完一场之后那条船进入冷却（%.0f 秒）" % float(v.npcs.ships[0]["cooldown"]))
	# 存档往返
	var d := v.npcs.capture_state()
	var v4 := Voyage.new()
	v4.setup(Sea.ATLANTIC_PATH)
	v4.npcs.apply_state(d)
	var p1: Vector2 = v.npcs.ships[1]["pos"]
	var p2: Vector2 = v4.npcs.ships[1]["pos"]
	_check(p1.distance_to(p2) < 0.001, "NPC 船的位置往返一致（差 %.4f 米）" % p1.distance_to(p2))
	# 迷你海（教程/回归）里没有别的船 —— 这是"世界数据"这条设计的一部分
	var mini := Voyage.new()
	mini.setup(Sea.DATA_PATH)
	_check(mini.npcs.ships.is_empty(), "8km 的迷你海域里没有海盗（%d）" % mini.npcs.ships.size())

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
