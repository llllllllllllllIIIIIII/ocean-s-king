# Day 1 冒烟测试：确认 Godot 能以无头方式跑脚本。
# 用法：
#   D:\Godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/smoke_test.gd
extends SceneTree


func _initialize() -> void:
	var v: Dictionary = Engine.get_version_info()
	print("[smoke] headless script OK")
	print("[smoke] godot ", v["string"])
	print("[smoke] project: ", ProjectSettings.get_setting("application/config/name"))
	print("[smoke] res:// -> ", ProjectSettings.globalize_path("res://"))
	quit(0)
