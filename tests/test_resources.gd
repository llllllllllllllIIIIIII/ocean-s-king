extends SceneTree

# M4 的验收测试（上）：货舱、消耗、载重、修船料。
#
# 四件事：
#   1. 载重是真的（装不下就装不下，不悄悄丢一半）；
#   2. 消耗按**航程日**算：一段圣卢卡尔→加那利的航程 ≈ 5 个航程日、四十个人
#      吃掉两百份食物十桶水（验收第 1 条的"刚好够"就是照这把尺子量的）；
#   3. 缺粮缺水只记账（M5 拿它算士气），不会凭空变出补给；
#   4. 修船要花料：修一半就是一半。

const DT := 0.5
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_resources ===")
	_test_defs()
	_test_capacity()
	_test_consumption()
	_test_leg_supplies()
	_test_repair_materials()
	_test_shooting_accounting()
	_test_save()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	return v


# ---------------------------------------------------------------- 1 资源表

func _test_defs() -> void:
	var c := Cargo.new()
	c.setup(27.0)
	_check(c.capacity_kg == 27000.0, "60 吨船的载重是 27 吨（来自船的数据）")
	_check(c.unit_kg("water") == 60.0 and c.unit_kg("food") == 1.5,
		"重量来自 data/defs/resources.json（水 %.0fkg / 食物 %.1fkg）" % [
			c.unit_kg("water"), c.unit_kg("food")])
	var kinds := {}
	for it in c.defs.get("items", []):
		var k := str(it.get("kind", ""))
		kinds[k] = int(kinds.get(k, 0)) + 1
	_check(int(kinds.get("consumable", 0)) >= 3 and int(kinds.get("repair", 0)) >= 2
		and int(kinds.get("ammo", 0)) >= 3 and int(kinds.get("goods", 0)) >= 4,
		"四类资源都在：消耗 %d / 修理 %d / 弹药 %d / 货物 %d" % [
			int(kinds.get("consumable", 0)), int(kinds.get("repair", 0)),
			int(kinds.get("ammo", 0)), int(kinds.get("goods", 0))])
	# 出发时本来就有一点存货，但**不够**走到巴西
	_check(c.qty("food") == 120 and c.qty("water") == 8 and c.money == 200,
		"出发时有一点存货（食物 %d / 水 %d / 金币 %d）" % [c.qty("food"), c.qty("water"), c.money])


# ---------------------------------------------------------------- 2 载重

func _test_capacity() -> void:
	var c := Cargo.new()
	c.setup(27.0, false)                # 空船
	_check(c.used_kg() == 0.0 and c.free_kg() == 27000.0, "空船的载重全空着")
	_check(c.add("brazilwood", 100), "装 100 捆红木（8 吨）")
	_check(absf(c.used_kg() - 8000.0) < 0.01, "装了 %.0f 公斤" % c.used_kg())
	_check(c.free_kg() > 18000.0, "还剩 %.1f 吨" % (c.free_kg() / 1000.0))
	# 装不下就一件都不装
	var before := c.qty("wine")
	_check(not c.add("wine", 400), "装不下的货被拒绝（400 桶酒 = 36 吨）")
	_check(c.qty("wine") == before, "被拒绝的时候一件都没偷偷装进去")
	# how_many_fit 给的是"最多能装几件"
	var fit := c.how_many_fit("wine")
	_check(fit > 150 and fit < 320, "货舱还能装 %d 桶酒（%.1f 吨）" % [fit, c.free_kg() / 1000.0])
	_check(c.add("wine", fit) and not c.add("wine", 1),
		"装到刚好卡住载重线，再多一件就装不下了")


# ---------------------------------------------------------------- 3 消耗

func _test_consumption() -> void:
	var c := Cargo.new()
	c.setup(27.0, false)
	c.add("food", 100)
	c.add("water", 10)
	# 40 个人一天：40 份食物、120 升水 = 2 桶
	var r := c.consume(1.0, 40)
	_check(int(r["want_food"]) == 40 and int(r["want_water"]) == 2,
		"40 人一天要 40 份食物、2 桶水（%d / %d）" % [int(r["want_food"]), int(r["want_water"])])
	_check(int(r["short"]) == 0, "够吃的时候不缺")
	_check(c.qty("food") == 60 and c.qty("water") == 8, "扣完还剩 %d 份 / %d 桶" % [
		c.qty("food"), c.qty("water")])
	# 断粮：只记账，不凭空变出来（4 天 = 160 份食物 + 8 桶水，两样都见底）
	var r2 := c.consume(4.0, 40)
	_check(int(r2["short"]) > 0, "断粮了：这一轮缺 %d（食物 + 水）" % int(r2["short"]))
	_check(c.starving and c.shortage_total > 0.0, "缺粮被记下来了（累计 %.0f）" % c.shortage_total)
	_check(c.qty("food") == 0 and c.qty("water") == 0, "缺粮之后货舱里不会冒出食物")


# ---------------------------------------------------------------- 4 一段航程要带多少

