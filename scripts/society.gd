class_name Society
extends RefCounted

# 船上社会（M5）：四十个人之间的关系、小群体、紧张度，以及**按严重度递进**的
# 矛盾事件（争吵 → 打架 → 偷窃 → 赌博 → 酗酒 → 消极怠工 → 违抗 → 逃亡 → 叛乱）。
#
# 三条设计：
#   1. **一切可量化**：关系是 −1..1 的数，紧张度是 0..1 的数，纪律是 0..1 的数。
#      事件不是随机抽的，是"紧张度 + 纪律 + 规则"这三个量越过阈值挑出来的
#      （所以无头可测、联机可复现 —— 和 M6 的"不用随机数"是同一条纪律）。
#   2. **规则是甲方**：玩家定的规矩（`Rules`）直接给紧张度乘数与纪律加成，
#      社会这一层只是消费它们。改一条规矩 → 数值真的变，这条链路短到能一眼看完。
#   3. **它属于本船状态**：每条船有自己的四十个人，所以进 ShipState、不上网。

const GROUP_OFFICERS := "officers"
const GROUP_SAILORS := "sailors"
const GROUP_NOVICES := "novices"
const LOG_MAX := 8
const SOCIAL_STEP := 60.0            # 每 60 个游戏秒结算一次社会（≈ 半小时航程日）
const EVENT_COOLDOWN_DAYS := 0.8
# M15：逃亡事件**不许把船走空** —— 船上至少留这么多人（现实里剩下的人也不敢都走）
const MIN_CREW_ABOARD := 12

# 事件表：按严重度递进。`needs` 是触发条件（紧张度下限 + 额外的量），
# `effects` 是后果（全部是数）—— 每一条都会被 test_society 断言。
const EVENTS := [
	{
		"id": "quarrel", "name": "争吵", "severity": 1, "min_tension": 0.35,
		"mood": -0.02, "discipline": -0.02, "tension": -0.10, "affinity": -0.08,
		"text": "两个水手为了一个铺位吵起来，声音大得连舵手都回头。",
	},
	{
		"id": "slacking", "name": "消极怠工", "severity": 2, "min_tension": 0.45,
		"needs": {"max_discipline": 0.58},
		"mood": -0.01, "discipline": -0.06, "tension": -0.06, "affinity": -0.02,
		"text": "该收帆的时候有三个人在磨蹭。水手长喊了两遍。",
	},
	{
		"id": "gambling", "name": "赌博", "severity": 2, "min_tension": 0.50,
		"needs": {"liquor_not": "forbidden"},
		"mood": 0.02, "discipline": -0.07, "tension": -0.04, "affinity": -0.03,
		"text": "底舱有人用骰子赢走了一个月的工钱 —— 输的那个不肯认。",
	},
	{
		"id": "drunk", "name": "酗酒", "severity": 3, "min_tension": 0.55,
		"needs": {"liquor_is": "allowed"},
		"mood": 0.01, "discipline": -0.09, "tension": -0.03, "affinity": -0.04,
		"text": "有人在值班时喝倒了。帆没及时收，船横了一下。",
	},
	{
		"id": "theft", "name": "偷窃", "severity": 3, "min_tension": 0.60,
		"needs": {"starving": true},
		"mood": -0.05, "discipline": -0.08, "tension": -0.02, "affinity": -0.12,
		"text": "存粮少了一袋。没人承认，但所有人都知道是谁。",
	},
	{
		"id": "fight", "name": "打架", "severity": 4, "min_tension": 0.65,
		"mood": -0.06, "discipline": -0.06, "tension": -0.12, "affinity": -0.28,
		"hurt": 0.15,
		"text": "两个人在甲板上动了刀。外科医生缝了半夜。",
	},
	{
		"id": "defiance", "name": "违抗命令", "severity": 5, "min_tension": 0.72,
		"needs": {"max_discipline": 0.45},
		"mood": -0.04, "discipline": -0.12, "tension": -0.05, "affinity": 0.0,
		"text": "航海官下令换舷，有三个人当场没动。",
	},
	{
		"id": "desertion", "name": "逃亡", "severity": 6, "min_tension": 0.82,
		"needs": {"near_land": true},
		"mood": -0.08, "discipline": -0.16, "tension": -0.14, "affinity": -0.05,
		"deserters": 2,
		"text": "靠岸那晚有两个人不见了 —— 带着他们的那份口粮。",
	},
	{
		"id": "mutiny", "name": "叛乱", "severity": 7, "min_tension": 0.92,
		"needs": {"max_discipline": 0.35},
		"mood": -0.2, "discipline": -0.3, "tension": -0.25, "affinity": 0.0,
		"text": "有人把船长堵在艉楼里，要求掉头回西班牙。",
	},
]

