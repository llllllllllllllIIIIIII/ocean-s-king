extends SceneTree

# M14 的验收：东方贸易网 · 知识可交易 · 招募（docs/23 的 M14 卡片）。
#
# 五件事：
#   1. 真源：四种东方货 + 知识价目表。
#   2. **价差真实**（验收第 1 条）：产地的买价 × 3 以上才到欧洲的卖价，
#      而且卖一件的利润够付"四十个人一天"的补给账单。
#   3. **买卖守恒**（验收第 2 条）：钱、货、港口库存三本账对得上。
#   4. **知识可交易**（验收第 3 条）：卖出后有可断言的行为变化（商人态度、世界记忆）。
#   5. **招募**（验收第 4 条）：有岗位、有技能、进存档、进生还人数。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_trade_network ===")
	_test_truth_source()
	_test_spread()
	_test_conservation()
	_test_knowledge_trade()
	_test_recruit()
	_test_two_stage_trade()
	_test_indian_pool()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	return v


# ---------------------------------------------------------------- 1 真源

func _test_truth_source() -> void:
	var d := Cargo.defs_data()
	var ids := []
	for it in d.get("items", []):
		ids.append(str(it.get("id", "")))
	for want in ["cloves", "nutmeg", "silk", "porcelain"]:
		_check(ids.has(want), "东方货里有 %s" % want)
	_check((d.get("knowledge_price", {}) as Dictionary).has("chart"), "知识价目表里有海图价")

	var v := _v()
	_check(v.ports.has_port("tidore") and v.ports.has_port("sanlucar"), "产地与销地都在港口表里")
	_check(v.ports.trades("tidore").has("cloves"), "摩鹿加的港口做丁香的生意")
	_check(v.ports.trades("sanlucar").has("cloves"), "塞维利亚收丁香")


# ---------------------------------------------------------------- 2 价差

func _test_spread() -> void:
	var v := _v()
	var buy := v.ports.buy_price("tidore", "cloves")
	var sell := v.ports.sell_price("sanlucar", "cloves")
	_check(sell >= buy * 3, "产地与欧洲的价差够大（买 %d → 卖 %d，%.1f 倍）"
		% [buy, sell, float(sell) / maxf(1.0, float(buy))])
	# 一件的利润 vs 四十个人一天的补给账单（食物 1 份/人 + 淡水 3 升/人）
	var food_price := v.ports.buy_price("tidore", "food")
	var water_price := v.ports.buy_price("tidore", "water")
	var day_cost := food_price * 40 + water_price * 2      # 一桶 60 升，一天两桶
	_check(sell - buy > day_cost, "卖一件丁香的利润（%d）够付四十个人一天的补给（%d）"
		% [sell - buy, day_cost])
	# 港口面板的"什么好买"也认得出来
	var best: Dictionary = v.ports.best_trades("tidore", 4)
	_check((best.get("buy", []) as Array).has("cloves"), "摩鹿加面板上「丁香」是本地便宜货")
	var best_s: Dictionary = v.ports.best_trades("sanlucar", 4)
	_check((best_s.get("sell", []) as Array).has("cloves"), "塞维利亚面板上「丁香」是俏货")


# ---------------------------------------------------------------- 3 守恒

func _test_conservation() -> void:
	var v := _v()
	var stock_before := v.ports.stock_of("tidore", "cloves")
	var money_before := v.cargo.money
	var r := v.ports.buy("tidore", "cloves", 10, v.cargo)
	_check(bool(r.get("ok", false)), "在摩鹿加买下十袋丁香（%s）" % str(r.get("reason", "")))
	var cost := int(r.get("cost", 0))
	_check(v.ports.stock_of("tidore", "cloves") == stock_before - 10,
		"港口库存少了十袋（%d → %d）" % [stock_before, v.ports.stock_of("tidore", "cloves")])
	_check(v.cargo.money == money_before - cost, "钱正好少了一单（%d → %d）" % [money_before, v.cargo.money])
	_check(v.cargo.qty("cloves") == 10, "船上多了十袋丁香")

	var stock2 := v.ports.stock_of("sanlucar", "cloves")
	var money2 := v.cargo.money
	var r2 := v.ports.sell("sanlucar", "cloves", 10, v.cargo)
	_check(bool(r2.get("ok", false)), "在塞维利亚卖掉这十袋（%s）" % str(r2.get("reason", "")))
	var gain := int(r2.get("gain", 0))
	_check(v.ports.stock_of("sanlucar", "cloves") == stock2 + 10, "港口库存多了十袋")
	_check(v.cargo.money == money2 + gain, "钱进来了（+%d）" % gain)
	_check(v.cargo.qty("cloves") == 0, "船上不剩丁香")
	_check(gain > cost, "这一趟是赚的（成本 %d → 收入 %d）" % [cost, gain])


