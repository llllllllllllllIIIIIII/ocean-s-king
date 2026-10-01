class_name VoyageJournal
extends RefCounted

# 航海日志（Day 7）：文书（Escribano）记下的东西 —— 也是**结算页的唯一数据源**。
#
# docs/01 支柱 6 说结尾要有"一页文本结算"，docs/01 第 36 节把"航行日志"列为 ★保留。
# 这两件事是同一件事：结算不是另写一段文案，而是把这本日志摊开给玩家看。
#
# 它只记录，不驱动任何玩法 —— 不碰船、不碰船员，纯粹是账本。
# 所以这里可以放心地自由写：日志错了只是文字不对，不会污染气动模型。

const MAX_ENTRIES := 120

var entries: Array = []          # [{ t, kind, text }]，按时间顺序
var decisions: Array = []        # 玩家做过的决定（一句话一条，去重）
var landfalls: Array = []        # 到过的地标 [{ name, text, t }]
var distance_m := 0.0            # 航程（只累计"正常推进"的位移，瞬移不算）
var teleports := 0               # 被过滤掉的瞬移次数（调试用）
var last_line := ""              # 文书最后写下的一条

# 单帧位移超过这个值就当成瞬移（真速度 7 节 = 3.6 m/s，最大步长 0.5 秒 → 1.8 米）
const TELEPORT_M := 5.0


func record(t: float, kind: String, text: String, tracks_last_line := true) -> void:
	if text.strip_edges() == "":
		return
	entries.append({ "t": t, "kind": kind, "text": text })
	if entries.size() > MAX_ENTRIES:
		entries.pop_front()
	# 单行的话顺手记成"文书最后写下的一条"；多行（报告、剧情正文）不算。
	# 演出用的弹窗（第七幕落下来的那句话）也不算 —— 它压不住剧本写好的收尾。
	if tracks_last_line and not text.contains("\n"):
		last_line = text


func set_last_line(text: String) -> void:
	last_line = text


func decide(text: String) -> void:
	"""玩家做的一个决定。重复的不记（同一件事只写一遍）。"""
	if text.strip_edges() == "" or decisions.has(text):
		return
	decisions.append(text)


func landfall(name: String, text: String, t: float) -> void:
	for lf in landfalls:
		if str(lf["name"]) == name:
			return
	landfalls.append({ "name": name, "text": text, "t": t })


func advance(from_pos: Vector2, to_pos: Vector2) -> void:
	"""航程累计。瞬移（测试与截图脚本会 set_pose）不算航程。"""
	var d := from_pos.distance_to(to_pos)
	if d > TELEPORT_M:
		teleports += 1
		return
	distance_m += d


static func clock(t: float) -> String:
	"""游戏时间 -> "44 分钟" / "1 小时 07 分"。"""
	var minutes := int(t / 60.0)
	if minutes < 60:
		return "%d 分钟" % minutes
	return "%d 小时 %02d 分" % [minutes / 60, minutes % 60]


func distance_km() -> float:
	return distance_m / 1000.0


# ------------------------------------------------------------------ 结算页

func settlement(v: Voyage, story: Story) -> String:
	"""把航海日志拼成一页结算。docs/01 支柱 6 的最终验收就落在这一页上。"""
	var out := PackedStringArray()
	out.append("环球航行 · 航行结算")
	out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	out.append("1519 年 9 月 20 日　航行 %s" % clock(v.t))
	# 抢风记"段"而不是"换舷次数"：目标点固定的情况下，航海官几乎总能挑到最有利的
	# 那一舷一路顶上去，真的翻舷很少发生 —— 写"换舷 0 次"会让玩家以为系统坏了。
	# 换舷次数仍然单独列出来（发生过就显示）。
	out.append("航程 %.1f 公里　　抢风 %d 段　　到过 %d 个地方%s" % [
		distance_km(), v.nav.beat_count, landfalls.size(),
		"　　换舷 %d 次" % v.nav.tack_count if v.nav.tack_count > 0 else ""])

	out.append("")
	out.append("【到过的地方】")
	if landfalls.is_empty():
		out.append("  · 只有海。船没有靠过任何一片岸。")
	else:
		out.append("  · 出发港 —— 出港")
		for lf in landfalls:
			out.append("  · %s —— %s" % [str(lf["name"]), str(lf["text"])])

	out.append("")
	out.append("【你做的决定】")
	if decisions.is_empty():
		out.append("  · 这一天里，你没有做过一个需要负责的决定。")
	else:
		for d in decisions:
			out.append("  · " + str(d))

	out.append("")
	out.append("【船与人】")
	out.append("  · 损伤：%s" % v.ship.describe_damage())
	var ashore := 0
	for m in v.roster.members:
		if m.ashore:
			ashore += 1
	out.append("  · %d 人：%s" % [v.roster.members.size(),
		"船上 %d 人，岸上还有 %d 人" % [v.roster.members.size() - ashore, ashore]
		if ashore > 0 else "全部在船上"])
	out.append("  · 船上最累的人：%s" % _tiredest(v))

	out.append("")
	out.append("【文书最后写下的一条】")
	out.append("  “%s”" % (last_line if last_line != "" else "风平浪静，无事可记。"))
	return "\n".join(out)


func _tiredest(v: Voyage) -> String:
	var worst: CrewMember = null
	for m in v.roster.members:
		if worst == null or m.fatigue > worst.fatigue:
			worst = m
	if worst == null:
		return "——"
	return "%s（累 %.0f%%）" % [worst.label(), worst.fatigue * 100.0]