var relations: Dictionary = {}       # "a|b" -> {"affinity": float, "favors": int, "grudge": int}
var cohesion: Dictionary = {}        # group id -> 0..1
var tension := 0.10                  # 0..1 全船紧张度
var discipline := 0.70               # 0..1 纪律
var log_lines: Array = []            # 最近的几条社会事件（面板会显示）
var event_count := 0
var last_event := ""
var _acc := 0.0                      # 社会结算的累加器（游戏秒）
var _cooldown := 0.0                 # 下一次事件之前要等多少个航程日
var _last_severity := 1
var pending: Array = []              # 这一帧要弹给玩家的事件（Voyage 取走）


func setup(roster: CrewRoster, seed_hash := 20261001) -> void:
	relations.clear()
	cohesion = {GROUP_OFFICERS: 0.62, GROUP_SAILORS: 0.55, GROUP_NOVICES: 0.58}
	tension = 0.10
	discipline = 0.70
	log_lines.clear()
	event_count = 0
	last_event = ""
	_acc = 0.0
	_cooldown = 0.0
	_last_severity = 1
	pending.clear()
	if roster == null:
		return
	# 初始关系：用 id_hash 摊开（**不用随机数**，测试要可复现），
	# 关键船员之间互相认识：有人亲近、有人看不顺眼。
	var keys: Array = roster.key_crew()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: CrewMember = keys[i]
			var b: CrewMember = keys[j]
			var h := absi(a.id_hash * 31 + b.id_hash + seed_hash)
			var affinity := float(h % 100) / 100.0 * 0.6 - 0.2      # −0.2 .. 0.4
			relation_between(a.id, b.id)["affinity"] = affinity
			relation_between(a.id, b.id)["favors"] = h % 3
			relation_between(a.id, b.id)["grudge"] = (h / 7) % 2


static func pair_key(a: String, b: String) -> String:
	return "%s|%s" % [a, b] if a < b else "%s|%s" % [b, a]


func relation_between(a: String, b: String) -> Dictionary:
	var k := pair_key(a, b)
	if not relations.has(k):
		relations[k] = {"affinity": 0.0, "favors": 0, "grudge": 0}
	return relations[k]


func bump_relation(a: String, b: String, delta: float, grudge := 0) -> void:
	var r := relation_between(a, b)
	r["affinity"] = clampf(float(r["affinity"]) + delta, -1.0, 1.0)
	if grudge != 0:
		r["grudge"] = maxi(0, int(r["grudge"]) + grudge)


func group_of(m: CrewMember) -> String:
	if m.is_key:
		return GROUP_OFFICERS if m.post in ["船长", "大副", "航海官", "文书", "外科医生"] \
			else GROUP_SAILORS
	match m.post:
		"见习", "侍童":
			return GROUP_NOVICES
	return GROUP_SAILORS


func group_name(id: String) -> String:
	match id:
		GROUP_OFFICERS: return "军官与绅士"
		GROUP_SAILORS: return "水手"
		GROUP_NOVICES: return "见习与侍童"
	return id


# ------------------------------------------------------------ 每帧

func tick(delta: float, roster: CrewRoster, rules: Rules, cargo: Cargo, near_land: bool) -> void:
	_acc += delta
	if _acc < SOCIAL_STEP:
		return
	var days := SOCIAL_STEP * VoyageJournal.voyage_time_scale / 86400.0
	_acc = 0.0
	_update(days, roster, rules, cargo, near_land)


