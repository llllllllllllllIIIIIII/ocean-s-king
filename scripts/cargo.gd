class_name Cargo
extends RefCounted

# 货舱（M4）：一条船上装了什么。
#
# 三条规矩：
#   1. **真源是 `data/defs/resources.json`** —— 一个单位多重、一天吃多少、
#      修满船体要几捆木头，全在那儿，代码里不写死（和 ship_physics / weapons 同一条规矩）；
#   2. **载重上限**来自船的数据（`caravel_60.json` 的 `deadweight_t`），
#      不是写死的 27 吨 —— 换一条船就换一份载重；
#   3. 它是**本船状态**（拥有者权威）：谁开的船谁管它的货舱。联网时货舱不上网，
#      摘要里只带"装了多重 / 有多少钱"（docs/14 第 3 节）。

const DEFS_PATH := "res://data/defs/resources.json"

static var _defs_cache: Dictionary = {}

var defs: Dictionary = {}            # 静态：从 JSON 读进来（不进存档）
var items: Dictionary = {}           # id -> 数量（**会变的值**）
var money := 0
var capacity_kg := 27000.0
var shortage_total := 0.0            # 累计缺了多少（缺粮缺水的量，M5 拿它算士气）
var starving := false
var _frac: Dictionary = {}           # id -> 攒着的小数（不足一个单位的部分）


static func defs_data() -> Dictionary:
	if _defs_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DEFS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_defs_cache = d
		else:
			push_error("资源表读不出来：" + DEFS_PATH)
	return _defs_cache


static func deadweight_from_ship(path := "res://data/ships/caravel_60.json") -> float:
	"""载重来自**船的数据**（`caravel_60.json` 的 deadweight_t），不是代码里的常数。

	换一条船就换一份载重 —— 船是数据不是代码（AGENTS.md 铁律 2）。
	"""
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("读不到船的载重：" + path + "（先用 27 吨）")
		return 27.0
	return float((d.get("hull", {}) as Dictionary).get("deadweight_t", 27.0))


static func item_liters(id := "water") -> float:
	"""一"单位"有多少升（只有淡水用得上）。"""
	for it in defs_data().get("items", []):
		if str(it.get("id", "")) == id:
			return maxf(1.0, float(it.get("liters", 60.0)))
	return 60.0


func setup(deadweight_t := 27.0, with_start_load := true) -> void:
	defs = defs_data()
	capacity_kg = maxf(0.0, deadweight_t * 1000.0)
	items.clear()
	money = 0
	starving = false
	shortage_total = 0.0
	if not with_start_load:
		return
	# 出发时的存货写在资源表里（塞维利亚装好的那一份）
	var start: Dictionary = defs.get("start_load", {})
	for k in start.keys():
		if str(k) == "ducats":
			money = int(start[k])
		else:
			items[str(k)] = int(start[k])


func item_def(id: String) -> Dictionary:
	for it in defs.get("items", []):
		if str(it.get("id", "")) == id:
			return it
	return {}


func item_name(id: String) -> String:
	return str(item_def(id).get("name", id))


func item_unit(id: String) -> String:
	return str(item_def(id).get("unit", ""))


func unit_kg(id: String) -> float:
	return float(item_def(id).get("kg", 0.0))


func ids_of_kind(kind: String) -> Array:
	var out := []
	for it in defs.get("items", []):
		if str(it.get("kind", "")) == kind:
			out.append(str(it["id"]))
	return out


func qty(id: String) -> int:
	return int(items.get(id, 0))


func has(id: String, n: int) -> bool:
	return qty(id) >= n


func used_kg() -> float:
	var total := 0.0
	for id in items.keys():
		total += float(items[id]) * unit_kg(str(id))
	return total


func free_kg() -> float:
	return maxf(0.0, capacity_kg - used_kg())


func used_ratio() -> float:
	return used_kg() / maxf(capacity_kg, 1.0)


func fits(id: String, n: int) -> bool:
	return float(n) * unit_kg(id) <= free_kg() + 1e-6


func how_many_fit(id: String) -> int:
	var per := unit_kg(id)
	if per <= 0.0:
		return 9999
	return int(floor(free_kg() / per))


func add(id: String, n: int) -> bool:
	"""装货。**装不下就一件也不装**（返回 false）—— 不悄悄丢一半。"""
	if n <= 0:
		return true
	if not fits(id, n):
		return false
	items[id] = qty(id) + n
	return true


func remove(id: String, n: int) -> bool:
	if n <= 0:
		return true
	if not has(id, n):
		return false
	items[id] = qty(id) - n
	if items[id] <= 0:
		items.erase(id)
	return true


func total_goods_units() -> int:
	"""所有东西的件数（守恒断言用：买卖只搬货，不造货）。"""
	var total := 0
	for id in items.keys():
		total += int(items[id])
	return total


func total_goods_kg() -> float:
	return used_kg()


# ------------------------------------------------------------ 消耗

