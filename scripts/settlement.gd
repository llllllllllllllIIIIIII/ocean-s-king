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
	var wealth_score := int(value / 100.0) + int(v.ending_score.get("wealth", 0)) * 5
	var wealth := {
		"value": value, "money": cargo.money,
		"score": wealth_score,
		"lines": [
			"金币 %d，船上的货按基准价折算 %d" % [cargo.money, value - cargo.money],
			"载重 %.1f/%.1f 吨" % [cargo.used_kg() / 1000.0, cargo.capacity_kg / 1000.0],
			"贸易过 %d 次，打捞过 %d 次" % [
				int(v.memory.get("traded", 0)), int(v.memory.get("salvage", 0))],
		],
	}

	# ---- 航海 ----
	var ports := k.count_of("trade")
	var voyage_score := int(v.journal.distance_km()) / 4 + v.discovered_tiles() * 3 + ports * 5
	var voyage_block := {
		"distance_km": v.journal.distance_km(),
		"tiles": v.discovered_tiles(), "total_tiles": v.total_tiles(),
		"landfalls": v.journal.landfalls.size(), "ports": ports,
		"beat": v.nav.beat_count, "tack": v.nav.tack_count,
		"score": voyage_score,
		"lines": [
			"航程 %.1f 公里，抢风 %d 段（换舷 %d 次）" % [
				v.journal.distance_km(), v.nav.beat_count, v.nav.tack_count],
			"探明 %d/%d 块海图，到过 %d 个地标" % [
				v.discovered_tiles(), v.total_tiles(), v.journal.landfalls.size()],
			"停靠过 %d 个港" % ports,
		],
	}

	# ---- 知识 ----
	var knowledge_score := k.count() * 3 + int(v.ending_score.get("knowledge", 0)) * 5
	var knowledge := {
		"count": k.count(), "score": knowledge_score,
		"lines": [
			k.describe(),
			"海图 %d　风向洋流 %d　物种 %d" % [
				k.count_of("chart"), k.count_of("current"), k.count_of("species")],
			"文化 %d　语言 %d　贸易 %d　战争 %d" % [
				k.count_of("culture"), k.count_of("language"),
				k.count_of("trade"), k.count_of("war")],
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
		+ int(v.society.discipline * 20.0) + int(v.ending_score.get("crew", 0)) * 5
	var crew := {
		"alive": alive, "dead": dead, "hurt": hurt, "mood": avg_mood,
		"discipline": v.society.discipline, "events": v.society.event_count,
		"score": crew_score,
		"lines": [
			"生还 %d 人，阵亡 %d 人，带伤 %d 人" % [alive, dead, hurt],
			"平均心情 %.0f%%，纪律 %.0f%%" % [avg_mood * 100.0, v.society.discipline * 100.0],
			"船上出过 %d 次事（最后一条：%s）" % [
				v.society.event_count, v.society.last_event if v.society.last_event != "" else "无"],
		],
	}

	# ---- 历史与政治 ----
	var history_score := int(v.ending_score.get("history", 0)) * 5 \
		- int(v.memory.get("broken_faith", 0)) * 6 \
		- int(v.memory.get("killed", 0)) * 5
	var green := v.culture.describe("green_cape")
	var history := {
		"score": history_score, "stance": v.culture.stance_name("green_cape"),
		"lines": [
			green,
			"世界记住的：%s" % _memory_line(v.memory),
			"王室的命令：%s" % ("执行到底" if bool(v.story.ending_ready) else "还没走完"),
		],
	}

	var scores := {
		"wealth": wealth_score, "voyage": voyage_score, "knowledge": knowledge_score,
		"crew": crew_score, "history": history_score,
	}
	var total := 0
	for key in scores.keys():
		total += int(scores[key])
	var verdict := "失败式归来"
	if total >= GLORY_SCORE and arrived >= v.fleet.count():
		verdict = "巨大荣誉"
	elif total >= SUCCESS_SCORE:
		verdict = "普通成功"
	return {
		"wealth": wealth, "voyage": voyage_block, "knowledge": knowledge,
		"crew": crew, "history": history,
		"scores": scores, "total": total, "verdict": verdict,
		"fleet": fleet_rows, "arrived": arrived, "fleet_size": v.fleet.count(),
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

	"到达"的判据：开到**圣阿莱克索（巴西）**的锚地圈里（终点港，docs/13 第 10 节的航段）。
	"""
	var goal := Vector2.ZERO
	for p in v.sea.ports():
		if str(p.get("id", "")) == "sao_aleixo":
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
			"arrived": pos.distance_to(goal) <= 900.0,
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
	out.append("【船队】%d/%d 条船抵达圣阿莱克索" % [int(r["arrived"]), int(r["fleet_size"])])
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
