extends SceneTree

# M4 的验收测试（下）：四个港口、买卖守恒、价格随买卖走、修船、以及
# "船体不修，到巴西时航速明显掉"（验收第 2 条）。

const DT := 0.5
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_ports ===")
	_test_port_data()
	_test_docking()
	_test_buy_sell_conservation()
	_test_price_pressure()
	_test_repair()
	_test_supply_bundle()
	_test_damage_slows_you_down()
	_test_save()
	_test_route_metadata()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	return v


func _dock(v: Voyage) -> void:
	v.orders.anchored = true
	v.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
	v.ship.set_pose(v.sea.port_pos(), 180.0)
	var r := v.dock()
	if r != "":
		print("      （靠港失败：%s）" % r)


# ---------------------------------------------------------------- 1 港口数据

func _test_port_data() -> void:
	var v := _v()
	_check(v.ports.ids().size() == 4, "四个港都有经济（%s）" % ", ".join(v.ports.ids()))
	for want in ["sanlucar", "santa_cruz", "santiago", "sao_aleixo"]:
		_check(v.ports.has_port(want), "%s 在港口表里" % want)
		_check(v.ports.has_service(want, "supply") and v.ports.has_service(want, "trade"),
			"%s 能补给、能买卖" % want)
	# 地区价差：象牙在非洲便宜、在欧洲贵；巴西红木在巴西便宜、在欧洲贵
	_check(v.ports.buy_price("sanlucar", "ivory") > v.ports.buy_price("santiago", "ivory"),
		"象牙在非洲便宜（圣地亚哥 %d vs 圣卢卡尔 %d）" % [
			v.ports.buy_price("santiago", "ivory"), v.ports.buy_price("sanlucar", "ivory")])
	_check(v.ports.buy_price("sao_aleixo", "brazilwood") < v.ports.buy_price("sanlucar", "brazilwood"),
		"红木在巴西便宜（圣阿莱克索 %d vs 圣卢卡尔 %d）" % [
			v.ports.buy_price("sao_aleixo", "brazilwood"), v.ports.buy_price("sanlucar", "brazilwood")])
	_check(v.ports.stock_of("sanlucar", "food") > v.ports.stock_of("sao_aleixo", "food"),
		"出发港的补给最充足（%d vs %d 份）" % [
			v.ports.stock_of("sanlucar", "food"), v.ports.stock_of("sao_aleixo", "food")])


# ---------------------------------------------------------------- 2 靠港

func _test_docking() -> void:
	var v := _v()
	_check(v.docked_port == "", "开局在港里但**没靠港**（还得抛锚）")
	_check(not v.can_dock(), "没抛锚就靠不上港")
	v.orders.anchored = true
	_check(v.can_dock(), "抛了锚、又在港圈里，就能靠港")
	var r := v.dock()
	_check(r == "" and v.docked_port == "sanlucar", "靠上了圣卢卡尔（%s）" % v.port_name())
	_check(v.can_trade_here(), "靠港之后能买卖")
	var r2 := v.dock()
	_check(r2 != "", "已经靠港了就别重复靠（%s）" % r2)
	v.undock()
	_check(v.docked_port == "" and not v.can_trade_here(), "出海之后就不能买卖了")
	# 海上按买卖：给一句人话，不是静默失败
	var r3 := v.port_buy("food", 10)
	_check(not bool(r3.get("ok", true)) and str(r3.get("reason", "")) != "",
		"在海上买卖会被拒绝，而且说了为什么（%s）" % str(r3.get("reason", "")))


# ---------------------------------------------------------------- 3 买卖守恒

