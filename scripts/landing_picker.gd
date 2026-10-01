class_name LandingPicker
extends Control

# 登陆名单（L 打开）。它必须画在**屏幕坐标**里 ——
# 第一版画在世界坐标里，结果面板跟着相机跑，玩家找了半天才看见（现场反馈）。
# 用的是和其它面板一样的做法：挂在 CanvasLayer 上的 Control，居中显示。

const PANEL := Vector2(460.0, 470.0)
const ROW_H := 26.0

var font: Font
var roster: CrewRoster
var index := 0
var picked := {}
var hands := 6


func open(p_roster: CrewRoster) -> void:
	roster = p_roster
	index = 0
	picked.clear()
	queue_redraw()


func move(delta: int) -> void:
	if roster == null:
		return
	index = clampi(index + delta, 0, roster.key_crew().size() - 1)
	queue_redraw()


func toggle_current() -> void:
	if roster == null:
		return
	var m: CrewMember = roster.key_crew()[index]
	if picked.has(m.id):
		picked.erase(m.id)
	else:
		picked[m.id] = true
	queue_redraw()


func selected_ids() -> Array:
	return picked.keys()


func _draw() -> void:
	if roster == null or font == null:
		return
	draw_rect(Rect2(Vector2.ZERO, PANEL), Color(0.03, 0.06, 0.09, 0.96), true)
	draw_rect(Rect2(Vector2.ZERO, PANEL), Color(0.95, 0.8, 0.35, 0.85), false, 2.0)
	draw_string(font, Vector2(16, 28), "带谁上岸？", HORIZONTAL_ALIGNMENT_LEFT, -1, 19,
		Color(1.0, 0.95, 0.8))
	draw_string(font, Vector2(16, 50), "↑↓ 选人　空格 勾选　回车 确认　Esc 取消",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.75, 0.85, 0.95))
	draw_string(font, Vector2(16, 70), "另外还会带 %d 名水手一起上岸" % hands,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.8, 0.9))
	var crew := roster.key_crew()
	var y := 96.0
	for i in crew.size():
		var m: CrewMember = crew[i]
		if i == index:
			draw_rect(Rect2(10.0, y - 18.0, PANEL.x - 20.0, ROW_H), Color(0.85, 0.7, 0.3, 0.28), true)
		var mark := "[×]" if picked.has(m.id) else "[  ]"
		var col := Color(1.0, 0.98, 0.85) if i == index else Color(0.85, 0.9, 0.95)
		draw_string(font, Vector2(22, y), "%s %-14s %s　手艺 %d%%" % [
			mark, m.label(), m._job_name(m.job), int(m.skill_for("sail") * 100.0)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		y += ROW_H
	# 合计提示
	draw_string(font, Vector2(16, y + 18), "已选 %d 名关键船员 + %d 名水手" % [picked.size(), hands],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.95, 0.9, 0.7))
