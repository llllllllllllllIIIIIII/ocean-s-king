class_name Ports
extends RefCounted

# 港口经济（M4）：四个史实港口的库存与价格。
#
# **它是 WorldState**（docs/14 第 2 节）：库存与价格只有房主能写，客户端只读 ——
# 不然两个人会各自"买"到同一批货。所有买卖都从这一个文件进出，
# 于是"总货物量守恒"这条断言有一个唯一的检查点。
#
# 价格随库存浮动：买光了就贵一倍，堆满了就便宜一半。买卖真的会推着价格走，
# 所以低买高卖是要挑时候的 —— 这是"跑商"那一层乐趣的来源。

const DATA_PATH := "res://data/world/atlantic/ports.json"
const PRICE_LO := 0.5
const PRICE_HI := 2.0
const SELL_SPREAD := 0.9            # 卖价 = 买价的九折（港口的利差）

var defs: Dictionary = {}           # 静态：港口服务与基准库存
var stock: Dictionary = {}          # port_id -> {item: 数量}（**会变的值**）
var base_stock: Dictionary = {}     # port_id -> {item: 基准库存}（静态，读档时要重算）


func setup(path := DATA_PATH) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("港口数据读不出来：" + path)
		return
	defs = d
	stock.clear()
	base_stock.clear()
	for p in d.get("ports", []):
		var id := str(p.get("id", ""))
		stock[id] = (p.get("stock", {}) as Dictionary).duplicate()
		base_stock[id] = (p.get("stock", {}) as Dictionary).duplicate()


func ids() -> Array:
	var out := []
	for p in defs.get("ports", []):
		out.append(str(p.get("id", "")))
	return out


func port_def(id: String) -> Dictionary:
	for p in defs.get("ports", []):
		if str(p.get("id", "")) == id:
			return p
	return {}


func has_port(id: String) -> bool:
	return not port_def(id).is_empty()


func services(id: String) -> Array:
	return port_def(id).get("services", [])


func has_service(id: String, service: String) -> bool:
	return services(id).has(service)


func stock_of(port: String, item: String) -> int:
	return int((stock.get(port, {}) as Dictionary).get(item, 0))


func base_stock_of(port: String, item: String) -> int:
	return int((base_stock.get(port, {}) as Dictionary).get(item, 0))


func trades(port: String) -> Array:
	var out := []
	var items: Dictionary = (stock.get(port, {}) as Dictionary)
	for k in items.keys():
		out.append(str(k))
	out.sort()
	return out


func mul_of(port: String, item: String) -> float:
	var m: Dictionary = port_def(port).get("mul", {})
	return float(m.get(item, 1.0))


func best_trades(port: String, n := 2) -> Dictionary:
	"""这个港**什么好卖、什么好买** —— 直接从 `ports.json` 的 `mul` 推，不另写一份。

	`mul` 是地区系数：2.2 的货在这儿卖得起价（好卖），0.6 的在这儿便宜（好买）。
	M7 卡片把"航线元数据（风险/补给/价值）"留给 M8；补给在 `Voyage.supply_need_for`，
	这里是**价值**那一半 —— 出发前就能知道"这一趟带什么去、带什么回来"。
	"""
	var goods := []
	for item in trades(port):
		goods.append([float(mul_of(port, item)), str(item)])
	if goods.is_empty():
		return {"sell": [], "buy": []}
	goods.sort_custom(func(a, b): return a[0] > b[0])
	var sell := []
	for i in mini(n, goods.size()):
		if goods[i][0] > 1.0:
			sell.append(str(goods[i][1]))
	goods.sort_custom(func(a, b): return a[0] < b[0])
	var buy := []
	for i in mini(n, goods.size()):
		if goods[i][0] < 1.0:
			buy.append(str(goods[i][1]))
	return {"sell": sell, "buy": buy}


static func item_name(id: String) -> String:
	for it in Cargo.defs_data().get("items", []):
		if str(it.get("id", "")) == id:
			return str(it.get("name", id))
	return id


static func item_unit(id: String) -> String:
	for it in Cargo.defs_data().get("items", []):
		if str(it.get("id", "")) == id:
			return str(it.get("unit", "件"))
	return "件"


static func unit_kg_of(id: String) -> float:
	for it in Cargo.defs_data().get("items", []):
		if str(it.get("id", "")) == id:
			return float(it.get("kg", 1.0))
	return 1.0


func unit_price(port: String, item: String) -> float:
	"""一件多少钱：基准价 × 地区系数 × 库存压力。"""
	var base := 1.0
	for it in Cargo.defs_data().get("items", []):
		if str(it.get("id", "")) == item:
			base = float(it.get("base_price", 1.0))
			break
	var bs := maxf(1.0, float(base_stock_of(port, item)))
	var pressure := clampf(2.0 - float(stock_of(port, item)) / bs, PRICE_LO, PRICE_HI)
	return maxf(1.0, round(base * mul_of(port, item) * pressure))


func buy_price(port: String, item: String) -> int:
	return int(unit_price(port, item))


func sell_price(port: String, item: String) -> int:
	return int(maxf(1.0, round(unit_price(port, item) * SELL_SPREAD)))


func can_trade(port: String, item: String) -> bool:
	return has_service(port, "trade") and stock.get(port, {}).has(item)


