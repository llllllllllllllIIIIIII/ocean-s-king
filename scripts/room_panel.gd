class_name RoomPanel
extends Control

# 房间界面（M3）：开房间 / 加入 / 单机，以及四个船位各由谁占着。
#
# 设计取向（和 v0.1 的开场卡一致）：**先让陌生人知道自己在哪儿、要选什么**，
# 所以它是一个一屏能读完的卡，不是一套多级菜单。真正的多人选项只有三条路径：
#
#   ① 单机出海 —— 一个人 + 三条 AI（和联机**同一条代码路径**）
#   ② 开房间   —— 本机当房主，别人用 IP 连进来（v0.5 最多 4 个人）
#   ③ 加入房间 —— 输 IP（改了砍单预案：不做 UDP 自动发现，只留手输 IP）
#
# 它只画、只发信号，不自己开网络 —— 网络是 NetSession 的事，接线是场景的事。

signal choose(mode: String, ip: String)

const MODE_SOLO := "solo"
const MODE_HOST := "host"
const MODE_JOIN := "join"

var font: Font
var session: NetSession
var voyage: Voyage
var line := ""                    # 输入中的 IP
var editing := false
var hint := ""                    # 出错时的一句话（连接失败、船位满了…）


func _ready() -> void:
	line = "127.0.0.1"


func open() -> void:
	visible = true
	editing = false
	hint = ""
	queue_redraw()


func _draw() -> void:
	if font == null:
		return
	var w := minf(size.x - 80.0, 860.0)
	var box := Rect2(Vector2((size.x - w) * 0.5, 76.0), Vector2(w, 500.0))
	draw_rect(box, Color(0.02, 0.05, 0.08, 0.94), true)
	draw_rect(box, Color(0.95, 0.8, 0.35, 0.75), false, 2.0)
	_text(box.position + Vector2(28, 44), "环球航行 · 船队", 24, Color(1.0, 0.88, 0.52))
	_text(box.position + Vector2(28, 78),
		"1519 年 9 月 20 日 · 圣卢卡尔港 · 四艘船等着一支船队",
		15, Color(0.78, 0.85, 0.92))

	var y := box.position.y + 130.0
	_option(box, y, "1", "单机出海", "一个人开一条船，另外三条交给 AI（和联机走同一条代码路径）", true)
	y += 62.0
	_option(box, y, "2", "开房间（当房主）", "别人用你的 IP 连进来；没人开的船由 AI 接手", true)
	y += 62.0
	_option(box, y, "3", "加入别人的房间", "填 IP → 回车。中途加入也行，会接手一条 AI 船", true)
	y += 46.0
	var ip_box := Rect2(box.position.x + 28.0, y, 320.0, 34.0)
	draw_rect(ip_box, Color(0.06, 0.1, 0.14, 0.95), true)
	draw_rect(ip_box, Color(0.55, 0.78, 1.0, 0.6 if editing else 0.25), false,
		2.0 if editing else 1.0)
	_text(ip_box.position + Vector2(12, 23), "IP：" + line + ("_" if editing else ""),
		16, Color(0.95, 0.97, 1.0))
	_text(ip_box.position + Vector2(340, 23), "（按 I 编辑，回车连接；v0.5 是局域网手输 IP）",
		13, Color(0.6, 0.68, 0.76))

	_draw_slots(box, box.position.y + 372.0)
	if hint != "":
		_text(box.position + Vector2(28, box.size.y - 16), hint, 14, Color(1.0, 0.72, 0.55))


func _option(box: Rect2, y: float, key: String, title: String, sub: String, on: bool) -> void:
	var col := Color(1.0, 0.9, 0.6) if on else Color(0.5, 0.55, 0.6)
	draw_rect(Rect2(box.position.x + 22.0, y - 26.0, 34.0, 30.0),
		Color(0.1, 0.16, 0.22, 0.9), true)
	_text(Vector2(box.position.x + 34.0, y - 4.0), key, 18, col)
	_text(Vector2(box.position.x + 72.0, y - 4.0), title, 18, col)
	_text(Vector2(box.position.x + 72.0, y + 18.0), sub, 13, Color(0.7, 0.76, 0.83))


func _draw_slots(box: Rect2, y: float) -> void:
	_text(Vector2(box.position.x + 28.0, y), "四个船位", 15, Color(0.78, 0.85, 0.92))
	var i := 0
	if voyage != null and voyage.fleet != null:
		for s in voyage.fleet.slots:
			var x := box.position.x + 28.0 + float(i % 2) * 380.0
			var yy := y + 28.0 + float(i / 2) * 34.0
			var kind := str(s["kind"])
			var who := "（空着 · AI）"
			var col := Color(0.62, 0.68, 0.75)
			if kind == Fleet.KIND_LOCAL:
				who = "★ 我"
				col = Color(1.0, 0.88, 0.52)
			elif kind == Fleet.KIND_REMOTE:
				who = str(s.get("owner_name", "别人"))
				col = Color(0.6, 0.9, 1.0)
			_text(Vector2(x, yy), "%s　%s" % [str(s["name"]), who], 15, col)
			i += 1


func _text(at: Vector2, s: String, px: int, col: Color) -> void:
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, col)


# ------------------------------------------------------------ 输入

func handle_key(k: InputEventKey) -> bool:
	"""返回 true = 这个键被房间界面吃掉了（别再传给航行界面）。"""
	if not visible:
		return false
	match k.keycode:
		KEY_1:
			emit_signal("choose", MODE_SOLO, line)
		KEY_2:
			emit_signal("choose", MODE_HOST, line)
		KEY_3, KEY_ENTER, KEY_KP_ENTER:
			emit_signal("choose", MODE_JOIN, line)
		KEY_I:
			editing = true
		KEY_ESCAPE:
			editing = false
			visible = false
		KEY_BACKSPACE:
			if editing:
				line = line.substr(0, maxi(0, line.length() - 1))
			else:
				return false
		_:
			if editing:
				var ch := char(k.unicode)
				if ch != "" and (ch.is_valid_int() or ch == "." or ch == ":"):
					line += ch
			else:
				return false
	queue_redraw()
	return true