func _test_leg_supplies() -> void:
	var v := _v()
	var dist := v.sea.port_pos().distance_to(Vector2(36000, 12800))
	var need := v.supply_need_for(dist)
	_check(float(need["days"]) > 4.0 and float(need["days"]) < 6.0,
		"圣卢卡尔→加那利 ≈ %.1f 个航程日" % float(need["days"]))
	_check(int(need["food"]) > 150 and int(need["food"]) < 240,
		"四十个人这一程要 %d 份食物" % int(need["food"]))
	_check(int(need["water"]) > 6 and int(need["water"]) < 14,
		"要 %d 桶淡水" % int(need["water"]))
	# 出发时那点存货不够这一程 —— 这就是"必须补给"的意思
	_check(v.cargo.qty("food") < int(need["food"]) and v.cargo.qty("water") < int(need["water"]),
		"出发时的存货不够开到加那利（食物 %d < %d，水 %d < %d）" % [
			v.cargo.qty("food"), int(need["food"]), v.cargo.qty("water"), int(need["water"])])

	# 验收第 1 条：装到"刚好够"，一路开过去，到了几乎不剩；只装一半，半路就缺
	var v2 := _v()
	v2.cargo.items.clear()
	v2.cargo.add("food", int(need["food"]))
	v2.cargo.add("water", int(need["water"]))
	v2.ship.set_pose(Vector2(44000, 10000), 200.0)
	v2.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v2.orders.set_target_point(Vector2(36000, 12800))
	for _i in int(7000.0 / DT):
		v2.tick(DT)
		# 注意：出发时就站在港里，所以不能一进港就跳出 —— 要开到**下一个港**
		if v2.ship.position_m().distance_to(Vector2(36000, 12800)) < 700.0:
			break
	_check(v2.shortage_events == 0, "装够了就一路不缺（欠粮 %d 次）" % v2.shortage_events)
	_check(v2.cargo.qty("food") <= int(need["food"]) * 0.35,
		"开到的时候食物快吃完了（剩 %d 份）" % v2.cargo.qty("food"))

	var v3 := _v()
	v3.cargo.items.clear()
	v3.cargo.add("food", int(need["food"]) / 2)
	v3.cargo.add("water", int(need["water"]) / 2)
	v3.ship.set_pose(Vector2(44000, 10000), 200.0)
	v3.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v3.orders.set_target_point(Vector2(36000, 12800))
	for _i in int(7000.0 / DT):
		v3.tick(DT)
		if v3.shortage_events > 0:
			break
	_check(v3.shortage_events > 0, "只装一半：半路就缺粮缺水了（第 %d 次）" % v3.shortage_events)
	_check(v3.cargo.starving, "缺粮的标记立起来了（M5 会拿它算士气）")


# ---------------------------------------------------------------- 5 修船要料

func _test_repair_materials() -> void:
	var c := Cargo.new()
	c.setup(27.0, false)
	c.money = 500
	c.add("wood", 20)
	c.add("canvas", 10)
	var need := c.repair_need("hull", 0.5)
	_check(absf(float(need["wood"]) - 6.0) < 0.01, "修一半船体要 6 捆木头（%.0f）" % float(need["wood"]))
	_check(c.can_repair("hull", 0.5)["ok"], "料够的时候可以修")
	_check(c.pay_repair("hull", 0.5), "付了料")
	_check(c.qty("wood") == 14 and c.qty("canvas") == 7, "料被扣掉了（木 %d / 帆 %d）" % [
		c.qty("wood"), c.qty("canvas")])
	_check(c.money == 400, "工钱也花了（剩 %d）" % c.money)
	# 料不够就修不了，而且**一点都不会扣**
	var c2 := Cargo.new()
	c2.setup(27.0, false)
	c2.money = 0
	var r := c2.can_repair("hull", 1.0)
	_check(not bool(r["ok"]), "一点料都没有的时候修不了（缺：%s）" % ", ".join(r["lack"]))
	_check(c2.money == 0 and c2.qty("wood") == 0, "修不了的时候不会扣任何东西")


# ---------------------------------------------------------------- 6 与 M6 的账

func _test_shooting_accounting() -> void:
	var c := Cargo.new()
	c.setup(27.0, false)
	_check(not c.can_shoot(), "没有火药铅弹就打不了仗（M6 的联动词）")
	c.add("powder", 1)
	_check(not c.can_shoot(), "只有火药也不行（还得有铅弹和火绳）")
	c.add("lead", 20)
	c.add("match", 2)
	_check(c.can_shoot(), "火药 + 铅弹 + 火绳齐了才能开火")
	c.remove("powder", 1)
	_check(not c.can_shoot(), "打完火药就哑了")


# ---------------------------------------------------------------- 7 进存档

func _test_save() -> void:
	var a := _v()
	a.cargo.add("brazilwood", 12)
	a.cargo.add("ivory", 5)
	a.cargo.money -= 37
	a.docked_port = "sanlucar"
	var b := Voyage.new()
	b.setup(GEO)
	b.apply_world_state(a.capture_world_state())
	b.apply_ship_state(a.capture_ship_state())
	_check(b.cargo.qty("brazilwood") == 12 and b.cargo.qty("ivory") == 5,
		"读档后货舱一致（红木 %d，象牙 %d）" % [b.cargo.qty("brazilwood"), b.cargo.qty("ivory")])
	_check(b.cargo.money == a.cargo.money, "金币一致（%d）" % b.cargo.money)
	_check(absf(b.cargo.used_kg() - a.cargo.used_kg()) < 0.01,
		"载重一致（%.1f 吨）" % (b.cargo.used_kg() / 1000.0))
	_check(b.docked_port == "sanlucar", "靠港状态一致（%s）" % b.docked_port)


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