func _update(days: float, roster: CrewRoster, rules: Rules, cargo: Cargo,
		near_land: bool) -> void:
	var avg_mood := _avg_mood(roster)
	var starving := cargo != null and cargo.starving
	# ① 关系：一起值班的人越走越近；饿着肚子的人越看越不顺眼
	var keys: Array = roster.key_crew()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: CrewMember = keys[i]
			var b: CrewMember = keys[j]
			var delta := 0.0
			if a.ashore or b.ashore:
				continue
			if a.job == b.job and a.working and b.working and a.job != "idle":
				delta += 0.02 * days            # 一起干活
			if starving:
				delta -= 0.05 * days            # 饿的时候什么都难看
			if a.health < 0.6 or b.health < 0.6:
				delta += 0.03 * days            # 有人受伤了，帮忙的人记在心上
			if absf(delta) > 1e-9:
				bump_relation(a.id, b.id, delta)
	# ② 小群体：凝聚力跟着"这个群体里人的心情"走
	for gid in cohesion.keys():
		var target := clampf(_group_mood(roster, gid) * 1.05 - 0.05, 0.0, 1.0)
		cohesion[gid] = clampf(float(cohesion[gid])
			+ clampf(target - float(cohesion[gid]), -0.06 * days, 0.06 * days), 0.0, 1.0)
	# ③ 紧张度：海上日子本身在磨人 + 饥饿 + 心情差，再乘玩家定的规矩
	var rise := 0.02 + (1.0 - avg_mood) * 0.06 + (0.08 if starving else 0.0)
	if near_land:
		rise += 0.03                            # 看得见陆地而靠不了岸，最磨人
	tension = clampf(tension + rise * days * rules.tension_mult(), 0.0, 1.0)
	# ④ 纪律：往"规矩 + 平均心情"决定的目标靠
	var d_target := clampf(0.5 + rules.discipline_bonus() + (avg_mood - 0.5) * 0.4, 0.0, 1.0)
	discipline = clampf(discipline + clampf(d_target - discipline, -0.08 * days, 0.08 * days),
		0.0, 1.0)
	# ⑤ 事件：紧张度够高、冷却过了，就挑一条**最重的**能触发的事件
	_cooldown = maxf(0.0, _cooldown - days)
	if _cooldown <= 0.0:
		var ev := pick_event(rules, cargo, near_land)
		if not ev.is_empty():
			_fire(ev, roster, rules)


func pick_event(rules: Rules, cargo: Cargo, near_land: bool) -> Dictionary:
	"""挑一条**最重的、能触发的**事件（表是按严重度排的，所以最后一个命中的就是它）。

	它是公开的：面板要用它显示"下一个可能的麻烦"，测试也要直接断言"紧张度越高越重"。
	"""
	var best: Dictionary = {}
	for ev in EVENTS:
		if tension < float(ev["min_tension"]):
			continue
		var needs: Dictionary = ev.get("needs", {})
		if needs.has("max_discipline") and discipline > float(needs["max_discipline"]):
			continue
		if needs.has("starving") and not (cargo != null and cargo.starving):
			continue
		if needs.has("near_land") and not near_land:
			continue
		if needs.has("liquor_is") and str(rules.choice.get("liquor", "")) != str(needs["liquor_is"]):
			continue
		if needs.has("liquor_not") and str(rules.choice.get("liquor", "")) == str(needs["liquor_not"]):
			continue
		best = ev                         # 表是按严重度排的：最后一个能触发的就是最重的
	return best


func _fire(ev: Dictionary, roster: CrewRoster, rules: Rules) -> void:
	event_count += 1
	last_event = str(ev["id"])
	_last_severity = int(ev["severity"])
	tension = clampf(tension + float(ev["tension"]), 0.0, 1.0)
	discipline = clampf(discipline + float(ev["discipline"]), 0.0, 1.0)
	_cooldown = EVENT_COOLDOWN_DAYS * (1.0 + 0.4 * float(ev["severity"]))
	# 心情与关系
	var keys: Array = roster.key_crew()
	for m in keys:
		if m.ashore:
			continue
		m.mood = clampf(m.mood + float(ev.get("mood", 0.0)), 0.0, 1.0)
	# 挑一对当事人（用 id_hash 挑，不用随机数）
	if keys.size() >= 2:
		var a: CrewMember = keys[absi(roster.log_lines.size() + event_count) % keys.size()]
		var b: CrewMember = keys[absi(event_count * 7 + 3) % keys.size()]
		if a != b:
			bump_relation(a.id, b.id, float(ev.get("affinity", 0.0)), 1 if int(ev["severity"]) >= 4 else 0)
	# 打架会伤人
	if ev.has("hurt"):
		for m in keys:
			if m.ashore:
				continue
			m.health = clampf(m.health - float(ev["hurt"]), 0.05, 1.0)
			break
	# 逃亡真的会少人
	if ev.has("deserters"):
		# ⚠️ M15：**不许把整船人走空**。三年尺度上，靠岸就少两个人、几十次下来
		# 船上只剩一条空船（长跑里真的抓到了：40 个人全部"上岸"，摘要报 0 人）。
		# 现实里也说得通：剩下的人不敢都走 —— 走光了船就沉在这儿。
		var aboard := 0
		for m in roster.members:
			if not m.ashore and not m.dead:
				aboard += 1
		var room := maxi(0, aboard - MIN_CREW_ABOARD)
		var want := mini(int(ev["deserters"]), room)
		var gone := 0
		for m in roster.members:
			if gone >= want:
				break
			if m.ashore:
				continue
			m.ashore = true                   # 人不在船上了（岸上那本账由 Voyage 收）
			m.job = "deserted"
			gone += 1
	var line := "%s：%s" % [str(ev["name"]), str(ev["text"])]
	log_lines.append(line)
	if log_lines.size() > LOG_MAX:
		log_lines.pop_front()
	pending.append({"id": str(ev["id"]), "name": str(ev["name"]),
		"text": str(ev["text"]), "severity": int(ev["severity"])})


