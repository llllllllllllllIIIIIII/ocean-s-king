class_name WindField
extends RefCounted

# 风场（docs/01 支柱 6 的占位版：只做"全局风向还会慢慢变"）。
# 岛屿背风区、洋流带留给之后，这里先把接口留好：
#   * tws_ms / from_dir_deg 是真风（不是视风）
#   * 一切"船感受到什么风"的计算都在 ship_dynamics 里，风场只描述空气怎么动
#
# 风向约定：from_dir_deg 是"风从哪来"，世界系里 0 = +x，顺时针为正。
# 风"吹向"的方向 = from_dir_deg + 180（空气的速度矢量就是这个方向）。

const KNOT := 0.514444

var base_tws := 8.0             # 基准真风速 m/s
var base_from_dir := 0.0        # 基准真风来向
var gust_gain := 0.8            # 阵风幅度 m/s
var dir_swing_deg := 14.0       # 风向摆幅
var time_scale := 1.0

var tws_ms := 8.0
var from_dir_deg := 0.0
var t := 0.0


func _init(p_tws := 8.0, p_dir := 0.0) -> void:
	base_tws = p_tws
	base_from_dir = p_dir
	tws_ms = p_tws
	from_dir_deg = p_dir


func step(delta: float) -> void:
	"""风随时间缓变。两条不同周期的正弦叠加：看着不规律，但完全可复现。"""
	t += delta * time_scale
	from_dir_deg = base_from_dir + dir_swing_deg * sin(t * 0.045) \
		+ 0.35 * dir_swing_deg * sin(t * 0.117 + 1.7)
	tws_ms = base_tws + gust_gain * sin(t * 0.09) + 0.4 * gust_gain * sin(t * 0.21 + 0.6)
	tws_ms = maxf(tws_ms, 0.5)


func velocity_world() -> Vector2:
	"""空气的速度矢量（世界系，m/s）：方向 = 来向 + 180。"""
	var blow_to := deg_to_rad(from_dir_deg + 180.0)
	return Vector2(cos(blow_to), sin(blow_to)) * tws_ms


func from_dir_rad() -> float:
	return deg_to_rad(from_dir_deg)


func describe() -> String:
	return "真风 %.1f m/s（%.1f 节）来自 %.0f°，阵风幅度 %.1f" % [
		tws_ms, tws_ms / KNOT, fposmod(from_dir_deg, 360.0), gust_gain]


# ------------------------------------------------------------ 存档（docs/14）
# base_from_dir 会被"风向突变"事件改（+55°），所以它也是会变的值，必须存。

func capture_state() -> Dictionary:
	return {
		"base_tws": base_tws,
		"base_from_dir": base_from_dir,
		"gust_gain": gust_gain,
		"dir_swing_deg": dir_swing_deg,
		"time_scale": time_scale,
		"tws_ms": tws_ms,
		"from_dir_deg": from_dir_deg,
		"t": t,
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	base_tws = float(d.get("base_tws", 8.0))
	base_from_dir = float(d.get("base_from_dir", 0.0))
	gust_gain = float(d.get("gust_gain", 0.8))
	dir_swing_deg = float(d.get("dir_swing_deg", 14.0))
	time_scale = float(d.get("time_scale", 1.0))
	tws_ms = float(d.get("tws_ms", 8.0))
	from_dir_deg = float(d.get("from_dir_deg", 0.0))
	t = float(d.get("t", 0.0))
