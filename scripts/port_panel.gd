class_name PortPanel
extends Control

# 港口面板（M4）：靠港之后的一张单子 —— 补给、修船、买卖。
#
# 一屏回答四个问题：我在哪个港、船上还剩什么、这个港有什么、这笔生意划不划算。
# 它**只读 Voyage 的公开入口**（port_buy / port_sell / port_repair / port_supply_bundle），
# 自己不改任何状态 —— 玩法不藏在界面里（和帆态面板同一条规矩）。

const PANEL := Vector2(980, 660)
const QTY_STEPS := [1, 5, 25, 100]

var font: Font
var voyage: Voyage
var row := 0
var qty_idx := 1                    # 默认一次买 5 件
var note := ""


func qty() -> int:
	return int(QTY_STEPS[qty_idx % QTY_STEPS.size()])


func rows() -> Array:
	var out := [{"kind": "supply", "label": "一键补给（按到下一个港算，留一点余量）"}]
	for part in ["hull", "mast", "rudder"]:
		out.append({"kind": "repair", "part": part,
			"label": "修%s（修满）" % {"hull": "船体", "mast": "桅杆", "rudder": "舵"}[part]})
	if voyage != null and voyage.docked_port != "":
		for item in voyage.ports.trades(voyage.docked_port):
			out.append({"kind": "item", "item": item})
	return out


func move(dir: int) -> void:
	var n := rows().size()
	if n <= 0:
		return
	row = clampi(row + dir, 0, n - 1)
	note = ""
	queue_redraw()


func cycle_qty(dir: int) -> void:
	qty_idx = posmod(qty_idx + dir, QTY_STEPS.size())
	note = ""
	queue_redraw()


func activate(buy: bool) -> void:
	"""回车/买/卖：动作行执行动作，货物行买或卖。"""
	var rs := rows()
	if row < 0 or row >= rs.size():
		return
	var r: Dictionary = rs[row]
	match str(r["kind"]):
		"supply":
			var res := voyage.port_supply_bundle()
			note = "补给了：%s，花了 %d 金币" % [str(res.get("bought", [])), int(res.get("spent", 0))] \
				if bool(res.get("ok", false)) else "补给没成：" + str(res.get("reason", ""))
		"repair":
			var res2 := voyage.port_repair(str(r["part"]), 1.0)
			note = "修好了" if bool(res2.get("ok", false)) else "修不了：" + str(res2.get("reason", ""))
		"item":
			var item := str(r["item"])
			var res3 := voyage.port_buy(item, qty()) if buy else voyage.port_sell(item, qty())
			if bool(res3.get("ok", false)):
				note = ("买了 %d %s" % [qty(), voyage.cargo.item_name(item)]) if buy \
					else ("卖了 %d %s" % [qty(), voyage.cargo.item_name(item)])
			else:
				note = str(res3.get("reason", "不行"))
	queue_redraw()


func _draw() -> void:
	if font == null or voyage == null:
		return
	var box := Rect2((size - PANEL) * 0.5, PANEL)
	draw_rect(box, Color(0.02, 0.05, 0.08, 0.95), true)
	draw_rect(box, Color(0.95, 0.8, 0.35, 0.75), false, 2.0)
	_text(box.position + Vector2(24, 38), "港口 · %s" % voyage.port_name(), 22,
		Color(1.0, 0.88, 0.52))
	_text(box.position + Vector2(24, 66),
		"%s　%s" % [voyage.fleet.name_of(voyage.fleet.local_id), voyage.cargo.describe()],
		14, Color(0.78, 0.85, 0.92))
	# 右半边：本船还缺什么（一眼看完）
	var need := voyage.supply_need_for(
		voyage.next_port_position().distance_to(voyage.ship.position_m()))
	_text(box.position + Vector2(560, 38), "开到下一个港要 %.1f 个航程日" % float(need["days"]),
		14, Color(0.82, 0.88, 0.95))
	_text(box.position + Vector2(560, 62),
		"需要食物 %d 份、淡水 %d 桶" % [int(need["food"]), int(need["water"])],
		14, Color(0.82, 0.88, 0.95))
	_text(box.position + Vector2(560, 86), "船上：食物 %d、淡水 %d　损伤 %s" % [
		voyage.cargo.qty("food"), voyage.cargo.qty("water"), voyage.ship.describe_damage()],
		14, Color(0.82, 0.88, 0.95))

	var y := box.position.y + 122.0
	_text(Vector2(box.position.x + 24, y),
		"↑↓ 选　←→ 数量 %d　B/回车 买或执行　E/R 卖　P/Esc 关" % qty(),
		13, Color(0.62, 0.7, 0.78))
	y += 22.0
	var rs := rows()
	for i in rs.size():
		if y > box.position.y + box.size.y - 66.0:
			break
		var r: Dictionary = rs[i]
		var sel := i == row
		if sel:
			draw_rect(Rect2(box.position.x + 16, y - 16, box.size.x - 32, 24),
				Color(0.16, 0.24, 0.32, 0.9), true)
		var col := Color(1.0, 0.9, 0.6) if sel else Color(0.84, 0.88, 0.93)
		match str(r["kind"]):
			"supply", "repair":
				_text(Vector2(box.position.x + 26, y), str(r["label"]), 15, col)
			"item":
				var item := str(r["item"])
				var pname := voyage.cargo.item_name(item)
				var unit := voyage.cargo.item_unit(item)
				var stock := voyage.ports.stock_of(voyage.docked_port, item)
				var buy_p := voyage.ports.buy_price(voyage.docked_port, item)
				var sell_p := voyage.ports.sell_price(voyage.docked_port, item)
				var hold := voyage.cargo.qty(item)
				_text(Vector2(box.position.x + 26, y), pname, 15, col)
				_text(Vector2(box.position.x + 190, y), "港 %d %s" % [stock, unit], 14, col)
				_text(Vector2(box.position.x + 330, y), "船上 %d" % hold, 14, col)
				_text(Vector2(box.position.x + 440, y), "买 %d" % buy_p, 14,
					Color(1.0, 0.78, 0.62) if sel else col)
				_text(Vector2(box.position.x + 540, y), "卖 %d" % sell_p, 14,
					Color(0.7, 0.95, 0.75) if sel else col)
		y += 26.0
	if note != "":
		_text(box.position + Vector2(24, box.size.y - 32), note, 15, Color(1.0, 0.86, 0.5))
	else:
		_text(box.position + Vector2(24, box.size.y - 32),
			"金币 %d　载重 %.1f/%.1f 吨" % [voyage.cargo.money,
				voyage.cargo.used_kg() / 1000.0, voyage.cargo.capacity_kg / 1000.0],
			15, Color(0.8, 0.86, 0.92))


func _text(at: Vector2, s: String, px: int, col: Color) -> void:
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, col)


func handle_key(k: InputEventKey) -> bool:
	if not visible:
		return false
	match k.keycode:
		KEY_UP, KEY_W:
			move(-1)
		KEY_DOWN, KEY_S:
			move(1)
		KEY_LEFT, KEY_A:
			cycle_qty(-1)
		KEY_RIGHT, KEY_D:
			cycle_qty(1)
		KEY_B:
			activate(true)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			activate(true)
		KEY_E:
			activate(false)
		KEY_ESCAPE, KEY_P:
			visible = false
		KEY_R:
			# R = 卖（放在这里是因为 S 已经给"往下选"了 —— 键位冲突要当场解决）
			activate(false)
		_:
			return false
	return true