func take_events() -> Array:
	var out := pending.duplicate()
	pending.clear()
	return out


func _avg_mood(roster: CrewRoster) -> float:
	if roster.members.is_empty():
		return 0.7
	var sum := 0.0
	var n := 0
	for m in roster.members:
		if m.ashore:
			continue
		sum += m.mood
		n += 1
	return sum / maxf(1.0, float(n))


func _group_mood(roster: CrewRoster, group_id: String) -> float:
	var sum := 0.0
	var n := 0
	for m in roster.members:
		if m.ashore or group_of(m) != group_id:
			continue
		sum += m.mood
		n += 1
	return sum / maxf(1.0, float(n))


# ------------------------------------------------------------ 给面板用

func avg_mood(roster: CrewRoster) -> float:
	return _avg_mood(roster)


func faction_report(roster: CrewRoster) -> Array:
	var out := []
	for gid in [GROUP_OFFICERS, GROUP_SAILORS, GROUP_NOVICES]:
		out.append("%s：凝聚 %.0f%%　心情 %.0f%%" % [
			group_name(gid), float(cohesion.get(gid, 0.0)) * 100.0,
			_group_mood(roster, gid) * 100.0])
	return out


func why_unhappy(m: CrewMember, roster: CrewRoster, rules: Rules) -> String:
	"""他为什么心情差 —— 面板要回答的就是这一个问题（关系 + 需求 + 最近的事）。

	顺序是刻意的：先说"身上"（饿/累/伤），再说"人际"（跟谁不对付），
	最后才是"规矩"（玩家自己定的那几条）。玩家看完就知道该动哪一样。
	"""
	var out := PackedStringArray()
	if m.hunger > 0.6:
		out.append("饿 %.0f%%" % (m.hunger * 100.0))
	if m.fatigue > 0.6:
		out.append("累 %.0f%%" % (m.fatigue * 100.0))
	if m.health < 0.8:
		out.append("带伤 %.0f%%" % (m.health * 100.0))
	var grudge_with := ""
	var best := 0.0
	for other in roster.key_crew():
		if other.id == m.id:
			continue
		var r := relation_between(m.id, other.id)
		if float(r["affinity"]) < best:
			best = float(r["affinity"])
			grudge_with = other.display_name
	if grudge_with != "" and best < -0.05:
		out.append("跟 %s 不对付（%.2f）" % [grudge_with, best])
	if int(m.prio.get("sail", 0)) == 1 and m.job != "sail":
		out.append("想操帆，却被派去干别的")
	var bias := rules.mood_bias()
	if bias < -0.05:
		out.append("规矩压得紧（心情 %+.2f/天）" % bias)
	var gid := group_of(m)
	if float(cohesion.get(gid, 0.5)) < 0.45:
		out.append("%s 这伙人不太齐" % group_name(gid))
	return "、".join(out) if not out.is_empty() else "没什么不满"


func describe() -> String:
	return "紧张度 %.0f%%　纪律 %.0f%%　事件 %d 次" % [
		tension * 100.0, discipline * 100.0, event_count]


# ------------------------------------------------------------ 存档（ShipState，docs/14 第 3 节）

func capture_state() -> Dictionary:
	return {
		"relations": relations.duplicate(true),
		"cohesion": cohesion.duplicate(),
		"tension": tension,
		"discipline": discipline,
		"log_lines": log_lines.duplicate(),
		"event_count": event_count,
		"last_event": last_event,
		"_acc": _acc,
		"_cooldown": _cooldown,
		"_last_severity": _last_severity,
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	relations = (d.get("relations", {}) as Dictionary).duplicate(true)
	cohesion = (d.get("cohesion", {}) as Dictionary).duplicate()
	tension = float(d.get("tension", 0.1))
	discipline = float(d.get("discipline", 0.7))
	log_lines = (d.get("log_lines", []) as Array).duplicate()
	event_count = int(d.get("event_count", 0))
	last_event = str(d.get("last_event", ""))
	_acc = float(d.get("_acc", 0.0))
	_cooldown = float(d.get("_cooldown", 0.0))
	_last_severity = int(d.get("_last_severity", 1))
	pending.clear()
