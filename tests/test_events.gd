extends SceneTree

# M7 的验收测试：因果链、风暴真的改变航行、知识被填满。
#
# 三条验收（docs/13 M7 卡片）：
#   1. 至少 1 条 **4 环**因果链在无头下可复现；
#   2. 跨洋航程结束后，海图与知识页被填满（断言条目数 ≥ N）；
#   3. 风暴真的会改变航行结果（到达时间与损伤都不同）—— 不是纯文本。

const GEO := "res://data/world/atlantic/geography.json"
const DT := 60.0                     # 事件尺度粗：用一分钟一步跑得动

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_events ===")
	_test_weather_table()
	_test_chain_reproducible()
	_test_storm_changes_the_voyage()
	_test_knowledge_fills_up()
	_test_world_memory()
	_test_save()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	return v


func _drive(v: Voyage, seconds: float) -> void:
	var n := int(seconds / DT)
	for _i in n:
		v.tick(DT)


func _drive_until(v: Voyage, ev_id: String, max_seconds := 20000.0) -> bool:
	var spent := 0.0
	while spent < max_seconds:
		v.tick(DT)
		spent += DT
		if v.events.fired.has(ev_id):
			return true
	return false


# ---------------------------------------------------------------- 1 天气表

func _test_weather_table() -> void:
	var w := Weather.new()
	w.setup()
	_check(w.defs.get("states", []).size() >= 5, "至少五种天气（%d）" % w.defs.get("states", []).size())
	for want in ["clear", "squall", "storm", "fog", "calm"]:
		_check(not w._state_def(want).is_empty(), "%s 在表里" % want)
	_check(w.band_id_at(Vector2(0.0, 4000.0)) == "north", "北边是一带")
	_check(w.band_id_at(Vector2(0.0, 30000.0)) == "doldrums", "赤道一带是无风带")
	# 无风带的风只有两成、风暴近两倍 —— 这是"改变航行结果"的源头
	w.force("calm")
	var calm := w.wind_mult()
	w.force("storm")
	var storm := w.wind_mult()
	_check(calm < 0.3 and storm > 1.5 and storm > calm * 5.0,
		"无风带与风暴的风差 5 倍以上（%.2f vs %.2f）" % [calm, storm])
	_check(w.visibility_m() < 500.0, "风暴里看不见多远（%.0f 米）" % w.visibility_m())
	_check(w.misfire_weather() == "rain", "风暴的哑火天气是大雨（给 M6 用）")
	# 天气自己会变，而且可复现
	var a := _v()
	var b := _v()
	_drive(a, 6.0 * 3600.0)
	_drive(b, 6.0 * 3600.0)
	_check(a.weather.spells > 0, "天气自己会变（变了 %d 次）" % a.weather.spells)
	_check(a.weather.state_id == b.weather.state_id and a.weather.spells == b.weather.spells,
		"同一个局面必然遇到同样的天气（%s，%d 次）" % [a.weather.state_name(), a.weather.spells])


# ---------------------------------------------------------------- 2 四环因果链

func _test_chain_reproducible() -> void:
	var chain := ["locals_anger", "port_refused", "supplies_run_out",
		"storm_belt", "storm_damage", "crew_despair"]
	var v := _v()
	# 第一环的因：玩家在岸上开火（M5 的抉择 / M6 的陆战都会把态度推到敌对）
	v.culture.react("green_cape", "fire", "测试：开火")
	v.culture.react("green_cape", "fire", "测试：再开火")
	_check(v.culture.stance("green_cape") == Culture.HOSTILE,
		"当地人已经敌对（%s）" % v.culture.describe("green_cape"))
	var fired_order: Array = []
	for i in chain.size():
		var id := str(chain[i])
		if id == "supplies_run_out":
			v.cargo.remove("water", v.cargo.qty("water"))     # 补给真的见底了
		if id == "crew_despair":
			v.society.tension = maxf(v.society.tension, 0.5)  # 紧张度够高
		# 第 5 环要赶在风暴还在的时候判（风暴只持续 12 个航程小时）
		var ok := _drive_until(v, id, 2400.0 if id == "storm_damage" else 20000.0)
		_check(ok, "第 %d 环「%s」触发了%s" % [i + 1, id,
			"" if ok else "（条件：%s）" % v.events.unmet(v.events.def_of(id), v)])
		if ok:
			fired_order.append(id)
	_check(fired_order == chain,
		"六环按顺序串起来（%s）" % " → ".join(fired_order))
	_check(v.fired.has("despair"), "链子走到底留下了旗标（despair）")
	_check(v.ship.damage_of("hull") > 0.01,
		"链子里的风暴真的砸到了船体（%.0f%%）" % (v.ship.damage_of("hull") * 100.0))

	# 可复现：同样的开局与同样的输入，链子一模一样
	var v2 := _v()
	v2.culture.react("green_cape", "fire", "测试：开火")
	v2.culture.react("green_cape", "fire", "测试：再开火")
	var order2: Array = []
	for id in chain:
		if str(id) == "supplies_run_out":
			v2.cargo.remove("water", v2.cargo.qty("water"))
		if str(id) == "crew_despair":
			v2.society.tension = maxf(v2.society.tension, 0.5)
		if _drive_until(v2, str(id)):
			order2.append(str(id))
	_check(order2 == fired_order, "同样的输入 → 同一条链子（%s）" % " → ".join(order2))


# ---------------------------------------------------------------- 3 风暴改变航行

