class_name TitleCard
extends Control

# 开场标题卡（Day 7）。docs/01 支柱 6 的最终验收是"陌生人 15 分钟玩完、事后能复述
# 自己做了什么决定"，而陌生人在第一分钟里必须知道三件事：
#   我是谁（1519 年的一艘拉丁帆船）／我在哪儿（圣卢卡尔港）／我要干什么（往东找到岛）
#
# 还有第四条：**怎么动**。玩家不能直接操船，这是本作最容易误解的一点，
# 所以开场就把那句话写在脸上。游戏在这一页上不跑任何模拟。

var font: Font
var title := ""
var subtitle := ""
var heading := ""
var body := ""
var hint := ""
var age := 0.0

# 中文没有词边界，draw_multiline_string 默认不会断行 —— 必须显式给字素断行标记
const WRAP := (TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND
	| TextServer.BREAK_GRAPHEME_BOUND | TextServer.BREAK_ADAPTIVE)


func _draw() -> void:
	if font == null:
		return
	# 全不透明：半透明的底会把海面矩形透出来（第一版截图里有一条莫名其妙的浅色带）
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.016, 0.035, 0.055), true)

	# 顶上的细线，把"港口的水平线"这个感觉压住
	var cx := size.x * 0.5
	draw_line(Vector2(cx - 300.0, 150.0), Vector2(cx + 300.0, 150.0),
		Color(0.55, 0.75, 0.95, 0.35), 1.0)

	draw_string(font, Vector2(cx - 450.0, 300.0), title,
		HORIZONTAL_ALIGNMENT_CENTER, 900.0, 62, Color(0.96, 0.98, 1.0))
	draw_string(font, Vector2(cx - 450.0, 336.0), subtitle,
		HORIZONTAL_ALIGNMENT_CENTER, 900.0, 16, Color(0.62, 0.78, 0.95))
	draw_string(font, Vector2(cx - 450.0, 396.0), heading,
		HORIZONTAL_ALIGNMENT_CENTER, 900.0, 15, Color(0.95, 0.83, 0.5))
	draw_multiline_string(font, Vector2(cx - 450.0, 434.0), body,
		HORIZONTAL_ALIGNMENT_CENTER, 900.0, 16, -1, Color(0.88, 0.92, 0.97), WRAP)

	# 提示一直在闪：不闪的话陌生人会以为卡住了
	var blink := 0.55 + 0.45 * sin(age * 2.4)
	draw_string(font, Vector2(cx - 450.0, size.y - 120.0), hint,
		HORIZONTAL_ALIGNMENT_CENTER, 900.0, 18, Color(1.0, 0.9, 0.55, blink))
	draw_string(font, Vector2(cx - 450.0, size.y - 78.0),
		"左键 点目标点　　Tab 帆态面板　　X 抛锚　　L 登陆　　C 船员　　. 快进　　滚轮 缩放",
		HORIZONTAL_ALIGNMENT_CENTER, 900.0, 14, Color(0.66, 0.76, 0.86))


func _process(delta: float) -> void:
	age += delta
	queue_redraw()
