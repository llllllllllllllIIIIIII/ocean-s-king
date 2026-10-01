class_name ShipPhysics
extends RefCounted

# 船体物理 + 帆的气动（docs/01 支柱 2 的公式落地）。
#
# 数据流（AGENTS.md 铁律 5）：玩家 → 船员 → 帆 → 船 → 表现。
# 这个文件只负责"帆受到多少力、船体顶得住多少"，它**不持有**船的位置和速度
# —— 那些在 ship_dynamics.gd 里，而且只有那里能写。
#
# 参数全部来自 data/defs/ship_physics.json（唯一真源），
# 与标定工具 tools/aero_prototype.py 读同一份数字。
# tests/test_aero_polar.gd 会证明两边算出的极坐标一致。

const DEFAULT_PATH := "res://data/defs/ship_physics.json"
const RHO_AIR := 1.225      # kg/m^3
const GRAVITY := 9.81
const KNOT := 0.514444      # m/s per knot

# 求前进速度时的搜索网格，与 aero_prototype.py 的 U_GRID 完全一致：
# 诱导阻力在 u->0 时发散、船体阻力在 u->30 时发散，"总阻力 - 推力"是一条
# U 形曲线，可能有两个根；真正的稳态是**大的那个根**。
const U_GRID_LO := 0.05
const U_GRID_MID := 1.0
const U_GRID_HI := 30.0

var mass := 60000.0          # kg   排水量
var gm := 0.55               # m    稳心高度（决定横倾）
var h_ce := 10.5             # m    帆受力中心距水线高度
var k_lat := 20000.0         # N/(m/s) 龙骨侧向阻力
var c_lin := 137.0           # N/(m/s)   船体线性阻力（摩擦）
var c_quad := 172.0          # N/(m/s)^2 船体兴波阻力
var c_wave := 9.0            # N/(m/s)^4 兴波高次项 = 真正的船速上限
var k_stall := 800.0         # N/(m/s)^2 龙骨最大侧向力系数（F_max = k_stall * s^2）
var c_cross := 12000.0       # N/(m/s)^2 船体横流阻力（失速后靠它顶住侧向力）
var u_min := 0.3             # m/s  参考流速下限，防止低速段除零
var area_main := 62.0        # m^2
var area_jib := 28.0         # m^2
var jib_offset := -8.0       # 度   前帆相对主帆的攻角差

var _alpha_tab := PackedFloat64Array()
var _cl_tab := PackedFloat64Array()
var _cd_tab := PackedFloat64Array()
var _ugrid := PackedFloat64Array()


static func load_default(path := DEFAULT_PATH) -> ShipPhysics:
	var p := ShipPhysics.new()
	p._build_grid()
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		push_error("找不到船体物理参数: " + path + "（用内嵌默认值）")
		return p
	var d = JSON.parse_string(text)
	if typeof(d) != TYPE_DICTIONARY:
		push_error("船体物理参数不是合法 JSON: " + path)
		return p
	p._apply(d)
	return p


func _apply(d: Dictionary) -> void:
	var hull: Dictionary = d.get("hull", {})
	var keel: Dictionary = d.get("keel", {})
	var sails: Dictionary = d.get("sails", {})
	mass = float(hull.get("mass_kg", mass))
	gm = float(hull.get("gm_m", gm))
	h_ce = float(hull.get("h_ce_m", h_ce))
	k_lat = float(hull.get("k_lat_n_per_ms", k_lat))
	c_lin = float(hull.get("c_lin_n_per_ms", c_lin))
	c_quad = float(hull.get("c_quad_n_per_ms2", c_quad))
	c_wave = float(hull.get("c_wave_n_per_ms4", c_wave))
	k_stall = float(keel.get("k_stall_n_per_ms2", k_stall))
	c_cross = float(keel.get("c_cross_n_per_ms2", c_cross))
	u_min = float(keel.get("u_min_ms", u_min))
	area_main = float(sails.get("main_area_m2", area_main))
	area_jib = float(sails.get("jib_area_m2", area_jib))
	jib_offset = float(sails.get("jib_attack_offset_deg", jib_offset))

	var polar: Dictionary = d.get("sail_polar", {})
	if polar.has("alpha_deg"):
		_alpha_tab = _to_f64(polar["alpha_deg"])
		_cl_tab = _to_f64(polar["cl"])
		_cd_tab = _to_f64(polar["cd"])