func _test_buy_sell_conservation() -> void:
	var v := _v()
	_dock(v)
	_check(v.docked_port == "sanlucar", "先靠港（%s）" % v.docked_port)
	var total0 := v.ports.total_goods_units() + v.cargo.total_goods_units()
	var money0 := v.cargo.money
	var stock0 := v.ports.stock_of("sanlucar", "food")
	var hold0 := v.cargo.qty("food")

	var r := v.port_buy("food", 40)
	_check(bool(r.get("ok", false)), "买 40 份食物（花了 %d 金币）" % int(r.get("cost", 0)))
	_check(v.cargo.qty("food") == hold0 + 40, "船上多了 40 份（%d）" % v.cargo.qty("food"))
	_check(v.ports.stock_of("sanlucar", "food") == stock0 - 40,
		"港口库存同步少了 40（%d）" % v.ports.stock_of("sanlucar", "food"))
	_check(v.cargo.money < money0, "钱少了（%d → %d）" % [money0, v.cargo.money])
	_check(v.ports.total_goods_units() + v.cargo.total_goods_units() == total0,
		"买不造货：港口加船上的总件数不变（%d）" % total0)

	var money1 := v.cargo.money
	var r2 := v.port_sell("food", 15)
	_check(bool(r2.get("ok", false)), "卖回去 15 份（得到 %d 金币）" % int(r2.get("gain", 0)))
	_check(v.cargo.qty("food") == hold0 + 25, "船上剩 %d 份" % v.cargo.qty("food"))
	_check(v.ports.stock_of("sanlucar", "food") == stock0 - 25,
		"港口库存回到了 %d" % v.ports.stock_of("sanlucar", "food"))
	_check(v.cargo.money > money1, "卖东西钱变多（%d → %d）" % [money1, v.cargo.money])
	_check(v.ports.total_goods_units() + v.cargo.total_goods_units() == total0,
		"卖也不吞货：总数还是 %d" % total0)

	# 买不起 / 装不下 / 港口没有 —— 三种失败都要给人话
	var poor := _v()
	_dock(poor)
	poor.cargo.money = 1
	var r3 := poor.port_buy("food", 100)
	_check(not bool(r3.get("ok", true)) and str(r3.get("reason", "")).find("钱不够") >= 0,
		"钱不够时说「钱不够」（%s）" % str(r3.get("reason", "")))
	var nope := _v()
	_dock(nope)
	var r4 := nope.port_buy("ivory", 5)
	_check(not bool(r4.get("ok", true)), "港口不做这门生意就买不到（%s）" % str(r4.get("reason", "")))
	var heavy := _v()
	_dock(heavy)
	heavy.cargo.money = 100000
	_check(heavy.cargo.add("brazilwood", 320),  # 先把货舱塞到 25.6 吨（出发时还有 1 吨存货）
		"把货舱塞到 %.1f 吨" % (heavy.cargo.used_kg() / 1000.0))
	var r5 := heavy.port_buy("salt", 40)        # 再买 2 吨盐 —— 装不下了
	_check(not bool(r5.get("ok", true)) and str(r5.get("reason", "")).find("装不下") >= 0,
		"装不下的时候说装不下（%s）" % str(r5.get("reason", "")))


# ---------------------------------------------------------------- 4 价格随买卖走

func _test_price_pressure() -> void:
	var v := _v()
	_dock(v)
	v.cargo.money = 100000
	var p0 := v.ports.buy_price("sanlucar", "wood")
	v.port_buy("wood", 40)
	var p1 := v.ports.buy_price("sanlucar", "wood")
	_check(p1 > p0, "买走一批木头之后它涨价了（%d → %d）" % [p0, p1])
	# 往港口倒货：价格下来
	var v2 := _v()
	_dock(v2)
	v2.cargo.items.clear()
	v2.cargo.add("food", 400)
	var q0 := v2.ports.sell_price("sanlucar", "food")
	var s0 := v2.ports.stock_of("sanlucar", "food")
	v2.port_sell("food", 400)
	var q1 := v2.ports.sell_price("sanlucar", "food")
	_check(v2.ports.stock_of("sanlucar", "food") > s0,
		"倒货让港口库存涨到 %d" % v2.ports.stock_of("sanlucar", "food"))
	_check(q1 <= q0, "货多了价钱就下来（%d → %d）" % [q0, q1])


# ---------------------------------------------------------------- 5 修船

