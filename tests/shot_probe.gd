# 验证无头模式能否截到画面。
#
# 如果 headless 下拿不到图像（dummy 渲染），就改走"窗口模式 + 自动截图"。
# 用法：
#   ... --headless --path . --script res://tests/shot_probe.gd
#   ...          --path . --script res://tests/shot_probe.gd
extends SceneTree

var _frame := 0
var _out := "res://tests/_shot_probe.png"


func _initialize() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.14, 0.22)
	bg.size = Vector2(640, 360)
	root.add_child(bg)

	var bar := ColorRect.new()
	bar.color = Color(0.78, 0.64, 0.36)
	bar.position = Vector2(160, 150)
	bar.size = Vector2(320, 40)
	root.add_child(bar)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 6:
		return false

	var img: Image = root.get_texture().get_image() if root.get_texture() else null
	if img == null:
		print("[shot] viewport texture is null -> headless cannot capture")
	else:
		print("[shot] image %dx%d fmt=%d" % [img.get_width(), img.get_height(), img.get_format()])
		var err := img.save_png(_out)
		print("[shot] save err=", err, " -> ", ProjectSettings.globalize_path(_out))
	quit(0)
	return true