# ---------------------------------------------------------------- 4 知识交易

func _test_knowledge_trade() -> void:
	var v := _v()
	v.docked_port = "sanlucar"
	v.knowledge.note("chart", "test_chart", "测试海图", "一条可测的海图。")
	var money_before := v.cargo.money
	var att_before := v.factions.value("merchants")
	var r := v.port_sell_knowledge("chart", "test_chart")
	_check(bool(r.get("ok", false)), "海图卖得掉（%s）" % str(r.get("reason", "")))
	var price := int(r.get("price", 0))
	_check(v.cargo.money == money_before + price, "卖海图换到 %d 杜卡特" % price)
	_check(int(v.memory.get("sold_charts", 0)) == 1, "世界记住了「卖过一条海图」")
	_check(v.factions.value("merchants") > att_before,
		"买方行为变了：商人的态度 %.3f → %.3f" % [att_before, v.factions.value("merchants")])
	var again := v.port_sell_knowledge("chart", "test_chart")
	_check(not bool(again.get("ok", false)), "同一条不能卖第二遍（%s）" % str(again.get("reason", "")))


# ---------------------------------------------------------------- 5 招募

func _test_recruit() -> void:
	var v := _v()
	v.docked_port = "tidore"
	var before := v.roster.members.size()
	var r := v.port_recruit(3)
	_check(bool(r.get("ok", false)), "在港口招到人（%s）" % str(r.get("reason", "")))
	_check(v.roster.members.size() == before + 3, "名册多了三个人（%d → %d）"
		% [before, v.roster.members.size()])
	var newbie: CrewMember = null
	for m in v.roster.members:
		if m.id == "recruit_01":
			newbie = m
	_check(newbie != null, "招来的人有自己的名字（recruit_01）")
	if newbie != null:
		_check(newbie.post == "水手", "他有岗位（%s）" % newbie.post)
		_check(float(newbie.skills.get("seamanship", 0.0)) > 0.0, "他有技能（操帆 %.2f）"
			% float(newbie.skills.get("seamanship", 0.0)))
		_check(newbie.display_name.contains("#01") and newbie.display_name != "#R01",
			"显示名里带来源地（%s）" % newbie.display_name)
	_check(v.roster.recruited == 3, "招人计数进了名册状态（%d）" % v.roster.recruited)

	# 进存档：读回来人数、岗位、技能都在
	var st := v.roster.capture_state()
	var r2 := CrewRoster.new()
	r2.setup()
	r2.apply_state(st)
	_check(r2.members.size() == v.roster.members.size(), "读档后人数不变（%d）" % r2.members.size())
	_check(r2.recruited == 3, "读档后招人计数还在（%d）" % r2.recruited)
	var back: CrewMember = null
	for m in r2.members:
		if m.id == "recruit_01":
			back = m
	_check(back != null and back.post == "水手" and float(back.skills.get("seamanship", 0.0)) > 0.0,
		"读档后招来的人还有岗位与技能")

	# 生还人数：死一个人就少一个（结算数的是活人）
	var alive_before := v._alive_crew_count()
	for m in v.roster.members:
		if m.id == "recruit_01":
			m.dead = true
	_check(v._alive_crew_count() == alive_before - 1, "死人不再算生还人数（%d → %d）"
		% [alive_before, v._alive_crew_count()])


# ---------------------------------------------------------------- 收尾

func _test_indian_pool() -> void:
	"""印度洋与好望角段的事件池（M14 的内容那一块）。"""
	var v := _v()
	var ids: Array = v.events.ids()
	for want in ["indian_monsoon_reversal", "indian_fever", "indian_pirate_sail",
			"indian_sultan_port", "cape_of_storms"]:
		_check(ids.has(want), "印度洋事件池里有 %s" % want)
	var e: Dictionary = v.events.def_of("cape_of_storms")
	_check(str((e.get("requires", {}) as Dictionary).get("region", "")) == "indian",
		"好望角那条事件钉在印度洋图幅上")
	# 真触发一次：桅杆与帆真的受伤（事件只能改状态，不许绕过损伤链路）
	var mast_before := v.ship.damage_of("mast")
	v.t = 340.0 * 86400.0 / VoyageJournal.voyage_time_scale
	v.ship.set_pose(v.sea.lonlat_to_m(30.0, -25.0), 90.0)      # 印度洋中间
	var r := v.events.try_fire("cape_of_storms", v)
	_check(bool(r.get("ok", false)), "好望角事件触发得起来（%s）" % str(r.get("reason", "")))
	_check(v.ship.damage_of("mast") > mast_before, "狂风真的伤了桅杆（%.3f → %.3f）"
		% [mast_before, v.ship.damage_of("mast")])

