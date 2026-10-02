class_name Ballistics
extends RefCounted

# 火器的**纯模型**（M6）：命中、伤害、哑火、齐射系数。
#
# 这一层刻意不碰地图、不碰单位、不碰寻路 —— 四项硬指标全是"数"的问题，
# 混在寻敌与走路里调，永远说不清是模型错了还是队伍走错了。
# 和气动那一期一样：先离线把参数扫通，再接进游戏。
#
# 三条纪律（docs/13 第 6.3 节）：
#   1. **不用随机数**：命中是"技能 × 距离 × 队形 × 武器"的查表 + 确定性偏差；
#      哑火用 (射手 id, 第几发) 的哈希当确定性硬币 —— 所以同样的局面必得同样的伤亡名单。
#   2. 判定归属：射击方只广播"谁向谁开火"，命中由**受击方所属的权威**判（联机时用）。
#   3. 伤害复用已有的链路：对船就是船体/桅杆/舵那三处损伤，不新开一套。

const DEFS_PATH := "res://data/defs/weapons.json"

static var _defs_cache: Dictionary = {}


static func defs() -> Dictionary:
	if _defs_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DEFS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_defs_cache = d
		else:
			push_error("武器表读不出来：" + DEFS_PATH)
	return _defs_cache


static func weapon(id: String) -> Dictionary:
	for w in defs().get("weapons", []):
		if str(w.get("id", "")) == id:
			return w
	for w in defs().get("melee_weapons_local", []):
		if str(w.get("id", "")) == id:
			return w
	return {}


static func ammo(id: String) -> Dictionary:
	for a in defs().get("ammo_types", []):
		if str(a.get("id", "")) == id:
			return a
	return {}


static func weather(id: String) -> Dictionary:
	for w in defs().get("weather", []):
		if str(w.get("id", "")) == id:
			return w
	return {}


static func formation(id: String) -> Dictionary:
	for f in defs().get("formations", []):
		if str(f.get("id", "")) == id:
			return f
	return {}


# ------------------------------------------------------------ 舷炮（M10）

static func naval() -> Dictionary:
	return defs().get("naval", {})


static func gun(id: String) -> Dictionary:
	"""一门炮：`kind == "naval"` 的那些（寇非林长炮）。隼炮与回旋炮两用，
	它们的数值仍在 `weapons[]` 里 —— 只有一份。"""
	var w := weapon(id)
	if w.is_empty() or str(w.get("kind", "")) != "naval":
		return {}
	return w


static func naval_guns() -> Array:
	"""一艘船一侧的炮：从 `naval.guns_per_side` 推出来，不另写一份表。"""
	var out := []
	for wid in (naval().get("guns_per_side", {}) as Dictionary).keys():
		out.append({"id": str(wid), "count": int(naval()["guns_per_side"][wid])})
	return out


static func damage_to_rigging(weapon_id: String, ammo_id: String) -> float:
	"""打帆索（链弹）。与砸结构、打人是三条独立的口径。"""
	var w := weapon(weapon_id)
	if w.is_empty() or str(w.get("kind", "")) == "melee":
		return 0.0
	return float(w.get("damage", 0.0)) * float(ammo(ammo_id).get("vs_rigging", 0.0))


static func naval_hit_chance(weapon_id: String, skill: float, distance_m: float,
		guns := 6, broadside := false, closing := false) -> float:
	"""舷炮的命中：船炮的命中表（按横队的目标大小算）× 舷侧齐射增益 × 相对运动的罚。

	与 `tools/weapons_prototype.py` 的 `naval_hit_chance` 同源 —— 两份不一致时
	那个离线脚本就失去意义了（和气动那套一样的规矩）。
	"""
	var n := naval()
	var p := hit_chance(weapon_id, skill, distance_m, "ranked", 1, false, 1.0)
	if broadside:
		p *= 1.0 + float(n.get("broadside_gain", 0.9)) \
			* clampf((float(guns) - 1.0) / 5.0, 0.0, 1.0)
	else:
		p *= float(n.get("independent_hit_mult", 0.75))
	if closing:
		p *= 1.0 - float(n.get("relative_motion_penalty", 0.35))
	return clampf(p, 0.0, 0.95)


static func broadside_damage(weapon_id: String, ammo_id: String, skill: float,
		distance_m: float, guns := 6, broadside := true, closing := true) -> float:
	var p := naval_hit_chance(weapon_id, skill, distance_m, guns, broadside, closing)
	return float(guns) * p * damage_to_structure(weapon_id, ammo_id)