func _test_repair() -> void:
	var v := _v()
	_dock(v)
	v.ship.apply_damage("hull", 0.35)
	v.ship.apply_damage("rudder", 0.2)
	v.cargo.add("wood", 20)
	v.cargo.add("canvas", 10)
	v.cargo.money = 1000
	var wood0 := v.cargo.qty("wood")
	var r := v.port_repair("hull", 1.0)
	_check(bool(r.get("ok", false)), "在港口把船体修好（%s）" % str(r))
	_check(v.ship.damage_of("hull") <= 0.01, "船体损伤清零（%.0f%%）" % (v.ship.damage_of("hull") * 100.0))
	_check(v.cargo.qty("wood") < wood0, "修船真的花了木头（%d → %d）" % [wood0, v.cargo.qty("wood")])
	_check(v.ship.damage_of("rudder") > 0.1, "只修了船体，舵还是坏的（%.0f%%）" % (
		v.ship.damage_of("rudder") * 100.0))
	# 靠港才修得了
	var v2 := _v()
	v2.ship.apply_damage("hull", 0.3)
	var r2 := v2.port_repair("hull", 1.0)
	_check(not bool(r2.get("ok", true)), "海上海没修（%s）" % str(r2.get("reason", "")))
	# 没料修不了，而且不会扣掉一半
	var v3 := _v()
	_dock(v3)
	v3.cargo.items.clear()
	v3.cargo.money = 0
	v3.ship.apply_damage("hull", 0.3)
	var r3 := v3.port_repair("hull", 1.0)
	_check(not bool(r3.get("ok", true)), "没料修不了（%s）" % str(r3.get("reason", "")))
	_check(is_equal_approx(v3.ship.damage_of("hull"), 0.3), "修不了的时候船体原样（%.0f%%）" % (
		v3.ship.damage_of("hull") * 100.0))


# ---------------------------------------------------------------- 6 一键补给

func _test_supply_bundle() -> void:
	var v := _v()
	_dock(v)
	v.cargo.money = 5000
	var need := v.supply_need_for(v.next_port_position().distance_to(v.ship.position_m()))
	var food0 := v.cargo.qty("food")
	var r := v.port_supply_bundle()
	_check(bool(r.get("ok", false)), "一键补给：买了 %s" % str(r.get("bought", [])))
	_check(v.cargo.qty("food") >= int(need["food"]),
		"补给之后食物够开到下一个港（%d ≥ %d）" % [v.cargo.qty("food"), int(need["food"])])
	_check(v.cargo.qty("water") >= int(need["water"]),
		"水也够（%d ≥ %d）" % [v.cargo.qty("water"), int(need["water"])])
	_check(v.cargo.qty("food") > food0, "确实往里装了东西")
	_check(v.ports.total_goods_units() + v.cargo.total_goods_units() > 0, "港口还有货可卖")


# ---------------------------------------------------------------- 7 验收第 2 条

func _test_damage_slows_you_down() -> void:
	"""船体损伤不修，一路上就是慢 —— 沿用 v0.1 的损伤 → 阻力链路。"""
	var clean := _v()
	var hurt := _v()
	hurt.ship.apply_damage("hull", 0.6)
	for v in [clean, hurt]:
		v.ship.set_pose(Vector2(30000, 22000), 200.0)
		v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
		v.orders.set_target_point(Vector2(22000, 26000))
		for _i in int(900.0 / DT):
			v.tick(DT)
	var a := clean.ship.speed_kn()
	var b := hurt.ship.speed_kn()
	_check(b < a * 0.9, "船体损伤 60%% 的船明显更慢（%.1f 节 vs %.1f 节，慢了 %.0f%%）" % [
		b, a, (1.0 - b / maxf(a, 0.01)) * 100.0])


# ---------------------------------------------------------------- 8 港口进存档

func _test_save() -> void:
	var a := _v()
	_dock(a)
	a.port_buy("food", 30)
	a.port_sell("salt", 0)      # 什么都不卖的调用也不该炸
	var b := Voyage.new()
	b.setup(GEO)
	b.apply_world_state(a.capture_world_state())
	b.apply_ship_state(a.capture_ship_state())
	_check(b.ports.stock_of("sanlucar", "food") == a.ports.stock_of("sanlucar", "food"),
		"读档后港口库存一致（%d 份）" % b.ports.stock_of("sanlucar", "food"))
	_check(b.ports.buy_price("sanlucar", "food") == a.ports.buy_price("sanlucar", "food"),
		"读档后价格一致（%d）" % b.ports.buy_price("sanlucar", "food"))
	_check(b.cargo.qty("food") == a.cargo.qty("food") and b.cargo.money == a.cargo.money,
		"读档后货舱与金币一致（食物 %d，金币 %d）" % [b.cargo.qty("food"), b.cargo.money])


# ---------------------------------------------------------------- 断言框架

# ------------------------------------------------- 7 航段元数据（风险 / 补给 / 价值）