func consume(days: float, crew: int, food_mult := 1.0, water_mult := 1.0) -> Dictionary:
	"""按人数扣口粮与淡水。返回这一轮缺了多少（不缺就是 0）。

	口径：一天一个水手一份食物、三升水（`resources.json` 的 consumption 段）。
	缺了**不会凭空变出来** —— 只记账（`shortage_total`）；
	士气与效率的后果是 M5 的规则与事件的事。

	⚠️ 扣的时候按**小数**精确记账（`_take`）：一桶水六十升，四十个人一分钟
	只喝十升 —— 每次结算都"进一位"的话，水会被放大六倍，一个上午就把一船水喝光。
	"""
	var cons: Dictionary = defs.get("consumption", {})
	var food_per := float(cons.get("ration_per_person_day", 1.0))
	var water_l := float(cons.get("water_l_per_person_day", 3.0))
	var want_food := float(crew) * food_per * days * food_mult
	var liters_per_barrel := maxf(1.0, float(item_def("water").get("liters", 60)))
	var want_water := float(crew) * water_l * days * water_mult / liters_per_barrel
	var short_food := _take("food", want_food)
	var short_water := _take("water", want_water)
	var short := short_food + short_water
	if short > 0:
		shortage_total += float(short)
		starving = true
	return {
		"days": days,
		"want_food": int(floor(want_food + 0.5)), "got_food": int(floor(want_food + 0.5)) - short_food,
		"want_water": int(floor(want_water + 0.5)), "got_water": int(floor(want_water + 0.5)) - short_water,
		"short": short,
	}


func _take(id: String, want: float) -> int:
	"""按小数精确扣：不足一个单位的先攒着，攒够一件才真扣。

	返回**缺了几件**（0 = 够）。缺的时候小数继续攒着，所以连着几轮缺下来，
	账是对得上的 —— 不会因为"每次都要至少一件"而虚报消耗。
	"""
	var debt := float(_frac.get(id, 0.0)) + want
	var whole := int(floor(debt))
	_frac[id] = debt - float(whole)
	if whole <= 0:
		return 0
	var got := mini(whole, qty(id))
	remove(id, got)
	return whole - got


func can_shoot() -> bool:
	"""M6 的联动词：没有火药铅弹火绳就打不了仗（这一期先把账算清楚）。"""
	return qty("powder") > 0 and qty("lead") > 0 and qty("match") > 0


# ------------------------------------------------------------ 修船

func repair_need(part: String, amount: float) -> Dictionary:
	"""修好 `amount`（0..1）需要多少料。修一半就是一半。"""
	var table: Dictionary = defs.get("repair", {})
	var row: Dictionary = table.get(part, {})
	var out := {}
	for k in row.keys():
		out[str(k)] = float(row[k]) * amount
	return out


func can_repair(part: String, amount: float) -> Dictionary:
	var need := repair_need(part, amount)
	var lack := PackedStringArray()
	for k in need.keys():
		if str(k) == "ducats":
			if float(money) < float(need[k]):
				lack.append("金币")
		elif qty(str(k)) < int(ceil(float(need[k]))):
			lack.append(item_name(str(k)))
	return {"ok": lack.is_empty(), "need": need, "lack": lack}


func pay_repair(part: String, amount: float) -> bool:
	var c := can_repair(part, amount)
	if not bool(c["ok"]):
		return false
	var need: Dictionary = c["need"]
	for k in need.keys():
		if str(k) == "ducats":
			money -= int(round(float(need[k])))
		else:
			remove(str(k), int(ceil(float(need[k]))))
	return true


# ------------------------------------------------------------ 给界面用

func describe() -> String:
	return "载重 %.1f/%.1f 吨　金币 %d" % [
		used_kg() / 1000.0, capacity_kg / 1000.0, money]


func lines(max_lines := 12) -> Array:
	var out := []
	for it in defs.get("items", []):
		var id := str(it["id"])
		if qty(id) <= 0:
			continue
		out.append("%s %d %s" % [str(it["name"]), qty(id), str(it.get("unit", ""))])
		if out.size() >= max_lines:
			break
	if out.is_empty():
		out.append("货舱是空的")
	return out


# ------------------------------------------------------------ 存档（ShipState，docs/14 第 3 节）
# defs 与 capacity_kg 是**静态数据**（表 + 船的数据），读档时重新加载，所以不进存档。

func capture_state() -> Dictionary:
	return {
		"items": items.duplicate(),
		"money": money,
		"shortage_total": shortage_total,
		"starving": starving,
		"_frac": _frac.duplicate(),
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	items = {}
	var src: Dictionary = d.get("items", {})
	for k in src.keys():
		items[str(k)] = int(src[k])
	money = int(d.get("money", 0))
	shortage_total = float(d.get("shortage_total", 0.0))
	starving = bool(d.get("starving", false))
	_frac = {}
	var fr: Dictionary = d.get("_frac", {})
	for k in fr.keys():
		_frac[str(k)] = float(fr[k])
