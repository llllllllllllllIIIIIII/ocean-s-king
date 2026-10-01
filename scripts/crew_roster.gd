class_name CrewRoster
extends RefCounted

# 船上的人：12 名关键船员 + 28 名普通船员。
#
# 它干四件事：
#   1. 每帧推进每个人的需求（饿、累）
#   2. 按**工作优先级**把活派下去（类环世界：优先级 1 的先挑，同级看技能）
#   3. 让每个人走到自己的岗位上（船内寻路，走梯子/舱口）
#   4. 把"现在有几个人真的在操帆、他们手艺如何、累不累"算出来交给操船
#
# 第 4 条是这套系统的**全部意义**：船员好不好 = 船灵不灵。

const DATA_PATH := "res://data/defs/crew_12.json"
const WALK_SPEED := 1.6          # 格/秒（1 格 = 1 米）
const CLIMB_SPEED := 0.6         # 上下梯子慢得多
const JOB_ORDER := ["helm", "sail", "lookout", "cook", "repair", "chores"]
const LOG_MAX := 6
const ASSIGN_PERIOD := 2.0       # 秒：多久重排一次活（水手长不是每帧都在喊人）

var members: Array = []          # 40 人：前 12 个是关键船员
var jobs := {}
var needs := {}
var path := ShipPath.new()
var log_lines: Array = []        # 最近几条"船上发生了什么"
var t := 0.0
var ready := false

var _grumble_pool := [
	"这帆脚索又缠住了。",
	"风又转了，白调一趟。",
	"腰快断了。",
	"淡水一股桶味。",
	"谁又把我的工具拿走了？",
	"想睡个整觉。",
	"手上全是泡。",
	"这船到处在渗水。",
]
var _grumble_cursor := 0
var _assign_timer := 1e9


func setup() -> void:
	path.setup()
	var d = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("船员名册读不出来：" + DATA_PATH)
		return
	jobs = d.get("jobs", {})
	needs = d.get("needs", {})

	for raw in d.get("key_crew", []):
		var m := CrewMember.new()
		m.id = str(raw["id"])
		m.id_hash = absi(m.id.hash())
		m.is_key = true
		m.display_name = str(raw["name"])
		m.post = str(raw["post"])
		m.post_es = str(raw.get("post_es", ""))
		m.skills = raw.get("skills", {})
		m.prio = (raw.get("prio", {}) as Dictionary).duplicate()
		m.relations = raw.get("relations", [])
		for tr in raw.get("traits", []):
			m.traits.append(str(tr))
		members.append(m)

	# 28 名普通船员：技能按编号摊开（不用随机数，保证可复现）
	var hands: Dictionary = d.get("hands", {})
	var count := int(hands.get("count", 28))
	var center := float(hands.get("skill_center", 0.45))
	var spread := float(hands.get("skill_spread", 0.15))
	var hand_prio: Dictionary = hands.get("prio", {})
	for i in count:
		var m := CrewMember.new()
		m.id = "hand_%02d" % (i + 1)
		m.id_hash = absi(m.id.hash())
		m.is_key = false
		m.post = "水手" if i < 16 else ("见习" if i < 24 else "侍童")
		m.display_name = "#%02d" % (i + 1)
		var wobble := (float(i % 7) / 6.0 - 0.5) * 2.0      # −1..1
		var s := clampf(center + wobble * spread, 0.15, 0.85)
		m.skills = {
			"seamanship": s,
			"navigation": maxf(0.05, s - 0.25),
			"helm": maxf(0.05, s - 0.15),
			"cooking": maxf(0.05, s - 0.30),
			"medicine": 0.05,
			"repair": maxf(0.05, s - 0.20),
		}
		m.prio = hand_prio.duplicate()
		members.append(m)

	_place_members()
	log_event("船员上船：12 名关键船员 + %d 名水手。" % count)
	ready = true


func _place_members() -> void:
	"""开局站定：关键船员在舱内，水手在甲板上。"""
	var interior := path.reachable_cells(1)
	var deck := path.reachable_cells(2)
	var i_in := 0
	var i_deck := 0
	for m in members:
		if m.is_key and interior.size() > 0:
			m.at = interior[i_in % interior.size()]
			i_in += 3                 # 错开，别挤在同一格
		elif deck.size() > 0:
			m.at = deck[i_deck % deck.size()]
			i_deck += 5
		m.path = [m.at]


func tick(delta: float, sail_demand: int) -> void:
	if not ready:
		return
	t += delta
	_update_needs(delta)
	_assign_timer += delta
	if _assign_timer >= ASSIGN_PERIOD:
		_assign_timer = 0.0
		_assign_jobs(sail_demand)
	_move(delta)
	_update_mood(delta)


# ------------------------------------------------------------ 需求