# --- 两段式交易的两半（M14）-------------------------------------------------
# 港口库存与价格是**房主权威**（`AGENTS.md` 铁律 11），船上的钱与货是**船主权威**。
# 联机时这两本账在两个进程上，所以一次交易必须拆成两半：
#   `check_*` —— 只回答"港口这边答不答应"并报价（价目表是房主/本机那一份）
#   `apply_*` —— 港口这边落账（扣 / 加库存），**不碰任何人的船**
# 单机的 `buy` / `sell` 就是"这两半 + 本机 Cargo 的账"，所以两条路走的是同一个报价
# 与同一条守恒口径（`test_ports` 的断言一条都没动）。

func check_buy(port: String, item: String, n: int, money: int, free_kg: float) -> Dictionary:
	"""港口这一侧：这批货卖不卖给你、卖多少钱。**不改任何值。**"""
	if n <= 0:
		return {"ok": false, "reason": "买多少？"}
	if not can_trade(port, item):
		return {"ok": false, "reason": "这个港口不做这门生意"}
	if stock_of(port, item) < n:
		return {"ok": false, "reason": "%s 只剩 %d" % [item_name(item), stock_of(port, item)]}
	if free_kg < unit_kg_of(item) * float(n):
		return {"ok": false, "reason": "装不下了（货舱还剩 %.1f 吨）" % (free_kg / 1000.0)}
	var price := buy_price(port, item)
	var cost := price * n
	if money < cost:
		return {"ok": false, "reason": "钱不够（要 %d，有 %d）" % [cost, money]}
	return {"ok": true, "cost": cost, "unit": price, "item": item, "qty": n}


func apply_buy(port: String, item: String, n: int) -> void:
	"""港口这一侧落账：库存减少（**守恒的另一半**由买方自己落）。"""
	stock[port][item] = stock_of(port, item) - n


func check_sell(port: String, item: String, n: int, have: int) -> Dictionary:
	"""港口这一侧：这批货收不收、给多少钱。**不改任何值。**"""
	if n <= 0:
		return {"ok": false, "reason": "卖多少？"}
	if not can_trade(port, item):
		return {"ok": false, "reason": "这个港口不收这个"}
	if have < n:
		return {"ok": false, "reason": "船上只有 %d %s" % [have, item_unit(item)]}
	var price := sell_price(port, item)
	return {"ok": true, "gain": price * n, "unit": price, "item": item, "qty": n}


func apply_sell(port: String, item: String, n: int) -> void:
	"""港口这一侧落账：库存增加。"""
	stock[port][item] = stock_of(port, item) + n


func buy(port: String, item: String, n: int, cargo: Cargo) -> Dictionary:
	"""买：钱出去、货进来、**港口库存同步减少**（守恒）。"""
	var r := check_buy(port, item, n, cargo.money, cargo.free_kg())
	if not bool(r.get("ok", false)):
		return r
	cargo.money -= int(r["cost"])
	cargo.add(item, n)
	apply_buy(port, item, n)
	return r


func sell(port: String, item: String, n: int, cargo: Cargo) -> Dictionary:
	"""卖：货出去、钱进来、**港口库存同步增加**（守恒）。"""
	var r := check_sell(port, item, n, cargo.qty(item))
	if not bool(r.get("ok", false)):
		return r
	cargo.remove(item, n)
	cargo.money += int(r["gain"])
	apply_sell(port, item, n)
	return r


func repair(port: String, part: String, amount: float, cargo: Cargo, ship: ShipDynamics) -> Dictionary:
	"""在港口修船：花料 + 花工钱，然后才动船。

	（`ship.apply_damage(part, -x)` 是**指令入口**，和木匠那件事走的是同一个口子 ——
	`check_motion_ownership` 管的是"谁写速度与位置"，不管损伤。）
	"""
	if not has_service(port, "repair"):
		return {"ok": false, "reason": "这个港口修不了"}
	if amount <= 0.0:
		return {"ok": false, "reason": "没什么好修的"}
	var c := cargo.can_repair(part, amount)
	if not bool(c["ok"]):
		return {"ok": false, "reason": "缺料：" + ", ".join(c["lack"])}
	cargo.pay_repair(part, amount)
	ship.apply_damage(part, -amount)
	return {"ok": true, "part": part, "amount": amount}


func total_goods_units() -> int:
	"""港口里所有货物的件数（与船上的合起来看：买卖只搬货）。"""
	var total := 0
	for p in stock.keys():
		for k in (stock[p] as Dictionary).keys():
			total += int(stock[p][k])
	return total


func describe(port: String) -> String:
	return "%s：%d 种货，服务 %s" % [
		str(port_def(port).get("id", port)), trades(port).size(), ", ".join(services(port))]


# ------------------------------------------------------------ 存档（WorldState，docs/14 第 2 节）

func capture_state() -> Dictionary:
	# 键名 = 变量名（`stock`），这样 test_save 的字段覆盖断言能逐个核对
	var out := {}
	for p in stock.keys():
		out[str(p)] = (stock[p] as Dictionary).duplicate()
	return {"stock": out}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	var src_all: Dictionary = d.get("stock", d)
	for p in src_all.keys():
		var src: Dictionary = src_all[p]
		var dst: Dictionary = {}
		for k in src.keys():
			dst[str(k)] = int(src[k])
		stock[str(p)] = dst
