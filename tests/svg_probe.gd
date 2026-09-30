# 验证 SVG 能否在运行时以任意清晰度栅格化。
#
# 背景：Godot 通过 .svg.import 把 SVG 当纹理导入，默认按 1:1 栅格化。
# 正交摄像机要能从"整片海"拉到"甲板细节"，导入纹理在高倍放大下会糊。
# Image.load_svg_from_string() 允许运行时按指定倍率重新栅格化，
# 这就是"矢量船"方案能否成立的关键。
extends SceneTree

const SVG_TEST := """<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50">
<rect width="100" height="50" fill="#1b3a5c"/>
<path d="M0 45 L100 45 L80 50 L20 50 Z" fill="#c8a45c"/>
<circle cx="50" cy="20" r="12" fill="#f0d9a0"/>
</svg>"""


func _initialize() -> void:
	print("[svg] --- runtime SVG rasterization probe ---")
	for scale in [1.0, 4.0, 16.0]:
		var img := Image.new()
		var err: int = img.load_svg_from_string(SVG_TEST, scale)
		if err != OK:
			print("[svg] scale=", scale, " FAILED err=", err)
			continue
		print("[svg] scale=%-5s -> %dx%d  fmt=%d" % [
			str(scale), img.get_width(), img.get_height(), img.get_format()])
	quit(0)