# ------------------------------------------------------------ 接舷（M10）

static func boarding_rates(boarders: int, defenders: int, boarder_skill := 0.6,
		defender_skill := 0.45, boarder_bonus := true) -> Dictionary:
	"""接舷的期望值：跳帮那一下的一轮火器 + 之后甲板上的近战交换率。

	返回 {"boarders": 每秒伤害, "defenders": 每秒伤害, "volley": 一次性伤害}。
	与离线脚本的 `boarding_rates` 同源。
	"""
	var b: Dictionary = naval().get("boarding", {})
	var q: Dictionary = defs().get("crew_quality", {})
	var dmg_mult := float(q.get("melee_damage_mult", 1.0)) if boarder_bonus else 1.0
	var hit_mult := float(q.get("melee_hit_mult", 1.0)) if boarder_bonus else 1.0
	var cycle := maxf(0.1, float(b.get("melee_cycle_s", 3.6)))
	var pike := weapon("pike")
	var sword := weapon("sword")
	var p_pike := float(pike.get("base_hit", 0.55)) \
		* (1.0 - float(pike.get("skill_weight", 0.45)) + float(pike.get("skill_weight", 0.45)) * boarder_skill)
	var p_sword := float(sword.get("base_hit", 0.62)) \
		* (1.0 - float(sword.get("skill_weight", 0.4)) + float(sword.get("skill_weight", 0.4)) * defender_skill)
	var board_rate := float(boarders) * p_pike * hit_mult * float(pike.get("damage", 0.38)) \
		* dmg_mult / cycle
	var defend_rate := float(defenders) * p_sword * float(b.get("defender_bonus", 1.15)) \
		* float(sword.get("damage", 0.3)) / cycle
	var volley := float(boarders) * hit_chance("arquebus", boarder_skill, 30.0, "close", 1, false) \
		* float(weapon("arquebus").get("damage", 0.55)) \
		* float(b.get("firearm_volley_mult", 0.5))
	return {"boarders": board_rate, "defenders": defend_rate, "volley": volley}


static func melee_weapon_of(skill: float) -> String:
	"""跳帮时拿什么：长矛（够得着）。留一个口子给以后的武器选择。"""
	return "pike"


# ------------------------------------------------------------ 哑火

static func misfire_chance(weapon_id: String, weather_id: String, powder_wet := false) -> float:
	"""哑火率。火药受潮 = 直接打不着（返回 1.0）。

	干燥 ≤5%、大雨 ≥30% 是硬指标 3 —— 靠 `weapons.json` 里的 misfire_dry 与
	天气的 misfire_mult 一起决定（0.035 × 9 = 0.315 ✔）。
	"""
	if powder_wet:
		return 1.0
	var w := weapon(weapon_id)
	if w.is_empty() or str(w.get("kind", "")) != "ranged":
		return 0.0
	var base := float(w.get("misfire_dry", 0.03))
	return clampf(base * float(weather(weather_id).get("misfire_mult", 1.0)), 0.0, 1.0)


static func misfires(shooter_key: int, shot_index: int, weapon_id: String,
		weather_id: String, powder_wet := false) -> bool:
	"""这一发是不是哑火 —— 确定性硬币，不用随机数。

	同一场遭遇（同样的射手、同样的第几发）必然得到同样的结果，
	所以"伤亡名单可复现"这条验收才成立。
	"""
	var p := misfire_chance(weapon_id, weather_id, powder_wet)
	if p <= 0.0:
		return false
	if p >= 1.0:
		return true
	return _coin(shooter_key, shot_index) < p


static func _coin(a: int, b: int) -> float:
	"""确定性伪随机：把 (a, b) 摊成 0..1。用的是整数哈希，不是 randf()。"""
	var h := (a * 73856093) ^ (b * 19349663) ^ 0x9E3779B9
	h = absi(h)
	return float(h % 100000) / 100000.0


static func roll(key_a: int, key_b: int) -> float:
	"""给别处用的确定性硬币（舷炮的每一发也要可复现）。"""
	return _coin(key_a, key_b)


# ------------------------------------------------------------ 命中

