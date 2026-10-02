class_name Climate
extends RefCounted

# 气候与季节（M13）：季风窗口、飓风季、坏血病、断粮断水的后果、船体老化。
#
# 三条设计（docs/22 第 12 章）：
#   1. **数值只有一份**：都在 `data/defs/climate.json`（与 weather.json 同等地位）。
#   2. **时间只从日历里来**：季节由航海日志的日期算出来，不另起一个计时器 ——
#      所以"三年"这件事在气候上也是自洽的。
#   3. **季风要能被玩家利用**：同一段航线，窗口内外走起来差别很大（验收第 1 条），
#      而"什么时候走"是玩家能决定的（等、绕、赌）。
#
# 纬度从哪来：只有**带投影的世界**（全球图）才谈得上纬度 —— 平面海域（8km 迷你海、
#
# 48km 大西洋）返回"中性"，季风与飓风都不参与。这是有意的：那两片海是教程与回归用的。

const DEFS_PATH := "res://data/defs/climate.json"

static var _defs_cache: Dictionary = {}


static func defs() -> Dictionary:
	if _defs_cache.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(DEFS_PATH))
		if typeof(d) == TYPE_DICTIONARY:
			_defs_cache = d
		else:
			push_error("气候表读不出来：" + DEFS_PATH)
	return _defs_cache


# ------------------------------------------------------------ 季节

static func season_at(elapsed: float) -> Dictionary:
	"""这一刻是哪个季节（由日历的月份推出来）。

	⚠️ 入参与 `VoyageJournal.date_parts()` 一致：**游戏秒**，不是"第几天"。
	"""
	var parts := VoyageJournal.date_parts(elapsed)
	# ⚠️ `date_parts()` 的键是 y / m / d（不是 year / month / day）
	var month := int(parts.get("m", 1))
	for s in defs().get("seasons", []):
		# ⚠️ JSON 里的数字是 float：`[9,10,11].has(9)` 是 **false**（老坑，AGENTS.md 记过）
		for mm in s.get("months", []):
			if int(mm) == month:
				return s
	return {}


static func season_id_at(elapsed: float) -> String:
	return str(season_at(elapsed).get("id", "winter"))


static func season_name_at(elapsed: float) -> String:
	return str(season_at(elapsed).get("name", "冬"))


# ------------------------------------------------------------ 季风

static func monsoon_band(lat: float) -> Dictionary:
	for m in defs().get("monsoon", []):
		if lat >= float(m.get("lat_min", -90.0)) and lat <= float(m.get("lat_max", 90.0)):
			return m
	return {}


static func wind_shift_deg(lat: float, elapsed: float) -> float:
	"""季风把基准风向转多少度（没有季风的地方返回 0）。"""
	var band := monsoon_band(lat)
	if band.is_empty():
		return 0.0
	var sid := season_id_at(elapsed)
	return float((band.get("shift_by_season", {}) as Dictionary).get(sid, 0.0))


static func wind_gain(lat: float, elapsed: float) -> float:
	"""季风把风力乘多少（没有季风的地方返回 1）。"""
	var band := monsoon_band(lat)
	if band.is_empty():
		return 1.0
	var sid := season_id_at(elapsed)
	return float((band.get("gain_by_season", {}) as Dictionary).get(sid, 1.0))


static func monsoon_name(lat: float) -> String:
	return str(monsoon_band(lat).get("name", ""))


# ------------------------------------------------------------ 飓风季

static func hurricane_band(lat: float, elapsed: float) -> Dictionary:
	"""这一带、这个月是不是飓风季？是就返回那条带子的定义。"""
	var parts := VoyageJournal.date_parts(elapsed)
	var month := int(parts.get("m", 1))
	for h in defs().get("hurricane", []):
		if lat < float(h.get("lat_min", -90.0)) or lat > float(h.get("lat_max", 90.0)):
			continue
		for mm in h.get("months", []):
			if int(mm) == month:
				return h
	return {}


# ------------------------------------------------------------ 坏血病 / 断粮 / 老化

static func scurvy_health_per_day(days_since_fresh: float) -> float:
	"""离开新鲜食物多少天之后，健康每天掉多少（越久越快）。"""
	var s: Dictionary = defs().get("scurvy", {})
	var safe := float(s.get("safe_days", 30.0))
	if days_since_fresh <= safe:
		return 0.0
	var late := float(s.get("steep_days", 60.0))
	if days_since_fresh <= late:
		return float(s.get("health_per_day", 0.005))
	return float(s.get("health_per_day_late", 0.011))


static func scurvy_mood_per_day(days_since_fresh: float) -> float:
	var s: Dictionary = defs().get("scurvy", {})
	if days_since_fresh <= float(s.get("safe_days", 30.0)):
		return 0.0
	return float(s.get("mood_per_day", 0.0025))


static func scurvy_name() -> String:
	return "坏血病"


static func attrition_health_per_day(starving: bool, thirsty: bool) -> float:
	var a: Dictionary = defs().get("attrition", {})
	var out := 0.0
	if starving:
		out += float(a.get("starving_health_per_day", 0.02))
	if thirsty:
		out += float(a.get("thirsty_health_per_day", 0.05))
	return out


static func attrition_grace_days() -> float:
	return float((defs().get("attrition", {}) as Dictionary).get("grace_days", 5.0))


static func death_health() -> float:
	"""健康掉到这个数以下就有人死（坏血病与断粮共用这个门槛）。"""
	var a: Dictionary = defs().get("attrition", {})
	var s: Dictionary = defs().get("scurvy", {})
	return float(a.get("death_health", 0.05)) if a.has("death_health") else float(s.get("death_health", 0.05))


static func wear_for_day(days_at_sea: float) -> Dictionary:
	"""船体老化：过了 start_day 个航程日之后，每多一个航程日掉多少。"""
	var w: Dictionary = defs().get("wear", {})
	if days_at_sea <= float(w.get("start_day", 60.0)):
		return {}
	var out := {}
	for part in ["hull", "mast", "rudder", "sail"]:
		var per := float(w.get("%s_per_day" % part, 0.0))
		if per > 0.0:
			out[part] = per
	return out


static func describe_day(lat: float, elapsed: float) -> String:
	var bits := PackedStringArray()
	bits.append(Climate.season_name_at(elapsed))
	var mn := monsoon_name(lat)
	if mn != "":
		bits.append("%s：风转 %.0f°、风力 ×%.2f" % [mn, wind_shift_deg(lat, elapsed),
			wind_gain(lat, elapsed)])
	if not hurricane_band(lat, elapsed).is_empty():
		bits.append("%s 正在飓风季" % str(hurricane_band(lat, elapsed).get("name", "")))
	return "　".join(bits)
