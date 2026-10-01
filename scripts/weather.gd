class_name Weather
extends RefCounted

# 自然环境（M7）：天气不是随机播放的动画 —— 它真的改风、改损伤、改瞭望距离、
# 改火器的哑火率。验收第 3 条（"风暴真的改变航行结果"）就靠这一条链子：
#
#   天气 → 风场乘数 → 帆的受力 → 航速与到达时间
#        → 每小时往船体/桅杆/舵上砸损伤 → 阻力与帆面积
#        → 瞭望距离（雾里看不见岛）→ 发现变慢
#        → 火器的哑火天气（大雨 = M6 的 31.5%）与船员的疲劳/心情（M5）
#
# **不用随机数**：换天气由 (第几个航程小时, 所在的海区带) 的哈希决定 ——
# 所以同一趟航程必然遇到同样的天气，无头可复现（和 M6 的火器同一条纪律）。

const DEFS_PATH := "res://data/defs/weather.json"

static var _defs_cache: Dictionary = {}

var defs: Dictionary = {}            # 静态
var state_id := "clear"              # **会变的值**
var hours_left := 8.0                # 这一段天气还剩几个航程小时
var spells := 0                      # 换过几次天气（结算与测试要看）
var worst := "clear"                 # 这一程遇到的最坏的天气
var storm_hours := 0.0               # 在风暴里待了多久（验收第 3 条的证据）
var _acc := 0.0                      # 航程小时的累加器
var _leg := 0                        # 第几"段"天气（哈希用的第二个输入）


static func defs_data() -> Dictionary:
	if _defs_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DEFS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_defs_cache = d
		else:
			push_error("天气表读不出来：" + DEFS_PATH)
	return _defs_cache


func setup(start := "clear") -> void:
	defs = defs_data()
	state_id = start
	hours_left = _roll_hours(state_id)
	spells = 0
	worst = start
	storm_hours = 0.0
	_acc = 0.0
	_leg = 0


func state() -> Dictionary:
	for s in defs.get("states", []):
		if str(s.get("id", "")) == state_id:
			return s
	return {}


func state_name() -> String:
	return str(state().get("name", state_id))


func band_id_at(pos: Vector2) -> String:
	for b in defs.get("bands", []):
		if pos.y <= float(b.get("y_max", 99999)):
			return str(b.get("id", "clear"))
	return "tropical"


func band_at(pos: Vector2) -> Dictionary:
	var want := band_id_at(pos)
	for b in defs.get("bands", []):
		if str(b.get("id", "")) == want:
			return b
	return {}


# ------------------------------------------------------------ 航线元数据（M8 收尾）
#
# M7 的卡片把"航线元数据（风险/补给/价值）"留给了 M8。补给那一半早就有了
# （`Voyage.supply_need_for`）；这里补的是**风险**那一半：一段航线会穿过哪些天气带。
# 全部从 `weather.json` 的 `bands` 现推，不另写一份"风险表" ——
# 数值只有一个真源，而且玩家看到的与真的会遇上的**是同一份数据**。

static func band_at_pos(pos: Vector2) -> Dictionary:
	"""静态版 `band_at`：给"出发前算这一段路上有什么"用（不需要 Weather 实例）。"""
	for b in defs_data().get("bands", []):
		if pos.y <= float(b.get("y_max", 99999.0)):
			return b
	return {}


static func bands_on(points: PackedVector2Array, step_m := 500.0) -> Array:
	"""这一段航线穿过哪些天气带（按先后去重）。

	必须**沿线段采样**，不能只看端点：天气带是按 y 分的，而一段航线的两个端点
	可能一个在信风带、一个在热带海岸，中间整条赤道无风带就藏在中间。
	（实测踩过：只看端点时"渡海去巴西"这一段报的是"信风带、热带海岸"，
	把真正把船晒住的那条无风带漏掉了 —— 而它恰恰是最该告诉玩家的。）
	"""
	var out := []
	var seen := {}
	if points.size() == 1:
		_push_band(out, seen, points[0])
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var steps := maxi(1, int(ceil(a.distance_to(b) / maxf(1.0, step_m))))
		for k in range(steps + 1):
			_push_band(out, seen, a.lerp(b, float(k) / float(steps)))
	return out


static func _push_band(out: Array, seen: Dictionary, p: Vector2) -> void:
	var band := band_at_pos(p)
	var id := str(band.get("id", ""))
	if id == "" or seen.has(id):
		return
	seen[id] = true
	out.append(band)