func _test_two_stage_trade() -> void:
	"""两段式交易（M14）：港口库存是房主权威、货与钱是拥有者权威 —— 两半各动各的，
	合起来才是一笔**两边账目一致**的交易（验收第 2 条的后半段）。
	"""
	var host := _v()          # 扮演房主那一半（世界与港口库存）
	var me := _v()            # 扮演申请方那一半（我这条船的货舱）
	host.docked_port = "tidore"
	me.docked_port = "tidore"
	var stock_before := host.ports.stock_of("tidore", "cloves")
	var money_before := me.cargo.money
	# 申请里带**船主自报**的三个数（钱 / 舱位）：铁律 11 —— 船的账由船主报，
	# 房主只守港口那一本。
	var req := {"ship_id": "client", "port": "tidore", "item": "cloves", "n": 5, "side": "buy",
		"money": me.cargo.money, "free_kg": me.cargo.free_kg()}

	var res := host.host_execute_trade(req)
	_check(bool(res.get("ok", false)), "房主执行了第一段（%s）" % str(res.get("reason", "")))
	_check(host.ports.stock_of("tidore", "cloves") == stock_before - 5,
		"房主只动库存（%d → %d）" % [stock_before, host.ports.stock_of("tidore", "cloves")])
	_check(me.cargo.qty("cloves") == 0 and me.cargo.money == money_before,
		"回执还没到，申请方的账一点没动")

	var applied := me.client_apply_trade({"req": req, "result": res})
	_check(bool(applied.get("ok", false)), "申请方把回执落到自己的货舱")
	_check(me.cargo.qty("cloves") == 5, "船上多了五袋丁香（自己的货舱）")
	_check(me.cargo.money == money_before - int(res.get("total", 0)),
		"钱按回执上的总数扣（%d → %d）" % [money_before, me.cargo.money])
	_check(int(res.get("total", 0)) == int(res.get("unit", 0)) * 5,
		"两边用的是同一份价目（%d = %d × 5）" % [int(res.get("total", 0)), int(res.get("unit", 0))])

	# 库存不够：房主直接拒，申请方一分钱一袋货都不动
	var stock2 := host.ports.stock_of("tidore", "cloves")
	var money2 := me.cargo.money
	var bad := host.host_execute_trade({"ship_id": "client", "port": "tidore",
		"item": "cloves", "n": stock2 + 100, "side": "buy",
		"money": me.cargo.money, "free_kg": me.cargo.free_kg()})
	_check(not bool(bad.get("ok", false)), "买得比库存多 → 房主拒了（%s）" % str(bad.get("reason", "")))
	me.client_apply_trade({"req": {}, "result": bad})
	_check(host.ports.stock_of("tidore", "cloves") == stock2 and me.cargo.money == money2,
		"被拒的那一笔两边都没动账")

	# 卖：方向反过来，还是两半各动各的
	var host2 := _v()
	var me2 := _v()
	host2.docked_port = "sanlucar"
	me2.docked_port = "sanlucar"
	me2.cargo.add("cloves", 4)
	var stock3 := host2.ports.stock_of("sanlucar", "cloves")
	var money3 := me2.cargo.money
	var sell_req := {"ship_id": "client", "port": "sanlucar", "item": "cloves", "n": 4,
		"side": "sell", "have": me2.cargo.qty("cloves")}
	var sres := host2.host_execute_trade(sell_req)
	_check(bool(sres.get("ok", false)), "房主执行卖出那一段")
	_check(host2.ports.stock_of("sanlucar", "cloves") == stock3 + 4, "港口的库存多了四袋")
	me2.client_apply_trade({"req": sell_req, "result": sres})
	_check(me2.cargo.qty("cloves") == 0, "船上那四袋没了")
	_check(me2.cargo.money == money3 + int(sres.get("total", 0)), "钱按回执上的总数进账")

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
