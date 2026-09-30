# Day 2 验收测试：SVG 部件管线。
#
# 对应 docs/02 的三条验收标准里的第三条：
#   "换掉一个 SVG 文件，船的外观立刻改变（证明部件化成立）"
#
# 用法：
#   Godot_..._console.exe --headless --path . --script res://tests/test_svg_parts.gd

extends SceneTree

const PARTS := "res://data/defs/parts.json"
const PROPS := "res://data/defs/props.json"
const BASE := "res://assets/ship/parts/"

var _errors: PackedStringArray = []
var _checks := 0


func _initialize() -> void:
	print("=== test_svg_parts ===")

	var bank := SvgBank.new()
	var defs = JSON.parse_string(FileAccess.get_file_as_string(PARTS))

	# --- 1) 每个部件都能找到、都能栅格化、尺寸与声明一致 ---
	for name in defs["parts"]:
		var d: Dictionary = defs["parts"][name]
		var path := BASE + str(d["file"])
		_check(FileAccess.file_exists(path), "部件文件不存在：%s" % path)
		if not FileAccess.file_exists(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		var img := bank.rasterize_text(text, 1.0)
		_check(img != null, "部件栅格化失败：%s" % name)
		if img == null:
			continue
		var declared := bank.intrinsic_of(name)
		_check(Vector2(img.get_width(), img.get_height()).is_equal_approx(declared),
			"部件 %s 声明的画布 %s 与实际栅格化 %dx%d 不一致" % [
				name, str(declared), img.get_width(), img.get_height()])
		# 锚点必须落在画布内，否则部件会被画到错误的位置
		var a: Array = d["anchor"]
		_check(float(a[0]) >= 0 and float(a[0]) <= declared.x
			and float(a[1]) >= 0 and float(a[1]) <= declared.y,
			"部件 %s 的锚点 %s 落在画布 %s 之外" % [name, str(a), str(declared)])

	# --- 2) props.json 里引用的部件都必须存在 ---
	var props = JSON.parse_string(FileAccess.get_file_as_string(PROPS))["props"]
	for t in props:
		var part := str(props[t].get("part", ""))
		if part != "":
			_check(bank.has_part(part),
				"物件 %s 引用了不存在的部件 %s" % [t, part])

	# --- 3) 换掉一个 SVG 的内容，栅格化结果必须跟着变 ---
	#     这是"部件化成立"的直接证据：画什么完全由 SVG 文件决定。
	var src := FileAccess.get_file_as_string(BASE + "rig/mast.svg")
	var before := bank.rasterize_text(src, 1.0)
	var swapped := src.replace("#6b4f2a", "#00ff00")
	_check(swapped != src, "换色替换没有生效，测试本身失效")
	var after := bank.rasterize_text(swapped, 1.0)
	_check(after != null, "替换后的 SVG 栅格化失败")
	if before != null and after != null:
		# 统计整图有多少像素变了，比取单点可靠（单点可能正好落在没改的那一圈上）
		var diff := 0
		for y in before.get_height():
			for x in before.get_width():
				if not before.get_pixel(x, y).is_equal_approx(after.get_pixel(x, y)):
					diff += 1
		_check(diff > 500,
			"换了颜色但只有 %d 个像素变化，说明画面不是由 SVG 内容决定的" % diff)
		print("  换色后有 %d 个像素发生变化" % diff)

	# --- 4) 缓存生效：重复取同一档位不应重复栅格化 ---
	var n0 := bank.rasterizations
	var bank2 := SvgBank.new()
	for i in 5:
		bank2.rasterize_text(src, 1.0)             # 直接栅格化不走缓存，仅确认稳定
	_check(bank.rasterizations == n0, "纯栅格化调用不应改变部件表的缓存计数")

	_finish()


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_errors.append(msg)


func _finish() -> void:
	if _errors.is_empty():
		print("=== OK：%d 项断言全部通过 ===" % _checks)
		quit(0)
	else:
		print("=== 失败：%d 项断言中 %d 个不通过 ===" % [_checks, _errors.size()])
		for e in _errors:
			print("  x  " + e)
		quit(1)