func _test_route_metadata() -> void:
	"""M7 卡片把"航线元数据（风险/补给/价值）"留给了 M8 —— 这一节就是它的验收。

	三样都必须**从真源推出来**：补给来自距离（`supply_need_for`）、风险来自
	`weather.json` 的天气带、价值来自 `ports.json` 的 `mul`。玩家看到的与真的会
	遇上的必须是同一份数据 —— 所以这里不比字符串，比**数**。
	"""
	var v := _v()
	_check(v.sea.routes().size() == 3, "三条航段（%d）" % v.sea.routes().size())

	var sanlucar_leg := v.leg_info({"id": "probe", "from": "sanlucar", "to": "santa_cruz"})
	_check(not sanlucar_leg.is_empty(), "第一条航段的元数据拿得到")
	if sanlucar_leg.is_empty():
		return
	# ① 补给：图上距离 × 压缩系数 = 真实公里；天数与口粮按真实公里算
	_check(float(sanlucar_leg["map_km"]) > 1.0, "算得出图上距离（%.1f km）" % float(sanlucar_leg["map_km"]))
	var ratio := float(sanlucar_leg["real_km"]) / float(sanlucar_leg["map_km"])
	_check(is_equal_approx(ratio, v.sea.real_time_scale()),
		"真实公里 = 图上公里 × 压缩系数（%.0f 倍）" % ratio)
	var need := v.supply_need_for(Geom2D.path_length(v.sea.route_points(
		{"id": "probe", "from": "sanlucar", "to": "santa_cruz"})))
	_check(is_equal_approx(float(sanlucar_leg["days"]), float(need["days"]))
		and int(sanlucar_leg["food"]) == int(need["food"]),
		"航程日与口粮跟 supply_need_for 是同一个数（%.1f 天 / %d 份）" % [
			float(sanlucar_leg["days"]), int(sanlucar_leg["food"])])
	_check(float(sanlucar_leg["days"]) > 0.0 and int(sanlucar_leg["water"]) > 0,
		"口粮与淡水都算得出来（水 %d 桶）" % int(sanlucar_leg["water"]))

	# ② 风险：穿过哪些天气带 —— 直接对着 weather.json 的带子核
	var brazil_leg := v.leg_info({"id": "probe", "from": "santiago", "to": "sao_aleixo"})
	var risky: Array = brazil_leg["risky"]
	var names := PackedStringArray()
	for b in risky:
		names.append(str(b.get("name", "")))
	var joined := "、".join(names)
	_check(joined.find("无风带") >= 0,
		"渡海去巴西这一段会穿过赤道无风带（%s）-- 这正是实测里把船晒住的那一带" % joined)
	_check(str(brazil_leg["risk_text"]).find("无风") >= 0
		and str(brazil_leg["risk_text"]).find("风暴") >= 0,
		"风险话术里既说了无风也说了风暴（%s）" % str(brazil_leg["risk_text"]))

	# ③ 价值：好卖/好买是从 ports.json 的 mul 推出来的，得跟 mul 对得上
	var best: Dictionary = v.ports.best_trades("sao_aleixo", 2)
	_check((best["sell"] as Array).size() > 0 and (best["buy"] as Array).size() > 0,
		"巴西港既列得出好卖的也列得出好买的（卖 %s / 买 %s）" % [
			str(best["sell"]), str(best["buy"])])
	var sell_ids: Array = best["sell"]
	if not sell_ids.is_empty():
		_check(v.ports.mul_of("sao_aleixo", str(sell_ids[0])) > 1.0,
			"排第一的'好卖'确实有溢价（%s × %.1f）" % [
				str(sell_ids[0]), v.ports.mul_of("sao_aleixo", str(sell_ids[0]))])
	# 好卖的都是这个港出价高的（反过来：出价高的不一定全被列出来，但列出来的必须高）
	var bad := 0
	for item in sell_ids:
		if v.ports.mul_of("sao_aleixo", str(item)) <= 1.0:
			bad += 1
	_check(bad == 0, "列出来的'好卖'没有一个是溢价的（%d 个不对）" % bad)

	# ④ 靠港时面板拿到的就是"从这儿出去的下一段"
	_dock(v)
	var here := v.leg_info()
	_check(str(here.get("id", "")) == "sanlucar_canarias",
		"在圣卢卡尔靠港时，下一段是出海口那一段（%s）" % str(here.get("id", "")))
	_check(str(here.get("to", "")) == "圣克鲁斯" or str(here.get("to", "")) != "",
		"下一段的终点港有名字（%s）" % str(here.get("to", "")))
	_check(str(here.get("note", "")) != "", "每一段都有一句忠告（%s）" % str(here.get("note", "")).substr(0, 12))


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
