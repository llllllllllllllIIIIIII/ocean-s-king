class_name KnowledgePanel
extends Control

# 知识与日志页（M7，按 K）：把这一路"发现即记录"的东西摊开。
#
# 它只读 `Voyage.knowledge` 与 `Voyage.memory` —— 不改任何状态。

const PANEL := Vector2(760.0, 560.0)

var font: Font
var voyage: Voyage
var scroll := 0


func _draw() -> void:
	if font == null or voyage == null:
		return
	var box := Rect2((size - PANEL) * 0.5, PANEL)
	draw_rect(box, Color(0.02, 0.05, 0.08, 0.94), true)
	draw_rect(box, Color(0.95, 0.8, 0.35, 0.7), false, 2.0)
	var k := voyage.knowledge
	_text(box.position + Vector2(24, 38), "知识与日志", 22, Color(1.0, 0.88, 0.52))
	_text(box.position + Vector2(24, 64), k.describe(), 14, Color(0.8, 0.87, 0.94))
	var y := box.position.y + 96.0
	var lines := k.lines(40)
	for i in range(scroll, lines.size()):
		if y > box.position.y + box.size.y - 90.0:
			break
		var line := str(lines[i])
		var col := Color(0.86, 0.92, 0.98)
		if line.begins_with("【"):
			col = Color(1.0, 0.86, 0.5)
		_text(Vector2(box.position.x + 26, y), line, 14, col)
		y += 18.0
	# 底下两行：世界记住了什么 + 天气
	var memory := PackedStringArray()
	for key in voyage.memory.keys():
		memory.append("%s %d" % [str(key), int(voyage.memory[key])])
	_text(box.position + Vector2(24, box.size.y - 54),
		"世界记住的：%s" % ("、".join(memory) if memory.size() > 0 else "还什么都没记"),
		14, Color(0.9, 0.85, 0.7))
	_text(box.position + Vector2(24, box.size.y - 30),
		"现在的天气：%s　↑↓ 翻页　K 关闭" % voyage.weather.describe(),
		14, Color(0.75, 0.85, 0.95))


func handle_key(k: InputEventKey) -> bool:
	if not visible:
		return false
	match k.keycode:
		KEY_UP, KEY_W:
			scroll = maxi(0, scroll - 5)
		KEY_DOWN, KEY_S:
			scroll = mini(maxi(0, voyage.knowledge.lines(40).size() - 20), scroll + 5)
		KEY_ESCAPE, KEY_K:
			visible = false
		_:
			return false
	queue_redraw()
	return true


func _text(at: Vector2, s: String, px: int, col: Color) -> void:
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, col)
