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
