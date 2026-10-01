class_name DilemmaCard
extends Control

# 抉择卡（M5）：缺粮 / 重伤病 / 部落冲突 摊在桌上时的那一屏。
#
# 它只做一件事：把 data/defs/dilemmas.json 里的一个抉择摆出来，等玩家按一个数字。
# 后果全部由 `Dilemma.resolve()` 执行 —— 卡片自己不改任何状态，
# 也不"替玩家决定"（比如按回车默认第一项）：
# **每一个选项都必须被读一遍再选**，这是这一期唯一想表达的玩法。

const PANEL := Vector2(940.0, 520.0)

var font: Font
var voyage: Voyage
var dilemma_id := ""
var hover := 0


func refresh() -> bool:
	"""有要拿主意的事就把卡片摆出来。返回是不是摆上了。"""
	if voyage == null:
		return false
	var id := voyage.dilemmas.current()
	if id == "":
		visible = false
		dilemma_id = ""
		return false
	if id != dilemma_id:
		dilemma_id = id
		hover = 0
	visible = true
	queue_redraw()
	return true


func options() -> Array:
	if voyage == null or dilemma_id == "":
		return []
	return voyage.dilemmas.def_of(dilemma_id).get("options", [])


func _draw() -> void:
	if font == null or voyage == null or dilemma_id == "":
		return
	var box := Rect2((size - PANEL) * 0.5, PANEL)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.55), true)
	draw_rect(box, Color(0.03, 0.06, 0.09, 0.97), true)
	draw_rect(box, Color(1.0, 0.78, 0.35, 0.9), false, 2.0)
	var d := voyage.dilemmas.def_of(dilemma_id)
	draw_string(font, box.position + Vector2(28, 44),
		"要你拿主意：%s" % str(d.get("name", dilemma_id)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1.0, 0.86, 0.5))
	draw_multiline_string(font, box.position + Vector2(28, 82), str(d.get("text", "")),
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 56.0, 16, -1,
		Color(0.92, 0.95, 1.0), VoyageHud.WRAP)
	var y := box.position.y + 190.0
	var opts := options()
	for i in opts.size():
		var o: Dictionary = opts[i]
		var sel := i == hover
		if sel:
			draw_rect(Rect2(box.position.x + 18, y - 20, box.size.x - 36, 44),
				Color(0.18, 0.28, 0.38, 0.85), true)
		var col := Color(1.0, 0.92, 0.66) if sel else Color(0.86, 0.92, 0.98)
		draw_string(font, Vector2(box.position.x + 34.0, y),
			"%d. %s" % [i + 1, str(o.get("name", ""))], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, col)
		draw_string(font, Vector2(box.position.x + 60.0, y + 20.0),
			str(o.get("text", "")), HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 90.0, 13,
			Color(0.72, 0.79, 0.86))
		y += 52.0
	draw_string(font, box.position + Vector2(28, box.size.y - 22),
		"↑↓ 选　回车 / 数字键 决定 —— 每个选项的后果都不一样，选之前先读一遍。",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.62, 0.7, 0.78))


func handle_key(k: InputEventKey) -> bool:
	if not visible:
		return false
	var opts := options()
	if opts.is_empty():
		return false
	match k.keycode:
		KEY_UP, KEY_W:
			hover = posmod(hover - 1, opts.size())
			queue_redraw()
		KEY_DOWN, KEY_S:
			hover = posmod(hover + 1, opts.size())
			queue_redraw()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var idx := k.keycode - KEY_1
			if idx < opts.size():
				_answer(idx)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_answer(hover)
		_:
			return false
	return true


func _answer(idx: int) -> void:
	var opts := options()
	if idx < 0 or idx >= opts.size():
		return
	var id := str((opts[idx] as Dictionary).get("id", ""))
	var r := voyage.answer_dilemma(id)
	if bool(r.get("ok", false)):
		dilemma_id = ""
		visible = false
	refresh()