func _update_needs(delta: float) -> void:
	var hunger_rate := float(needs.get("hunger_rate", 0.0000075))
	var fatigue_rate := float(needs.get("fatigue_rate", 0.0000125))
	var sleep_recover := float(needs.get("sleep_recover", 0.00030))
	var eat_recover := float(needs.get("eat_recover", 0.00220))
	for m in members:
		m.hunger = clampf(m.hunger + hunger_rate * delta, 0.0, 1.0)
		m.fatigue = clampf(m.fatigue + fatigue_rate * delta, 0.0, 1.0)
		if m.job == "sleep" and m.working:
			m.fatigue = clampf(m.fatigue - sleep_recover * delta, 0.0, 1.0)
		elif m.job == "off_watch" and m.working:
			# 不在班的人在舱里歇着，回一点疲劳（比睡觉慢）
			m.fatigue = clampf(m.fatigue - sleep_recover * 0.35 * delta, 0.0, 1.0)
		elif m.job == "eat" and m.working:
			m.hunger = clampf(m.hunger - eat_recover * delta, 0.0, 1.0)
		m.health = clampf(m.health, 0.0, 1.0)


# ------------------------------------------------------------ 派活

func _assign_jobs(sail_demand: int) -> void:
	# 先算一张"应该怎么派"的方案，再和现状对比、只应用**变化**。
	# 不能每帧清空重派：那样每 0.5 秒就把所有人的路线清零，谁也走不到岗位上。
	var demand := {
		"helm": 1, "sail": clampi(sail_demand, 0, 12), "lookout": 1,
		"cook": 1, "repair": 1, "chores": 2,
	}
	var hunger_to_eat := float(needs.get("hunger_to_eat", 0.70))
	var fatigue_to_sleep := float(needs.get("fatigue_to_sleep", 0.78))
	for m in members:
		m.planned = false
		m.next_job = "off_watch"
		m.next_target = Vector3i(-1, -1, -1)
	# 0) 上岸的人不参与船上的派活 —— 带走的每一个人都意味着船上少一双手
	for m in members:
		if m.ashore:
			m.next_job = "ashore"
			m.planned = true
	# 1) 需求优先：饿/累到阈值就放下手里的活
	for m in members:
		if m.ashore:
			continue
		if m.hunger >= hunger_to_eat:
			m.next_job = "eat"
			m.next_target = _need_slot(m, "eat")
			m.planned = true
		elif m.fatigue >= fatigue_to_sleep:
			m.next_job = "sleep"
			m.next_target = _need_slot(m, "sleep")
			m.planned = true
	# 2) 干活：按工作类型依次挑人（优先级高的先挑，同级看技能，再看谁没那么累）
	for j in JOB_ORDER:
		# 先把"名次"算一次再排序 —— 别在比较函数里反复算技能和哈希
		var pairs := []
		for m in members:
			if not m.planned and not m.ashore and m.can_work(j):
				pairs.append([_rank(m, j), m])
		pairs.sort_custom(func(a, b): return a[0] < b[0])
		var want: int = min(int(demand.get(j, 0)), pairs.size())
		var slots: Array = path.station_cells(j)
		for i in want:
			var m: CrewMember = pairs[i][1]
			m.next_job = j
			m.next_target = Vector3i(-1, -1, -1)
			if slots.size() > 0:
				m.next_target = slots[i % slots.size()]
			m.planned = true
	# 3) 剩下的不在班：回水手舱待着（真船就是这么排更的）
	for m in members:
		if not m.planned and not m.ashore:
			m.next_job = "off_watch"
			m.next_target = _need_slot(m, "off_watch")
	# 4) 只应用变化（路线不清零，人才走得到岗位）
	for m in members:
		if m.job == m.next_job and m.path_target == m.next_target:
			continue
		m.job = m.next_job
		m.path_target = m.next_target
		m.path = []
		m.move_progress = 0.0
		m.working = false


func _need_slot(m: CrewMember, job_id: String) -> Vector3i:
	var slots: Array = path.station_cells(job_id)
	if slots.is_empty():
		return Vector3i(-1, -1, -1)
	# 按 id 摊开，免得所有人挤同一张铺
	return slots[m.id_hash % slots.size()]


func _rank(m: CrewMember, job_id: String) -> float:
	# 先比优先级（越小越优先），再比技能（越大越好），最后比疲劳（越小越先上）
	# 最后用 id 做稳定的并列打破，保证同一批人每次排出来的顺序都一样
	return float(int(m.prio.get(job_id, 0))) * 100.0 - m.skill_for(job_id) * 10.0 + m.fatigue \
		+ float(m.id_hash % 1000) * 0.0001


# ------------------------------------------------------------ 走路

