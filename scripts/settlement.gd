class_name Settlement
extends RefCounted

# 船队结算（M8）：把六期攒下来的东西拼成**五类成果**，再给一个三档评价。
#
# 它**不产生任何新状态** —— 只是把已经存在的账摊开：
#   ending_score（抉择与死亡）· journal（到过哪、做了什么决定、航程）
#   knowledge（发现）· memory（世界记住的事）· roster（人）· cargo（钱与货）
#   fleet（四条船各自到哪儿了）
#
# 所以"结算页"不是另写一段文案，而是**这本账的封面**。

const CATEGORIES := [
	{ "id": "wealth", "name": "财富" },
	{ "id": "voyage", "name": "航海" },
	{ "id": "knowledge", "name": "知识" },
	{ "id": "crew", "name": "船员" },
	{ "id": "history", "name": "历史与政治" },
]

# 三档的门槛（总分）。砍单预案说"先出三档、不给细分评分"——
# 但每一类的分与依据都摊在页面上，玩家看得见分是怎么来的。
const GLORY_SCORE := 220
const SUCCESS_SCORE := 120

# M19：四档结局的真源（判定顺序与条件都写在数据里）
const ENDINGS_PATH := "res://data/defs/endings.json"
static var _endings_cache: Array = []


static func endings() -> Array:
	if _endings_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(ENDINGS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			var list: Array = d.get("endings", [])
			list.sort_custom(func(a, b): return int(a.get("priority", 0)) > int(b.get("priority", 0)))
			_endings_cache = list
		else:
			push_error("结局表读不出来：" + ENDINGS_PATH)
	return _endings_cache


static func ending_ids() -> Array:
	var out := []
	for e in endings():
		out.append(str((e as Dictionary).get("id", "")))
	return out


static func _meets(req: Dictionary, ctx: Dictionary) -> bool:
	"""一条结局的条件（每一把钥匙都要满足）。条件类型只有这一处解释。"""
	for key in req.keys():
		var want = req[key]
		match str(key):
			"total_min":
				if float(ctx.get("total", 0.0)) < float(want):
					return false
			"total_max":
				if float(ctx.get("total", 0.0)) > float(want):
					return false
			"all_arrived":
				if bool(want) != bool(ctx.get("all_arrived", false)):
					return false
			"arrived_min":
				if int(ctx.get("arrived", 0)) < int(want):
					return false
			"orders_done_min":
				if int(ctx.get("orders_done", 0)) < int(want):
					return false
			"orders_broken_min":
				if int(ctx.get("orders_broken", 0)) < int(want):
					return false
			"any_broken":
				if bool(want) and int(ctx.get("orders_broken", 0)) <= 0:
					return false
			"memory_min":
				for k in (want as Dictionary).keys():
					if int((ctx.get("memory", {}) as Dictionary).get(str(k), 0)) < int(want[k]):
						return false
			"memory_max":
				for k in (want as Dictionary).keys():
					if int((ctx.get("memory", {}) as Dictionary).get(str(k), 0)) > int(want[k]):
						return false
			"flag":
				if not (ctx.get("flags", {}) as Dictionary).has(str(want)):
					return false
			"not_flag":
				if (ctx.get("flags", {}) as Dictionary).has(str(want)):
					return false
	return true


static func ending_for(ctx: Dictionary) -> Dictionary:
	"""这一局落进哪一档（**从上到下第一个满足条件的** —— 四档互斥且覆盖全部）。"""
	for e in endings():
		var d: Dictionary = e
		if _meets(d.get("requires", {}), ctx):
			return d
	return {}


static func cargo_value(cargo: Cargo) -> int:
	"""船上的货按**基准价**折算成金币（不是按卖价 —— 那是还没卖出去的东西）。"""
	var total := float(cargo.money)
	for it in cargo.defs.get("items", []):
		var id := str(it.get("id", ""))
		var n := cargo.qty(id)
		if n > 0:
			total += float(n) * float(it.get("base_price", 1.0))
	return int(total)


static func report(v: Voyage) -> Dictionary:
	"""一份五类成果 + 三档评价。返回的是**数**，页面只负责排版。"""
	var cargo: Cargo = v.cargo
	var k: Knowledge = v.knowledge
	var fleet_rows := fleet_report(v)
	var arrived := 0
	for r in fleet_rows:
		if bool(r["arrived"]):
			arrived += 1

	# ---- 财富 ----
	var value := cargo_value(cargo)
	# M19：探索捞到的东西也算财富（M18 的 `find_log`）
	var wealth_score := int(value / 100.0) + int(v.ending_score.get("wealth", 0)) * 5 \
		+ v.find_log.size() * 4
	var wealth := {
		"value": value, "money": cargo.money,
		"finds": v.find_log.size(),
		"score": wealth_score,
		"lines": [
			"金币 %d，船上的货按基准价折算 %d" % [cargo.money, value - cargo.money],
			"载重 %.1f/%.1f 吨" % [cargo.used_kg() / 1000.0, cargo.capacity_kg / 1000.0],
			"贸易过 %d 次，打捞过 %d 次，探索产出 %d 处" % [
				int(v.memory.get("traded", 0)), int(v.memory.get("salvage", 0)),
				v.find_log.size()],
		],
	}

	# ---- 航海 ----
	var ports := k.count_of("trade")
	var voyage_score := int(v.journal.distance_km()) / 4 + v.discovered_tiles() * 3 + ports * 5 \
		+ v.chart_flags.size() * 2
	var voyage_block := {
		"distance_km": v.journal.distance_km(),
		"tiles": v.discovered_tiles(), "total_tiles": v.total_tiles(),
		"landfalls": v.journal.landfalls.size(), "ports": ports,
		"beat": v.nav.beat_count, "tack": v.nav.tack_count,
		"flags": v.chart_flags.size(), "regions": v.discovered_regions(),
		"score": voyage_score,
		"lines": [
			"航程 %.1f 公里，抢风 %d 段（换舷 %d 次）" % [
				v.journal.distance_km(), v.nav.beat_count, v.nav.tack_count],
			"探明 %d/%d 块海图，到过 %d 个地标" % [
				v.discovered_tiles(), v.total_tiles(), v.journal.landfalls.size()],
			"停靠过 %d 个港" % ports,
			"走过 %d 个分区图幅，海图上插了 %d 面旗" % [v.discovered_regions(), v.chart_flags.size()],
		],
	}

	# ---- 知识 ----
	var knowledge_score := k.count() * 3 + int(v.ending_score.get("knowledge", 0)) * 5 \
		+ v.known_peoples.size() * 4
	var knowledge := {
		"count": k.count(), "peoples": v.known_peoples.size(),
		"sold": int(v.memory.get("sold_charts", 0)), "score": knowledge_score,
		"lines": [
			k.describe(),
			"海图 %d　风向洋流 %d　物种 %d" % [
				k.count_of("chart"), k.count_of("current"), k.count_of("species")],
			"文化 %d　语言 %d　贸易 %d　战争 %d" % [
				k.count_of("culture"), k.count_of("language"),
				k.count_of("trade"), k.count_of("war")],
			"遇到过的民族 %d 个，卖出去的知识 %d 条" % [
				v.known_peoples.size(), int(v.memory.get("sold_charts", 0))],
		],
	}

	# ---- 船员 ----
	var alive := 0
	var dead := 0
	var hurt := 0
	var mood_sum := 0.0
	for m in v.roster.members:
		if m.dead:
			dead += 1
		else:
			alive += 1
			mood_sum += m.mood
			if m.health < 0.8:
				hurt += 1
	var avg_mood := mood_sum / maxf(1.0, float(alive))
	var crew_score := alive - dead * 12 - hurt * 3 + int(avg_mood * 20.0) \
		+ int(v.society.discipline * 20.0) + int(v.ending_score.get("crew", 0)) * 5 \
		+ v.roster.recruited * 2
	var crew := {
		"alive": alive, "dead": dead, "hurt": hurt, "mood": avg_mood,
		"discipline": v.society.discipline, "events": v.society.event_count,
		"recruited": v.roster.recruited, "faith": v.roster.avg_faith(),
		"captain": v.roster.avg_captain(), "mutiny": v.society.mutiny_stage,
		"score": crew_score,
		"lines": [
			"生还 %d 人，阵亡 %d 人，带伤 %d 人" % [alive, dead, hurt],
			"平均心情 %.0f%%，纪律 %.0f%%" % [avg_mood * 100.0, v.society.discipline * 100.0],
			"船上出过 %d 次事（最后一条：%s）" % [
				v.society.event_count, v.society.last_event if v.society.last_event != "" else "无"],
			"路上招了 %d 个人；信仰 %.2f、对船长的态度 %.2f；叛乱阶梯到第 %d 档" % [
				v.roster.recruited, v.roster.avg_faith(), v.roster.avg_captain(),
				v.society.mutiny_stage],
		],
	}

	# ---- 历史与政治 ----
	# M19：**王室命令的执行度直接进这一档**（完成加分、违抗扣分），它也就直接改结局档位
	var orders := v.factions.evaluate_orders(v.royal_order_ctx())
	var orders_done := 0
	var orders_broken := 0
	for o in orders:
		if bool((o as Dictionary).get("broken", false)):
			orders_broken += 1
		elif bool((o as Dictionary).get("done", false)):
			orders_done += 1
	var history_score := int(v.ending_score.get("history", 0)) * 5 \
		- int(v.memory.get("broken_faith", 0)) * 6 \
		- int(v.memory.get("killed", 0)) * 5 \
		+ orders_done * 6 - orders_broken * 8 - v.lost_ships.size() * 4
	var green := v.culture.describe("green_cape")
	var history := {
		"score": history_score, "stance": v.culture.stance_name("green_cape"),
		"orders_done": orders_done, "orders_broken": orders_broken,
		"ships_lost": v.lost_ships.size(),
		"castile": v.factions.value("castile"), "portugal": v.factions.value("portugal"),
		"locals": v.factions.value("locals"),
		"lines": [
			green,
			"世界记住的：%s" % _memory_line(v.memory),
			"王室的命令：完成 %d 条、违抗 %d 条" % [orders_done, orders_broken],
			"势力态度：卡斯蒂利亚 %.2f　葡萄牙 %.2f　当地人 %.2f" % [
				v.factions.value("castile"), v.factions.value("portugal"),
				v.factions.value("locals")],
			"路上丢了 %d 条船" % v.lost_ships.size(),
		],
	}

	var scores := {
		"wealth": wealth_score, "voyage": voyage_score, "knowledge": knowledge_score,
		"crew": crew_score, "history": history_score,
	}
	var total := 0
	for key in scores.keys():
		total += int(scores[key])
	# M19：四档结局 —— 条件在 `data/defs/endings.json`，这里只把这一局的账摆成 ctx
	var ctx := ending_context(v, total, arrived, fleet_rows)
	var ending := ending_for(ctx)
	var verdict := str(ending.get("name", "失败式归来"))
	return {
		"wealth": wealth, "voyage": voyage_block, "knowledge": knowledge,
		"crew": crew, "history": history,
		"scores": scores, "total": total, "verdict": verdict,
		"ending": ending, "ending_id": str(ending.get("id", "failed")),
		"imprison": bool(ending.get("imprison", false)),
		"ending_text": str(ending.get("text", "")),
		"ending_reason": str(ending.get("reason", "")),
		"ctx": ctx,
		"fleet": fleet_rows, "arrived": arrived, "fleet_size": v.fleet.count(),
	}


static func ending_context(v: Voyage, total: int, arrived: int, fleet_rows: Array) -> Dictionary:
	"""这一局摆到结局判定面前的那几个数（**全部来自已有的账**，不新造状态）。

	王室命令走 M11 的求值器（`Factions.evaluate_orders`）：完成几条、违抗几条。
	"""
	var orders_ctx := v.royal_order_ctx()
	var results: Array = v.factions.evaluate_orders(orders_ctx)
	var done := 0
	var broken := 0
	for r in results:
		if bool((r as Dictionary).get("broken", false)):
			broken += 1
		elif bool((r as Dictionary).get("done", false)):
			done += 1
	return {
		"total": total, "arrived": arrived, "fleet_size": int(fleet_rows.size()),
		"all_arrived": arrived >= int(fleet_rows.size()) and int(fleet_rows.size()) > 0,
		"orders_done": done, "orders_broken": broken,
		"orders": results,
		"memory": v.memory.duplicate(),
		"flags": v.fired.duplicate(),
		"finds": v.find_log.size(), "peoples": v.known_peoples.size(),
		"ships_lost": v.lost_ships.size(),
	}


static func _memory_line(memory: Dictionary) -> String:
	if memory.is_empty():
		return "还什么都没记"
	var parts := PackedStringArray()
	for key in memory.keys():
		parts.append("%s %d" % [str(key), int(memory[key])])
	return "、".join(parts)


static func fleet_report(v: Voyage) -> Array:
	"""四条船各自到哪儿了、伤了多少、发现了多少 —— 全队结算的那张表。

	"到达"的判据：开到**这一程的终点港**的锚地圈里 ——
	v0.5（大西洋单程）是圣阿莱克索（巴西）；M15 起全球图的终点是**归乡港**圣卢卡尔。
	"""
	var goal := Vector2.ZERO
	var want := v.home_port_id()
	if want == "":
		want = "sao_aleixo"
	for p in v.sea.ports():
		if str(p.get("id", "")) == want:
			goal = Geom2D.centroid(p["shape"])
	if goal == Vector2.ZERO:
		goal = v.sea.port_pos()
	var rows := []
	for id in v.fleet.ids():
		var sm: Dictionary = v.fleet.summary_of(id)
		if sm.is_empty():
			continue
		var p: Array = sm.get("pos", [0.0, 0.0])
		var pos := Vector2(float(p[0]), float(p[1]))
		rows.append({
			"id": id, "name": v.fleet.name_of(id), "kind": v.fleet.kind_of(id),
			# 抵达是个**闩**：到过一次就一直算到过（洋流会把停在港里的船带走）
			"arrived": v.fleet.arrived.has(id) or pos.distance_to(goal) <= Fleet.ARRIVE_RADIUS_M,
			"distance_to_goal_m": pos.distance_to(goal),
			"hull_pct": float(sm.get("hull_pct", 1.0)),
			"crew_count": int(sm.get("crew_count", 0)),
			"hold_kg": float(sm.get("hold_kg", 0.0)),
			"action": str(sm.get("action", "")),
		})
	return rows


static func text(v: Voyage, journal: VoyageJournal, story: Story) -> String:
	"""把五类成果排成一页（结算页显示的就是它）。"""
	var r := report(v)
	var out := PackedStringArray()
	out.append("环球航行 · 船队结算")
	out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	out.append("%s（第 %d 天）　评价：%s　总分 %d" % [
		VoyageJournal.date_cn(v.t), VoyageJournal.day_index(v.t) + 1,
		str(r["verdict"]), int(r["total"])])
	# M19：四档结局 —— 档位、理由、以及"完成但被惩罚"那一条
	if str(r.get("ending_text", "")) != "":
		out.append("「%s」" % str(r["verdict"]))
		out.append("  " + str(r["ending_text"]))
		out.append("  理由：" + str(r["ending_reason"]))
		if bool(r.get("imprison", false)):
			out.append("  ⚠ 远征队的账被封存，船长被带走了。")
	out.append("")
	var blocks := [
		["wealth", "【财富】"], ["voyage", "【航海】"],
		["knowledge", "【知识】"], ["crew", "【船员】"], ["history", "【历史与政治】"],
	]
	for b in blocks:
		var d: Dictionary = r[str(b[0])]
		out.append("%s　%d 分" % [str(b[1]), int(d["score"])])
		for line in d["lines"]:
			out.append("  · " + str(line))
		out.append("")
	out.append("【船队】%d/%d 条船抵达%s" % [
		int(r["arrived"]), int(r["fleet_size"]), v.goal_port_name()])
	if (r.get("fleet", []) as Array).size() > 0 and v.lost_ships.size() > 0:
		var lost_names := PackedStringArray()
		for rec in v.lost_ships:
			lost_names.append(str((rec as Dictionary).get("name", "?")))
		out.append("【损失】%s" % "、".join(lost_names))
	for row in r["fleet"]:
		out.append("  · %s%s　船体 %.0f%%　%d 人　%s" % [
			str(row["name"]),
			"（我）" if str(row["kind"]) == Fleet.KIND_LOCAL else "",
			float(row["hull_pct"]) * 100.0, int(row["crew_count"]),
			"已抵达" if bool(row["arrived"]) else "距终点 %.0f 公里" % (
				float(row["distance_to_goal_m"]) / 1000.0)])
	out.append("")
	out.append("【你做的决定】")
	if journal.decisions.is_empty():
		out.append("  · 这一趟，你没有做过一个需要负责的决定。")
	else:
		for d in journal.decisions:
			out.append("  · " + str(d))
	out.append("")
	out.append("【文书最后写下的一条】")
	out.append("  “%s”" % (journal.last_line if journal.last_line != "" else "风平浪静，无事可记。"))
	return "\n".join(out)
