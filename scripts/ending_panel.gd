class_name EndingPanel
extends Control

# 一页文本结算（Day 7，docs/01 第 41~42 节"占位：一页文本结算，1 个通用结局"）。
#
# 内容全部来自 VoyageJournal —— 没有一句是这里现编的。
# 到过哪些地标、做了什么决定、船伤成什么样、船员累成什么样，都是这一趟真的发生过的事。
# 这是"陌生人 15 分钟后能不能复述自己做了什么"的最后一道保险：
# 他说不出来，结算页替他说。

var font: Font
var text := ""

# 中文没有词边界，draw_multiline_string 默认不断行 —— 必须显式给字素断行标记
const WRAP := (TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND
	| TextServer.BREAK_GRAPHEME_BOUND | TextServer.BREAK_ADAPTIVE)


func _draw() -> void:
	if font == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.03, 0.05), true)
	# 纸面高度跟着内容走：一页结算不该下面空一大块（写死高度看着像没画完）
	var h := clampf(104.0 + 21.0 * float(text.split("\n").size()), 320.0, size.y - 150.0)
	var box := Rect2(size.x * 0.5 - 470.0, 62.0, 940.0, h)
	draw_rect(box, Color(0.03, 0.06, 0.09, 0.97), true)
	draw_rect(box, Color(0.85, 0.72, 0.35, 0.75), false, 2.0)
	draw_multiline_string(font, box.position + Vector2(28, 40), text,
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 56.0, 15, -1,
		Color(0.92, 0.95, 0.99), WRAP)
	draw_string(font, Vector2(size.x * 0.5 - 470.0, size.y - 46.0),
		"R 再走一趟　　Esc 关掉这一页，继续看海",
		HORIZONTAL_ALIGNMENT_CENTER, 940.0, 15, Color(1.0, 0.88, 0.55))