static func hit_chance(weapon_id: String, skill: float, distance_m: float,
		formation_id := "close", shooter_count := 1, volley := false,
		target_size_mult := 1.0) -> float:
	"""命中率：技能 × 距离 × 队形密度 × 武器（+ 齐射系数）。

	`shooter_count` 与 `volley` 一起决定齐射增益：十个人密集齐射 = ×1.9
	（`formations.volley_gain` 0.9），而各自为战（散兵，不齐射）= ×0.75。
	这两条正是硬指标 2 的分子与分母。
	"""
	var w := weapon(weapon_id)
	if w.is_empty():
		return 0.0
	var f := formation(formation_id)
	var base := float(w.get("base_hit", 0.3))
	var w_skill := float(w.get("skill_weight", 0.4))
	var eff := float(w.get("range_effective_m", 100.0))
	var half := maxf(1.0, float(w.get("half_range_m", 50.0)))
	var p := base * (1.0 - w_skill + w_skill * clampf(skill, 0.0, 1.0))
	if distance_m > eff:
		# 有效射程之外掉得很快（球面扩散 + 精度）
		var over := (distance_m - eff) / half
		p *= 1.0 / (1.0 + over * over)
	p *= float(f.get("hit_mult", 1.0)) * target_size_mult
	if volley and str(w.get("kind", "")) == "ranged":
		p *= 1.0 + float(f.get("volley_gain", 0.0)) * clampf((float(shooter_count) - 1.0) / 9.0, 0.0, 1.0)
	return clampf(p, 0.0, 0.95)


static func in_ammo_band(ammo_id: String, distance_m: float) -> bool:
	"""这一种弹在这个距离上打不打得到人（霰弹 80–200 米是硬指标 4）。"""
	var a := ammo(ammo_id)
	if a.is_empty():
		return true
	var band: Array = a.get("band_m", [0.0, 99999.0])
	return distance_m >= float(band[0]) and distance_m <= float(band[1])


# ------------------------------------------------------------ 伤害

static func damage_to_person(weapon_id: String, ammo_id: String, distance_m: float) -> float:
	"""(武器, 弹种, 距离) → 打掉目标多少生存度。"""
	var w := weapon(weapon_id)
	if w.is_empty():
		return 0.0
	if str(w.get("kind", "")) == "melee":
		return float(w.get("damage", 0.3))
	if not in_ammo_band(ammo_id, distance_m):
		return 0.0
	return float(w.get("damage", 0.4)) * float(ammo(ammo_id).get("vs_person", 1.0))


static func damage_to_structure(weapon_id: String, ammo_id: String) -> float:
	"""对船体/工事：实心弹 1.0、霰弹 0.08（硬指标 4 的另一个方向）。"""
	var w := weapon(weapon_id)
	if w.is_empty():
		return 0.0
	if str(w.get("kind", "")) == "melee":
		return 0.0
	return float(w.get("damage", 0.4)) * float(ammo(ammo_id).get("vs_structure", 0.3))


static func reload_time(weapon_id: String, skill := 0.3) -> float:
	"""装填时间：熟练的人在区间下端（火绳枪 30–60 秒那条）。"""
	var w := weapon(weapon_id)
	var slow := float(w.get("reload_s", 40.0))
	var fast := float(w.get("reload_skilled_s", slow))
	return lerpf(slow, fast, clampf(skill, 0.0, 1.0))


# ------------------------------------------------------------ 齐射（硬指标 2 的那把尺子）

static func volley_multiplier(shooter_count: int, formation_id: String, volley := true) -> float:
	if not volley or shooter_count <= 1:
		return 1.0
	var f := formation(formation_id)
	return 1.0 + float(f.get("volley_gain", 0.0)) * clampf((float(shooter_count) - 1.0) / 9.0, 0.0, 1.0)


static func expected_damage(shooter_count: int, weapon_id: String, ammo_id: String,
		skill: float, distance_m: float, formation_id: String,
		shooters_per_volley := -1, volley := false) -> float:
	"""一次齐射/一轮互射的**期望伤害**（测试与离线标定都用它）。

	`shooters_per_volley` 是"同时开火的人数"：各自为战时就是 1（各打各的）。
	"""
	var n := shooter_count if shooters_per_volley < 0 else shooters_per_volley
	var p := hit_chance(weapon_id, skill, distance_m, formation_id, n, volley)
	var d := damage_to_person(weapon_id, ammo_id, distance_m)
	return float(shooter_count) * p * d


# ------------------------------------------------------------ 硝烟

static func visibility_after_volley(weather_id: String) -> float:
	return float(defs().get("smoke_visibility_m", 60.0))


static func smoke_duration(weather_id: String) -> float:
	return float(weather(weather_id).get("smoke_s", 5.0))