static func band_states_text(band: Dictionary) -> String:
	"""一个带里可能出现哪几种天气：`比斯开湾以北（晴、雾、风暴）`。"""
	var band_name := str(band.get("name", "?"))
	var names := PackedStringArray()
	var seen := {}
	for sid in band.get("states", []):
		var id := str(sid)
		if seen.has(id):
			continue
		seen[id] = true
		var nm := state_display(id)
		# 带名里已经说过的就不重复（"赤道无风带"里不必再写一遍"无风带"）
		if band_name.find(nm) >= 0:
			continue
		names.append(nm)
	if names.is_empty():
		return band_name
	return "%s（%s）" % [band_name, "、".join(names)]


static func state_display(id: String) -> String:
	"""某个天气 id 的中文名（`state_name()` 是**当前天气**的名字，别重名）。"""
	for s in defs_data().get("states", []):
		if str(s.get("id", "")) == id:
			return str(s.get("name", id))
	return id


static func band_risk(band: Dictionary) -> String:
	"""这一带算不算"要小心"：会刮风暴或会无风停船的都算。"""
	var states: Array = band.get("states", [])
	if states.has("storm") or states.has("squall"):
		return "风暴"
	if states.has("calm"):
		return "无风"
	return ""


static func risky_bands_on(points: PackedVector2Array) -> Array:
	"""这一段路上"要小心"的那些带（海图上就标它们）。"""
	var out := []
	for b in bands_on(points):
		if band_risk(b) != "":
			out.append(b)
	return out


# ------------------------------------------------------------ 推进

func step(delta: float, pos: Vector2) -> void:
	"""按**航程小时**走：天气的寿命以航程小时计（和日历、补给同一个尺度，docs/17）。"""
	var voyage_hours := delta * VoyageJournal.voyage_time_scale / 3600.0
	if voyage_hours <= 0.0:
		return
	_acc += voyage_hours
	hours_left -= voyage_hours
	if state_id == "storm":
		storm_hours += voyage_hours
	if hours_left <= 0.0:
		_change(pos)


func _change(pos: Vector2) -> void:
	spells += 1
	_leg += 1
	var band := band_at(pos)
	var pool: Array = band.get("states", ["clear"])
	var h := absi(hash(str(band_id_at(pos)) + "|" + str(_leg) + "|" + str(spells)))
	state_id = str(pool[h % pool.size()])
	hours_left = _roll_hours(state_id)
	if _severity(state_id) > _severity(worst):
		worst = state_id


func _roll_hours(id: String) -> float:
	var s := _state_def(id)
	var span: Array = s.get("hours", [4.0, 8.0])
	var lo := float(span[0])
	var hi := float(span[1])
	var h := absi(hash(id + "#" + str(_leg) + "#" + str(spells)))
	return lerpf(lo, hi, float(h % 1000) / 1000.0)


func _state_def(id: String) -> Dictionary:
	for s in defs.get("states", []):
		if str(s.get("id", "")) == id:
			return s
	return {}


static func _severity(id: String) -> int:
	match id:
		"storm": return 4
		"squall": return 3
		"fog": return 2
		"calm": return 2
	return 1


func force(id: String, hours := 6.0) -> void:
	"""测试与剧情用：把天气直接按到某一种上（`docs/13` 的验收要能复现）。"""
	if _state_def(id).is_empty():
		return
	state_id = id
	hours_left = hours
	if _severity(id) > _severity(worst):
		worst = id


# ------------------------------------------------------------ 天气 → 各条链路

func wind_mult() -> float:
	return float(state().get("wind_mult", 1.0))


func visibility_m() -> float:
	return float(state().get("visibility_m", 8000.0))


func fatigue_mult() -> float:
	return float(state().get("fatigue_mult", 1.0))


func mood_bias() -> float:
	return float(state().get("mood_bias", 0.0))


func misfire_weather() -> String:
	"""给 M6 的陆战用：大雨 = 哑火率 ×9（31.5%）。"""
	return str(state().get("misfire_weather", "dry"))


func damage_per_hour() -> Dictionary:
	return state().get("damage_per_hour", {})


func is_storm() -> bool:
	return state_id == "storm" or state_id == "squall"


func describe() -> String:
	return "%s（还有 %.1f 个航程小时；最坏遇到过 %s）" % [
		state_name(), hours_left, str(_state_def(worst).get("name", worst))]


# ------------------------------------------------------------ 存档（WorldState，docs/14 第 2 节）

func capture_state() -> Dictionary:
	return {
		"state_id": state_id,
		"hours_left": hours_left,
		"spells": spells,
		"worst": worst,
		"storm_hours": storm_hours,
		"_acc": _acc,
		"_leg": _leg,
	}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	defs = defs_data()
	state_id = str(d.get("state_id", "clear"))
	hours_left = float(d.get("hours_left", 8.0))
	spells = int(d.get("spells", 0))
	worst = str(d.get("worst", "clear"))
	storm_hours = float(d.get("storm_hours", 0.0))
	_acc = float(d.get("_acc", 0.0))
	_leg = int(d.get("_leg", 0))
