class_name SvgBank
extends RefCounted

# SVG 部件仓库：读源文件 → 按需要的倍率在运行时栅格化 → 缓存。
#
# 这是"矢量船"方案能成立的关键。Godot 导入 SVG 时会栅格化成固定分辨率的纹理，
# 正交摄像机一拉近就糊。这里绕开导入系统，直接用
# Image.load_svg_from_string(svg_text, scale) 在运行时按当前缩放重新栅格化，
# 所以拉多远、拉多近都是锐利的。
#
# 缓存以"倍率档位"为键：缩放连续变化时不重新栅格化，跨档才重新做一次。

const BASE := "res://assets/ship/parts/"
const SCALE_BUCKETS: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0]
const MAX_TEX := 4096.0          # 单边纹理上限，防止大部件在高倍率下吃掉显存

var _defs: Dictionary = {}        # name -> {file, anchor}
var _src: Dictionary = {}         # name -> SVG 源文本
var _intrinsic: Dictionary = {}   # name -> 画布尺寸（SVG 单位）
var _tex: Dictionary = {}         # "name@scale" -> ImageTexture
var _re: RegEx
var rasterizations := 0           # 实际栅格化次数，用来验证缓存真的生效
var cache_hits := 0


func _init(defs_path := "res://data/defs/parts.json") -> void:
	_re = RegEx.new()
	_re.compile('width="([0-9.]+)"\\s+height="([0-9.]+)"')

	if not FileAccess.file_exists(defs_path):
		push_error("找不到部件表: " + defs_path)
		return
	var raw = JSON.parse_string(FileAccess.get_file_as_string(defs_path))
	for name in raw["parts"]:
		var d: Dictionary = raw["parts"][name]
		var path := BASE + str(d["file"])
		if not FileAccess.file_exists(path):
			push_error("缺少部件文件: " + path)
			continue
		var text := FileAccess.get_file_as_string(path)
		_defs[name] = d
		_src[name] = text
		_intrinsic[name] = _read_intrinsic(text)


func has_part(name: String) -> bool:
	return _src.has(name)


func rasterize_text(svg_text: String, scale: float) -> Image:
	"""把任意 SVG 文本栅格化成 Image。部件表之外的用途也走这里，便于验证管线。"""
	var img := Image.new()
	if img.load_svg_from_string(svg_text, scale) != OK:
		return null
	return img


func intrinsic_of(name: String) -> Vector2:
	return _intrinsic.get(name, Vector2.ZERO)


func part_names() -> Array:
	return _src.keys()


func stats() -> String:
	return "部件 %d 个，栅格化 %d 次，缓存命中 %d 次" % [
		_src.size(), rasterizations, cache_hits]


func draw_part(ci: CanvasItem, name: String, at: Vector2, rot: float,
		world_ppu: float, raster_ppu: float, tint := Color.WHITE) -> bool:
	"""把部件画到画布上，使锚点落在 at 处（世界像素坐标）。

	注意 world_ppu 和 raster_ppu 是**两个不同的值**，不能混：
	  * world_ppu  = 每个 SVG 单位占多少世界像素（固定值，摄像机再去缩放）
	  * raster_ppu = 每个 SVG 单位在屏幕上占多少像素（= world_ppu * 摄像机缩放）
	    只用来决定按什么倍率栅格化，保证纹理不被放大
	把 world_ppu 也乘上缩放，会导致摄像机再放大一次 —— 船会整体大一圈。
	"""
	var p := _fetch(name, raster_ppu)
	if p.is_empty():
		return false
	ci.draw_set_transform(at, rot, Vector2.ONE)
	ci.draw_texture_rect(p["tex"],
		Rect2(-p["anchor"] * world_ppu, p["units"] * world_ppu), false, tint)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	return true


# ------------------------------------------------------------------ 内部

# 不能叫 _get()——那是 Object 的内置虚函数，签名是 _get(StringName) -> Variant。
# 和 _set() 是同一类坑。
func _fetch(name: String, px_per_unit: float) -> Dictionary:
	if not _src.has(name):
		return {}
	var units: Vector2 = _intrinsic[name]
	var scale := _pick_scale(units, px_per_unit)
	var key := "%s@%.3f" % [name, scale]
	if _tex.has(key):
		cache_hits += 1
	else:
		var img := Image.new()
		if img.load_svg_from_string(_src[name], scale) != OK:
			push_error("SVG 栅格化失败: " + name)
			return {}
		_tex[key] = ImageTexture.create_from_image(img)
		rasterizations += 1
	var a: Array = _defs[name]["anchor"]
	return {
		"tex": _tex[key],
		"units": units,
		"anchor": Vector2(float(a[0]), float(a[1])),
	}


func _pick_scale(intrinsic: Vector2, need: float) -> float:
	# 取"不小于所需分辨率"的最小档位，保证纹理永远不被放大
	var s: float = SCALE_BUCKETS[0]
	for b in SCALE_BUCKETS:
		s = b
		if b >= need:
			break
	var longest: float = maxf(intrinsic.x, intrinsic.y)
	if longest * s > MAX_TEX:
		s = MAX_TEX / longest
	return maxf(s, 0.05)


func _read_intrinsic(text: String) -> Vector2:
	var m := _re.search(text)
	if m:
		return Vector2(float(m.get_string(1)), float(m.get_string(2)))
	return Vector2(100, 100)