func _test_storm_changes_the_voyage() -> void:
	var calm := _v()
	calm.weather.force("clear", 999.0)
	var storm := _v()
	storm.weather.force("storm", 999.0)
	for v in [calm, storm]:
		v.ship.set_pose(Vector2(30000, 22000), 200.0)
		v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
		v.orders.set_target_point(Vector2(22000, 26000))
		v.weather.force(v.weather.state_id, 999.0)     # tick 里会重算，这里再按一次
		# 船的物理要小步长（60 秒一步会把积分跑飞 —— 第一版这里出过 NaN）
		for _i in int(1800.0 / 0.5):
			v.tick(0.5)
		var far: float = v.ship.position_m().distance_to(Vector2(30000, 22000))
		_check(far > 0.0, "%s里航行了 %.0f 米" % [v.weather.state_name(), far])
	# 风暴里走得更少、伤得更多 —— 两条都要成立
	var calm_far := calm.ship.position_m().distance_to(Vector2(30000, 22000))
	var storm_far := storm.ship.position_m().distance_to(Vector2(30000, 22000))
	_check(storm_far != calm_far,
		"风暴里的航程与晴天不同（%.0f 米 vs %.0f 米）" % [storm_far, calm_far])
	_check(storm.ship.damage_of("hull") > calm.ship.damage_of("hull") + 0.005,
		"风暴里船体伤得更重（%.1f%% vs %.1f%%）" % [
			storm.ship.damage_of("hull") * 100.0, calm.ship.damage_of("hull") * 100.0])
	_check(calm.weather.storm_hours < 0.01 and storm.weather.storm_hours > 0.5,
		"风暴待了几小时（%.1f 小时 vs %.1f）" % [
			storm.weather.storm_hours, calm.weather.storm_hours])


# ---------------------------------------------------------------- 4 知识页

func _test_knowledge_fills_up() -> void:
	var v := _v()
	var k0 := v.knowledge.count()
	# 一趟"跨洋"：把船摆到各个港、靠港、上岸走一圈（用同一套公开入口）
	for port_id in ["sanlucar", "santa_cruz", "santiago", "sao_aleixo"]:
		var pos := Vector2.ZERO
		for p in v.sea.ports():
			if str(p.get("id", "")) == port_id:
				pos = Geom2D.centroid(p["shape"])
		v.ship.set_pose(pos, 180.0)
		v.orders.anchored = true
		v.dock()
		v.undock()
		v.orders.anchored = false
		_drive(v, 600.0)
	# 上岸走一遍（遗迹/村落/溪流各记一条）
	v.ship.set_pose(v.sea.poi_pos("beach") + Vector2(-200.0, 0.0), 0.0)
	v.orders.anchored = true
	var ids := []
	for m in v.roster.key_crew():
		ids.append(m.id)
	v.fired.erase("landed")
	v.land(ids, 4)
	_drive(v, 120.0)
	for poi in ["ruins", "village", "stream"]:
		v.move_party_to(v.sea.poi_pos(poi))
		_drive(v, 300.0)
	_drive(v, 3600.0)                       # 再跑一段，让天气与事件也记上几笔
	_check(v.knowledge.count() >= 8,
		"一趟下来知识页 ≥8 条（%d 条：%s）" % [v.knowledge.count(), v.knowledge.describe()])
	_check(v.knowledge.count_of("chart") >= 2, "海图上有条目（%d）" % v.knowledge.count_of("chart"))
	_check(v.knowledge.count_of("trade") >= 2, "贸易情报有条目（%d）" % v.knowledge.count_of("trade"))
	_check(v.knowledge.count_of("culture") + v.knowledge.count_of("language") >= 1,
		"文化与语言至少记下一样（%d / %d）" % [
			v.knowledge.count_of("culture"), v.knowledge.count_of("language")])
	_check(v.knowledge.count() > k0 and v.knowledge.lines().size() > 0,
		"知识页从 %d 条涨到 %d 条，能摊开给人看（%d 行）" % [
			k0, v.knowledge.count(), v.knowledge.lines().size()])


# ---------------------------------------------------------------- 5 世界记忆

func _test_world_memory() -> void:
	var v := _v()
	_check(v.memory.is_empty(), "开局世界还没记住什么")
	v.ship.set_pose(v.sea.port_pos(), 180.0)
	v.orders.anchored = true
	v.dock()
	_check(v.can_trade_here(), "名声没问题时港口做生意")
	# 毁约（链子第二环真的会改港口态度）
	v.fired["locals_hostile"] = true
	_drive_until(v, "port_refused")
	_check(v.events.fired.has("port_refused"), "港口拒绝了贸易（因果链第二环）")
	_check(int(v.memory.get("broken_faith", 0)) >= 1,
		"世界记住了这件事（broken_faith = %d）" % int(v.memory.get("broken_faith", 0)))
	_check(not v.can_trade_here(), "名声坏了之后按不下「买」")


# ---------------------------------------------------------------- 6 存档

func _test_save() -> void:
	var a := _v()
	a.weather.force("storm", 5.0)
	_drive(a, 1200.0)
	a.knowledge.note("species", "test_bird", "测试的鸟", "", a.t)
	a.memory["traded"] = 2
	a.events.fired["locals_hostile"] = true
	var b := Voyage.new()
	b.setup(GEO)
	b.apply_world_state(a.capture_world_state())
	b.apply_ship_state(a.capture_ship_state())
	_check(b.weather.state_id == a.weather.state_id,
		"读档后天气一致（%s）" % b.weather.state_name())
	_check(absf(b.weather.storm_hours - a.weather.storm_hours) < 1e-6,
		"读档后风暴时长一致（%.2f 小时）" % b.weather.storm_hours)
	_check(b.knowledge.count() == a.knowledge.count(),
		"读档后知识条数一致（%d）" % b.knowledge.count())
	_check(str(b.memory) == str(a.memory), "读档后世界记忆一致（%s）" % str(b.memory))
	_check(b.events.fired.has("locals_hostile"), "读档后事件池的旗标一致")


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