func _move(delta: float) -> void:
	for m in members:
		if m.job == "idle" or m.path_target.x < 0:
			m.working = m.job != "idle"
			continue
		if m.at == m.path_target:
			m.working = true
			continue
		if m.path.is_empty() or m.path[0] != m.at:
			var p := path.find(m.at, m.path_target)
			if p.is_empty():
				m.working = false          # 走不到就站着（不该发生，测试会抓）
				continue
			m.path = p
		m.working = false
		if m.path.size() > 1:
			var next: Vector3i = m.path[1]
			var speed := CLIMB_SPEED if next.z != m.at.z else WALK_SPEED
			m.move_progress += speed * delta
			while m.move_progress >= 1.0 and m.path.size() > 1:
				m.move_progress -= 1.0
				m.path.remove_at(0)
				m.at = m.path[0]
			if m.at == m.path_target:
				m.working = true


# ------------------------------------------------------------ 心情与抱怨

func _update_mood(delta: float) -> void:
	for m in members:
		var target := clampf(0.85 - 0.45 * m.fatigue - 0.45 * m.hunger
			- (1.0 - m.health) * 0.5, 0.0, 1.0)
		m.mood += clampf(target - m.mood, -0.25 * delta, 0.25 * delta)
		m.grumble_timer -= delta
		# 只有关键船员会抱怨 —— 这是 12 人 vs 28 人最直接的表现差异。
		# 冷却按 id 摊开，不用随机数（测试要可复现）。
		if not m.is_key or m.mood > 0.5 or m.grumble_timer > 0.0:
			continue
		m.grumble_timer = 45.0 + float(m.id_hash % 40)
		_say(m)


func _say(m: CrewMember) -> void:
	var line: String = _grumble_pool[_grumble_cursor % _grumble_pool.size()]
	_grumble_cursor += 1
	var note := m.needs_attention()
	if note != "":
		line = "%s（%s）" % [line, note]
	m.grumble = line
	log_event("%s：%s" % [m.label(), line])


func log_event(text: String) -> void:
	"""往船上日志里写一条（面板会显示最近三条）。"""
	log_lines.append(text)
	if log_lines.size() > LOG_MAX:
		log_lines.pop_front()


# ------------------------------------------------------------ 给操船看的量

func sail_hands() -> int:
	var n := 0
	for m in members:
		if m.job == "sail" and m.working:
			n += 1
	return n


func sail_skill() -> float:
	var sum := 0.0
	var n := 0
	for m in members:
		if m.job == "sail" and m.working:
			sum += m.skill_for("sail")
			n += 1
	return sum / float(n) if n > 0 else 0.0


func sail_fatigue() -> float:
	var sum := 0.0
	var n := 0
	for m in members:
		if m.job == "sail" and m.working:
			sum += m.fatigue
			n += 1
	return sum / float(n) if n > 0 else 0.0


func key_crew() -> Array:
	return members.slice(0, 12)


func hands() -> Array:
	return members.slice(12)


func job_counts() -> Dictionary:
	var out := {}
	for m in members:
		var k: String = m.job if m.job != "" else "idle"
		out[k] = int(out.get(k, 0)) + 1
	return out


func describe() -> String:
	var c := job_counts()
	var parts := PackedStringArray()
	var names := {
		"sail": "操帆", "helm": "掌舵", "lookout": "瞭望", "cook": "伙房",
		"repair": "修补", "chores": "杂务", "eat": "吃饭", "sleep": "睡觉",
		"off_watch": "休更", "idle": "待命",
	}
	for k in ["sail", "helm", "lookout", "cook", "repair", "chores",
			"eat", "sleep", "off_watch", "idle"]:
		if c.has(k):
			parts.append("%s %d" % [names.get(k, k), int(c[k])])
	return "全船 %d 人：%s" % [members.size(), " ".join(parts)]


# ------------------------------------------------------------ 存档（docs/14）
# 名册按 id 回填：静态数据（姓名/技能/性格/关系）在 setup() 时从 crew_12.json 建好，
# 存档只覆盖"会变的状态"。成员按 id 找回来，不依赖数组下标。
# _grumble_pool（抱怨语料）是静态表，不进存档。

func capture_state() -> Dictionary:
	var people := []
	for m in members:
		people.append(m.capture_state())
	return {
		"t": t,
		"_assign_timer": _assign_timer,
		"_grumble_cursor": _grumble_cursor,
		"log_lines": log_lines.duplicate(),
		"members": people,
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	t = float(d.get("t", 0.0))
	_assign_timer = float(d.get("_assign_timer", 1e9))
	_grumble_cursor = int(d.get("_grumble_cursor", 0))
	log_lines = (d.get("log_lines", []) as Array).duplicate()
	var by_id := {}
	for m in members:
		by_id[m.id] = m
	var raw_list: Array = d.get("members", [])
	for raw in raw_list:
		var cid := str(raw.get("id", ""))
		if by_id.has(cid):
			by_id[cid].apply_state(raw)