func _to_f64(arr: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(arr.size())
	for i in arr.size():
		out[i] = float(arr[i])
	return out


func _build_grid() -> void:
	_ugrid = PackedFloat64Array()
	for i in 10:                                        # geomspace(0.05, 1.0, 10)
		_ugrid.append(U_GRID_LO * pow(U_GRID_MID / U_GRID_LO, float(i) / 9.0))
	for i in 12:                                        # linspace(1.5, 30.0, 12)
		_ugrid.append(1.5 + (U_GRID_HI - 1.5) * float(i) / 11.0)
	if _alpha_tab.is_empty():                           # JSON 缺失时的兜底表
		_alpha_tab = PackedFloat64Array([0, 5, 10, 15, 18, 25, 35, 50, 70, 90])
		_cl_tab = PackedFloat64Array([0.00, 0.40, 0.78, 1.05, 1.15, 1.05, 0.82, 0.55, 0.34, 0.20])
		_cd_tab = PackedFloat64Array([0.02, 0.04, 0.09, 0.16, 0.24, 0.45, 0.75, 1.00, 1.15, 1.20])


static func normalize180(a: float) -> float:
	# 等价于 Python 的 (a + 180) % 360 - 180（GDScript 的 fmod 会保留符号，要补一次）
	var m := fmod(a + 180.0, 360.0)
	if m < 0.0:
		m += 360.0
	return m - 180.0


# ------------------------------------------------------------------ 帆

func cl_cd(alpha_deg: float) -> Vector2:
	"""攻角（度）-> (Cl, Cd)。|a| > 90 表示风流吹在帆的背面，退化为平板阻力。"""
	var a := absf(alpha_deg)
	if a > 90.0:
		a = 180.0 - a
	return Vector2(_interp(_cl_tab, a), _interp(_cd_tab, a))


func _interp(tab: PackedFloat64Array, x: float) -> float:
	var n := _alpha_tab.size()
	if n == 0:
		return 0.0
	if x <= _alpha_tab[0]:
		return tab[0]
	if x >= _alpha_tab[n - 1]:
		return tab[n - 1]
	for i in range(1, n):
		if x <= _alpha_tab[i]:
			var t := (x - _alpha_tab[i - 1]) / (_alpha_tab[i] - _alpha_tab[i - 1])
			return tab[i - 1] + t * (tab[i] - tab[i - 1])
	return tab[n - 1]


func sail_force(app_speed: float, app_dir_deg: float, chord_deg: float,
		area: float) -> Vector2:
	"""单面帆产生的力（船体坐标系：+x 船首、+y 右舷，单位牛顿）。"""
	var q := 0.5 * RHO_AIR * app_speed * app_speed
	var alpha := normalize180(app_dir_deg - chord_deg)
	var cc := cl_cd(alpha)
	var lift := q * area * cc.x
	var drag := q * area * cc.y
	var lift_dir := app_dir_deg + (90.0 if alpha > 0.0 else -90.0)
	var fx := lift * cos(deg_to_rad(lift_dir)) + drag * cos(deg_to_rad(app_dir_deg))
	var fy := lift * sin(deg_to_rad(lift_dir)) + drag * sin(deg_to_rad(app_dir_deg))
	return Vector2(fx, fy)


# ------------------------------------------------------------------ 船体

func hull_drag(u: float) -> float:
	return c_lin * u + c_quad * u * u + c_wave * u * u * u * u


func stall_over(side_force: float, u: float, w: float) -> float:
	"""龙骨超载比例：0 = 没失速。用的是**实际水流速度**（u, w），不是"想要多少力"。"""
	var s2 := u * u + w * w + u_min * u_min
	return maxf(absf(side_force) / maxf(k_stall * s2, 1e-6) - 1.0, 0.0)


func side_slip(side_force: float, u: float, w: float) -> float:
	"""横向力的去向：龙骨先顶（线性），顶不住就横着漂（船体横流阻力）。

	反解出的是**实际侧滑速度**。静止起步时 w = 0 -> 诱导阻力 = 0，所以船能从
	静止起得来；等侧滑真的长起来，诱导阻力才把它按住。这一点很重要 ——
	如果按"侧向力有多大"去算阻力，船会永远推不动自己。
	"""
	var a := absf(side_force)
	var s2 := u * u + w * w + u_min * u_min
	var fmax := k_stall * s2
	var sgn := signf(side_force)
	if a <= fmax:
		return sgn * a / k_lat
	return sgn * (fmax / k_lat + sqrt((a - fmax) / c_cross))


func induced_drag(side_force: float, u: float, w: float) -> float:
	"""诱导（漂移）阻力：横向力沿水流方向的分量，**再投影回船的首尾轴**。

	= |F_lat| * sin(侧滑角) * cos(侧滑角) = |F_lat| * |u*w| / (u^2 + w^2)

	小侧滑角时它就是经典的 F_lat * tan(侧滑角)（顶风慢、横风快都靠它）；
	水横向流（u->0）时它趋于 0 —— 船横着漂的时候，横向力垂直于首尾轴，
	不该去挡前进。这一条是"停着的船还能起得来"的物理基础。
	"""
	var s2 := u * u + w * w + 1e-9
	return absf(side_force) * absf(u * w) / s2


func drag_total(u: float, fy: float, w: float) -> float:
	return hull_drag(u) + induced_drag(fy, u, w)


func solve_surge(fx: float, fy: float, w: float) -> float:
	"""解 fx = 总阻力(u)，取满足条件的最大 u（U 形曲线的右根 = 真稳态）。

	没有任何 u 满足 -> 船根本推不动 -> 返回 0。
	"""
	if fx <= 0.0:
		return 0.0
	var idx := -1
	var n := _ugrid.size()
	for i in n:
		if drag_total(_ugrid[i], fy, w) <= fx:
			idx = i
	if idx < 0:
		return 0.0
	var lo := _ugrid[idx]
	var hi := _ugrid[idx + 1] if idx < n - 1 else _ugrid[n - 1]
	for _k in 24:
		var mid := 0.5 * (lo + hi)
		if drag_total(mid, fy, w) <= fx:
			lo = mid
		else:
			hi = mid
	return lo


# ------------------------------------------------------------------ 稳态与配平

func steady_state(tws: float, twa_deg: float, alpha_main: float,
		alpha_jib := INF, iters := 42, u0 := 1.5) -> Dictionary:
	"""给定帆的攻角（度），迭代求稳态（u 前进速度、w 侧滑、phi 横倾）。

	帆的收放用攻角参数化：chord = 视风方向 - alpha —— 这正是船上舵手做的事，
	看着帆的吃风角收放，船一加速视风前移就再收一点（所以每个迭代步都重算 chord）。
	初值给 1.5 m/s 的一点余速：现实里也是船有了速度才谈得上"能不能走"。
	"""
	var aj := alpha_jib
	if is_inf(aj):
		aj = clampf(alpha_main + jib_offset, 8.0, 90.0)
	var wx := tws * cos(deg_to_rad(twa_deg + 180.0))
	var wy := tws * sin(deg_to_rad(twa_deg + 180.0))
	var u := u0
	var w := 0.0
	var phi := 0.0
	var chord_m := -140.0
	var chord_j := -140.0
	var over := 0.0
	var u_new := u0
	for _i in iters:
		var ax := wx - u
		var ay := wy - w
		var sp := sqrt(ax * ax + ay * ay)
		if sp < 1e-6:
			sp = 1e-6
		var ad := rad_to_deg(atan2(ay, ax))
		chord_m = ad - alpha_main
		chord_j = ad - aj
		var fm := sail_force(sp, ad, chord_m, area_main)
		var fj := sail_force(sp, ad, chord_j, area_jib)
		var fx := fm.x + fj.x
		var fy := fm.y + fj.y
		var cp := cos(deg_to_rad(phi))
		fx *= cp
		fy *= cp
		over = stall_over(fy, u, w)
		# 侧滑由"龙骨 + 船体横流阻力"平衡反解；失速时侧滑明显变大，玩家看得见
		var w_new := side_slip(fy, u, w)
		u_new = solve_surge(fx, fy, w_new)
		var phi_new := rad_to_deg(asin(clampf(
			fy * h_ce / (mass * GRAVITY * gm), -1.0, 1.0)))
		u += 0.35 * (u_new - u)
		w += 0.35 * (w_new - w)
		phi += 0.35 * (phi_new - phi)
	# 收敛校验：松弛迭代在"刚好推得动/刚好推不动"的刀尖上会进 limit cycle，
	# 于是算出一个**根本不是稳态**的正速度（顺风时尤其明显）。
	# 真稳态下 u_new == u，所以只要最后一步还差得远，就判定为"这个配平站不住"。
	if absf(u_new - u) >= 0.05:
		u = 0.0
	return {
		"u": u, "w": w, "phi": phi, "over": over,
		"chord_main": chord_m, "chord_jib": chord_j,
	}


func best_trim(tws: float, twa_deg: float, alpha_step := 5.0) -> Dictionary:
	"""搜索最佳配平：一维扫主帆攻角（前帆跟着主帆减 8 度）。粗搜 + 局部细搜。"""
	var best := {"u": 0.0, "alpha": 5.0}
	var a := 5.0
	while a <= 90.0 + 1e-9:
		var s := steady_state(tws, twa_deg, a)
		if float(s["u"]) > float(best["u"]):
			best = s
			best["alpha"] = a
		a += alpha_step
	var a0 := float(best["alpha"])
	var lo := maxf(5.0, a0 - alpha_step)
	var hi := minf(90.0, a0 + alpha_step)
	a = lo
	while a <= hi + 1e-9:
		var s2 := steady_state(tws, twa_deg, a)
		if float(s2["u"]) > float(best["u"]):
			best = s2
			best["alpha"] = a
		a += 1.0
	return best


func speed_kn(tws: float, twa_deg: float) -> float:
	return float(best_trim(tws, twa_deg)["u"]) / KNOT


func describe() -> String:
	return "%.0ft / 帆 %.0f+%.0f m2 / k_stall %.0f / c_cross %.0f / c_wave %.1f" % [
		mass / 1000.0, area_main, area_jib, k_stall, c_cross, c_wave]
