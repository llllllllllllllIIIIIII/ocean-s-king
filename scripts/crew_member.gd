class_name CrewMember
extends RefCounted

# 一名船员。
#
#   * **关键船员**（is_key）：有名字、职位、性格、关系、六项技能、一张工作优先级表
#   * **普通船员**：只有岗位（水手/见习/侍童）、一组按编号摊开的技能、一张公用优先级
#
# 静态数据来自 data/defs/crew_12.json；**会变的状态一律只在内存里**
# （心情/疲劳/饥饿/健康/当前工作/位置）—— AGENTS.md 铁律 1。

const JOB_IDS := ["sail", "helm", "lookout", "cook", "repair", "chores"]

var id := ""
var id_hash := 0                # 缓存 id 的哈希（排序与选位要用，别每次现算）
var is_key := false
var display_name := ""
var post := ""
var post_es := ""
var traits: PackedStringArray = []
var relations: Array = []
var skills := {}
var prio := {}                  # job -> 0..3（玩家在船员面板里改的就是它）

# --- 会变的状态（内存里）---
var hunger := 0.20
var fatigue := 0.15
var health := 1.0
var mood := 0.75
# M17：十项属性补两个 —— **信仰**（0..1，虔敬的人更稳、也更认命）与
# **对船长的态度**（−1 恨 .. +1 服）。前者压紧张度，后者决定"会不会抗命/反"。
var faith := 0.5
var captain := 0.0
var job := "idle"               # job id / "eat" / "sleep" / "idle"
var working := false            # 到岗位了吗（没到就不出力）
var at := Vector3i.ZERO         # (x, y, layer)
var path: Array = []
var path_target := Vector3i(-1, -1, -1)
var move_progress := 0.0
var grumble := ""               # 最近一句抱怨（只有关键船员会说）
var grumble_timer := 0.0        # 抱怨冷却（秒），免得一句话刷屏
var ashore := false             # 跟船长上岸了：船上的活一律不管（人在岸上）
var dead := false               # M6：陆战里死了的人**永远回不来**（名册里留着名字）
# --- 派活用的临时字段（每 tick 重算，不落盘）---
var planned := false            # 这一轮方案里已经安排过他了
var next_job := ""
var next_target := Vector3i(-1, -1, -1)


func label() -> String:
	if is_key:
		return "%s %s" % [post, display_name]
	return "%s %s" % [post, display_name]


func skill_for(job_id: String) -> float:
	match job_id:
		"sail":
			return float(skills.get("seamanship", 0.3))
		"repair":
			return float(skills.get("repair", 0.2))
		"helm":
			return float(skills.get("helm", 0.2)) * 0.7 + float(skills.get("seamanship", 0.3)) * 0.3
		"lookout":
			return float(skills.get("seamanship", 0.3)) * 0.5 + float(skills.get("navigation", 0.2)) * 0.5
		"cook":
			return float(skills.get("cooking", 0.2))
		_:
			return float(skills.get("seamanship", 0.3))


func can_work(job_id: String) -> bool:
	return int(prio.get(job_id, 0)) > 0


func is_free() -> bool:
	return job == "" or job == "idle"


func needs_attention() -> String:
	if hunger >= 0.9:
		return "饿坏了"
	if fatigue >= 0.9:
		return "站着都能睡着"
	if health < 0.7:
		return "带着伤"
	return ""


func describe() -> String:
	return "%s　工作 %s%s　饿 %.0f%%　累 %.0f%%　心情 %.0f%%" % [
		label(), _job_name(job), "（在路上）" if (job != "idle" and not working) else "",
		hunger * 100.0, fatigue * 100.0, mood * 100.0]


func _job_name(j: String) -> String:
	match j:
		"sail": return "操帆"
		"helm": return "掌舵"
		"lookout": return "瞭望"
		"cook": return "伙房"
		"repair": return "修补"
		"chores": return "杂务"
		"eat": return "吃饭"
		"sleep": return "睡觉"
		"ashore": return "上岸"
		"off_watch": return "休更"
		_: return "待命"


# ------------------------------------------------------------ 存档（docs/14）
# 存的是**会变的状态**；姓名/职位/技能/性格/关系是静态数据（来自 crew_12.json），不进存档。
# 例外：prio 会被玩家在船员面板里改，所以要存。

func capture_state() -> Dictionary:
	return {
		"id": id,
		# M14：这四样本来是 `crew_12.json` 里的**静态数据**（关键船员的岗位/技能），
		# 但港口招来的人不在那个文件里 —— 不存的话读档之后"招来的人没了岗位和技能"。
		# 存下来对关键船员只是冗余，对招来的人是必需。
		"is_key": is_key, "display_name": display_name,
		"post": post, "post_es": post_es, "skills": skills.duplicate(),
		"faith": faith, "captain": captain,
		"hunger": hunger, "fatigue": fatigue, "health": health, "mood": mood,
		"job": job, "working": working,
		"at": StateIO.v3i(at),
		"path": StateIO.path3(path),
		"path_target": StateIO.v3i(path_target),
		"move_progress": move_progress,
		"grumble": grumble, "grumble_timer": grumble_timer,
		"ashore": ashore, "dead": dead,
		"prio": prio.duplicate(),
		"planned": planned, "next_job": next_job, "next_target": StateIO.v3i(next_target),
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	is_key = bool(d.get("is_key", is_key))
	display_name = str(d.get("display_name", display_name))
	post = str(d.get("post", post))
	post_es = str(d.get("post_es", post_es))
	if d.has("skills"):
		skills = (d.get("skills", {}) as Dictionary).duplicate()
	faith = clampf(float(d.get("faith", faith)), 0.0, 1.0)
	captain = clampf(float(d.get("captain", captain)), -1.0, 1.0)
	hunger = float(d.get("hunger", 0.2))
	fatigue = float(d.get("fatigue", 0.15))
	health = float(d.get("health", 1.0))
	mood = float(d.get("mood", 0.75))
	job = str(d.get("job", "idle"))
	working = bool(d.get("working", false))
	at = StateIO.to_v3i(d.get("at", [0, 0, 0]))
	path = StateIO.to_path3(d.get("path", []))
	path_target = StateIO.to_v3i(d.get("path_target", [-1, -1, -1]))
	move_progress = float(d.get("move_progress", 0.0))
	grumble = str(d.get("grumble", ""))
	grumble_timer = float(d.get("grumble_timer", 0.0))
	ashore = bool(d.get("ashore", false))
	dead = bool(d.get("dead", false))
	prio = (d.get("prio", {}) as Dictionary).duplicate()
	planned = bool(d.get("planned", false))
	next_job = str(d.get("next_job", ""))
	next_target = StateIO.to_v3i(d.get("next_target", [-1, -1, -1]))
