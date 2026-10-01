class_name CrewPanel
extends Control

# 船员面板（C 呼出）：12 名关键船员的名单、状态，和**可以直接改的工作优先级表**。
#
# 上半是名册：谁在干什么、饿不饿、累不累、心情如何；
# 下半是优先级表：行 = 12 名关键船员，列 = 6 种工作，格子里的数字就是优先级。
# 改优先级 → 下一轮派活（2 秒内）行为就变 —— 这是 Day 5 的第 3 条验收。

const PANEL := Vector2(900.0, 470.0)
const ROW_H := 21.0
const JOB_ORDER := ["sail", "helm", "lookout", "cook", "repair", "chores"]
const JOB_SHORT := ["操帆", "掌舵", "瞭望", "伙房", "修补", "杂务"]
const PRIO_HINT := ["不干", "优先", "一般", "有空"]

var font: Font
var roster: CrewRoster
var selected_row := 0
var selected_col := 0


func update_from(p_roster: CrewRoster) -> void:
	roster = p_roster
	if roster and selected_row >= roster.key_crew().size():
		selected_row = maxi(0, roster.key_crew().size() - 1)
	queue_redraw()


func move_selection(drow: int, dcol: int) -> void:
	if roster == null:
		return
	selected_row = clampi(selected_row + drow, 0, roster.key_crew().size() - 1)
	selected_col = clampi(selected_col + dcol, 0, JOB_ORDER.size() - 1)
	queue_redraw()


func cycle_priority() -> String:
	"""把选中格子的优先级转一圈：0 → 1 → 2 → 3 → 0。"""
	if roster == null:
		return ""
	var m: CrewMember = roster.key_crew()[selected_row]
	var job: String = JOB_ORDER[selected_col]
	var now := int(m.prio.get(job, 0))
	var nxt := (now + 1) % 4
	m.prio[job] = nxt
	queue_redraw()
	return "%s 的%s -> %s" % [m.label(), job, PRIO_HINT[nxt]]


func _draw() -> void:
	if roster == null or font == null:
		return
	draw_rect(Rect2(Vector2.ZERO, PANEL), Color(0.03, 0.06, 0.09, 0.94), true)
	draw_rect(Rect2(Vector2.ZERO, PANEL), Color(0.45, 0.7, 0.9, 0.5), false, 2.0)
	draw_string(font, Vector2(14, 24), "船员（C 关闭　↑↓ 选人　←→ 选工作　空格 改优先级）",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.85, 0.93, 1.0))

	var crew := roster.key_crew()
	var y := 44.0
	# 表头
	var col_x := 430.0
	for j in JOB_ORDER.size():
		draw_string(font, Vector2(col_x + float(j) * 62.0, y), JOB_SHORT[j],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.8, 0.95))
	y += 4.0
	for i in crew.size():
		var m: CrewMember = crew[i]
		y += ROW_H
		var row_col := Color(0.86, 0.92, 0.98)
		if i == selected_row:
			draw_rect(Rect2(10.0, y - 15.0, PANEL.x - 20.0, ROW_H),
				Color(0.25, 0.45, 0.65, 0.30), true)
			row_col = Color(1.0, 0.98, 0.85)
		# 名册
		draw_string(font, Vector2(18, y), "%-14s %-6s %s" % [
			m.label(), m._job_name(m.job),
			"到位" if m.working else ("在路上" if m.job != "idle" else "")],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, row_col)
		# 需求条
		var bx := 268.0
		_draw_bar(Vector2(bx, y - 10.0), m.fatigue, Color(0.95, 0.7, 0.35), "累")
		_draw_bar(Vector2(bx + 54.0, y - 10.0), m.hunger, Color(0.85, 0.5, 0.4), "饿")
		_draw_bar(Vector2(bx + 108.0, y - 10.0), 1.0 - m.mood, Color(0.7, 0.6, 0.95), "烦")
		# 优先级表
		for j in JOB_ORDER.size():
			var p := int(m.prio.get(JOB_ORDER[j], 0))
			var cell := Rect2(col_x + float(j) * 62.0 - 4.0, y - 15.0, 24.0, 18.0)
			if i == selected_row and j == selected_col:
				draw_rect(cell, Color(0.95, 0.8, 0.35, 0.85), true)
			var txt := "—" if p == 0 else str(p)
			var c := Color(0.45, 0.5, 0.55) if p == 0 else Color(0.85, 0.95, 1.0)
			if i == selected_row and j == selected_col:
				c = Color(0.05, 0.08, 0.1)
			draw_string(font, Vector2(cell.position.x + 2.0, y), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, c)

	# 底部：普通船员 + 船上日志
	var fy := y + 26.0
	draw_string(font, Vector2(18, fy), roster.describe(),
		HORIZONTAL_ALIGNMENT_LEFT, PANEL.x - 36.0, 13, Color(0.75, 0.85, 0.95))
	fy += 20.0
	draw_string(font, Vector2(18, fy), "船上动静：",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.8, 0.95))
	fy += 17.0
	for line in roster.log_lines.slice(maxi(0, roster.log_lines.size() - 3)):
		draw_string(font, Vector2(28, fy), str(line),
			HORIZONTAL_ALIGNMENT_LEFT, PANEL.x - 46.0, 13, Color(0.88, 0.9, 0.86))
		fy += 17.0


func _draw_bar(at: Vector2, value: float, color: Color, tag: String) -> void:
	draw_rect(Rect2(at, Vector2(44.0, 8.0)), Color(1, 1, 1, 0.12), true)
	draw_rect(Rect2(at, Vector2(44.0 * clampf(value, 0.0, 1.0), 8.0)), color, true)
	draw_string(font, Vector2(at.x - 14.0, at.y + 8.0), tag,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.8, 0.85))
