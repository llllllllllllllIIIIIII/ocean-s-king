class_name VoyageHud
extends Control

# 航行界面（Day 7 重做）。
#
# Day 6 的 HUD 是一整块 Label：时间、操作、损伤、日志、教学全糊在一起，
# 交接页里写着"两个面板都偏密，Day 7 按'陌生人'标准再砍"。
# 现在分四块，每块只回答一个问题：
#
#   左上【这一幕】 我现在该干什么？教学做到第几步？
#   中上【剧情卡】 刚才发生了什么？（新的一幕落下来时出现几秒）
#   左下【船的状态】 船怎么样？人在干什么？
#   底部【消息条】 刚刚船上报了什么？
#
# 它只画，不改任何状态 —— 整局游戏的可玩性不该藏在 UI 里。

const W := 580.0                  # 左上卡宽度
const BANNER_W := 1010.0
# ⚠️ draw_multiline_string 默认只在**词边界**断行。中文没有空格，整段会被当成一个
#    超长单词，一行直接冲出面板（第一版剧情卡就是这样糊到屏幕外面的）。
#    必须显式加上字素断行标记。
const WRAP := (TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND
	| TextServer.BREAK_GRAPHEME_BOUND | TextServer.BREAK_ADAPTIVE)

var font: Font
var voyage: Voyage
var time_scale := 1.0
var act_card_timer := 0.0         # 剧情卡的剩余播放时间（**真实**秒，不是游戏时间）
var mode_line := ""               # 船舱视图的提示行（由场景填）


func _draw() -> void:
	if font == null or voyage == null:
		return
	_draw_act_card()
	_draw_objective()
	_draw_status()
	_draw_banner()
	_draw_controls()


# ---------------------------------------------------------------- 左上：这一幕

func _draw_objective() -> void:
	var story: Story = voyage.story
	var box := Rect2(16.0, 16.0, W, 62.0 + 22.0 * float(story.visible_steps().size()) + 26.0)
	_panel(box)
	draw_string(font, box.position + Vector2(16, 26), story.act_name(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1.0, 0.87, 0.5))
	draw_string(font, box.position + Vector2(16, 50),
		"目标：" + (story.objective if story.objective != "" else "——"),
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 32.0, 15, Color(0.95, 0.97, 1.0))
	var y := box.position.y + 78.0
	for s in story.visible_steps():
		var done := bool(s["done"])
		var col := Color(0.55, 0.9, 0.62) if done else Color(0.82, 0.87, 0.93)
		draw_string(font, Vector2(box.position.x + 16.0, y),
			"%s %s" % ["√" if done else "○", str(s["text"])],
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 32.0, 14, col)
		y += 22.0
	# 快进：陌生人要能在 15 分钟里走完 8 公里，就必须看得见这个
	var ff := "时间 ×%d　按 . 切换" % int(time_scale)
	var ff_col := Color(1.0, 0.85, 0.45) if time_scale > 1.0 else Color(0.62, 0.7, 0.78)
	draw_string(font, Vector2(box.position.x + 16.0, box.end.y - 10.0), ff,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ff_col)


# ---------------------------------------------------------------- 中上：剧情卡

func _draw_act_card() -> void:
	if act_card_timer <= 0.0:
		return
	var story: Story = voyage.story
	var alpha := clampf(act_card_timer / 1.5, 0.0, 1.0)     # 最后 1.5 秒淡出
	# 摆在左上那张目标卡的右边：两张卡并排，谁也不盖谁
	var box := Rect2(W + 36.0, 16.0, size.x - W - 72.0, 178.0)
	draw_rect(box, Color(0.02, 0.05, 0.08, 0.9 * alpha), true)
	draw_rect(box, Color(0.95, 0.8, 0.35, 0.75 * alpha), false, 2.0)
	draw_string(font, box.position + Vector2(22, 32), story.act_name(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1.0, 0.88, 0.52, alpha))
	draw_multiline_string(font, box.position + Vector2(22, 62), story.act_text(),
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 44.0, 15, -1,
		Color(0.93, 0.96, 1.0, alpha), WRAP)


# ---------------------------------------------------------------- 左下：船的状态

func _draw_status() -> void:
	var v := voyage
	var lines := PackedStringArray()
	lines.append("%s %s　%.1f 节　%s" % [
		v.date_string(), v.clock_string(), v.ship.speed_kn(), v.orders.sail_level_name()])
	lines.append("%s　损伤：%s　操帆 %d 人" % [
		("抛锚中" if v.orders.anchored else v.nav.method_name()),
		v.ship.describe_damage(), v.crew.hands_on_sails])
	lines.append("%s　已探明 %d/%d 块海图" % [
		v.roster.describe(), v.discovered_tiles(), v.total_tiles()])
	lines.append("船队：%s" % v.fleet.describe_short())
	if v.ashore:
		lines.append("☀ 你在岸上，身边 %d 人 —— 左键带队走，走回滩头按 L 上船" % v.party_size())
	elif v.can_land():
		lines.append("★ 就在滩头旁边：按 L 选人登陆（先按 X 抛锚）")
	if mode_line != "":
		lines.append(mode_line)
	var h := 12.0 + 20.0 * float(lines.size())
	var y := size.y - 58.0 - h
	draw_rect(Rect2(16.0, y, W, h), Color(0.02, 0.05, 0.08, 0.72), true)
	var ty := y + 22.0
	for i in lines.size():
		var col := Color(0.9, 0.94, 0.99)
		if i == lines.size() - 1 and (v.ashore or v.can_land() or mode_line != ""):
			col = Color(1.0, 0.88, 0.5)
		draw_string(font, Vector2(28.0, ty), lines[i],
			HORIZONTAL_ALIGNMENT_LEFT, W - 24.0, 14, col)
		ty += 20.0


# ---------------------------------------------------------------- 底部：消息条

func _draw_banner() -> void:
	if voyage.message_timer <= 0.0 or voyage.last_message.strip_edges() == "":
		return
	var alpha := clampf(voyage.message_timer / 2.0, 0.0, 1.0)
	var box := Rect2(16.0, size.y - 224.0, BANNER_W, 62.0)
	draw_rect(box, Color(0.06, 0.09, 0.13, 0.88 * alpha), true)
	draw_rect(box, Color(0.55, 0.78, 1.0, 0.5 * alpha), false, 1.5)
	draw_multiline_string(font, box.position + Vector2(16, 26), voyage.last_message,
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 32.0, 15, 2,
		Color(0.95, 0.97, 1.0, alpha), WRAP)


# ---------------------------------------------------------------- 操作提示

func _draw_controls() -> void:
	draw_string(font, Vector2(16.0, size.y - 20.0),
		"左键 目标点·带队　X 抛锚　1/2/3 帆档　+/− 操帆人数　L 登陆·返船　"
		+ "Tab 帆态　C 船员　. 快进　F5 存档　F9 读档　滚轮 缩放（拉远 = 海图）",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.62, 0.7, 0.78))


func _panel(box: Rect2) -> void:
	draw_rect(box, Color(0.02, 0.05, 0.08, 0.82), true)
	draw_rect(box, Color(0.45, 0.7, 0.9, 0.42), false, 1.5)
