class_name LocalGroup
extends RefCounted

# 岛上的当地人（M6 的补课）：**他们本来就住在村子里**。
#
# 之前的问题（用户 2026-10-02 指出）：`LandBattle.setup()` 是在"打起来那一刻"凭空造出
# 两队的 —— 位置拿 `captain_pos` 当原点、两边各排开 60 米算出来。于是触发战斗时，
# 画面上会突然多出一批跟"你带的人""岛上的人"都没关系的点（"凭空刷新出来一批人和敌人"）。
#
# 现在这一伙人是**常驻实体**：
#   · 人数 / 站位 / 武器在开局就定下来（围着村子，确定性布置，不用随机数）；
#   · 翻了脸他们会**真的从村子走过来**，走到临战距离（LandBattle.START_GAP_M）才开打；
#   · 交给 `LandBattle` 的是**同一批 Unit 对象**（不是复制品）—— 所以打完少了几个人，
#     就是真的少了几个人，不会下一场又满血复活。

const SPEED := 3.4              # 米/秒（与 LandBattle.LOCALS_SPEED 同源）
const IDLE_SPEED := 1.4         # 平时溜达的速度

var id := "green_cape"
var group_name := "岛上的部落"
var home := Vector2.ZERO        # 村子中心
var units: Array = []           # Array[LandBattle.Unit] —— 就是战斗里用的那些对象

var _homes: Dictionary = {}     # unit.id -> 他平时站的位置（派生量，不进存档）
var _t := 0.0


func setup(p_home: Vector2, count := 12) -> void:
	home = p_home
	_t = 0.0
	units.clear()
	_homes.clear()
	var cfg: Dictionary = Ballistics.defs().get("local_warriors", {})
	var weapons: Array = cfg.get("weapons", ["spear_local"])
	for j in count:
		var u := LandBattle.Unit.new()
		u.id = "local_%d" % j
		u.side = "locals"
		u.name = "当地人 %d" % (j + 1)
		u.weapon = str(weapons[j % weapons.size()])
		u.skill = float(cfg.get("skill", 0.45))
		u.morale = float(cfg.get("morale", 0.6))
		u.pos = _ring_pos(j, count)
		_homes[u.id] = u.pos
		units.append(u)


func _ring_pos(j: int, count: int) -> Vector2:
	"""围村子的站位：两圈，确定性摆开（同一个 seed 每次一样）。"""
	var ang := TAU * float(j) / maxf(1.0, float(count)) + 0.3
	var r := 24.0 + 11.0 * float(j % 3)
	return home + Vector2(cos(ang), sin(ang)) * r


func advance(delta: float, target: Vector2, aggressive: bool) -> void:
	"""朝 `target` 走（aggressive）或者慢慢溜达回自己的位置。"""
	_t += delta
	for u in units:
		if not u.alive():
			continue
		var goal: Vector2 = target if aggressive else Vector2(_homes.get(u.id, u.pos))
		u.pos = _step(u.pos, goal, (SPEED if aggressive else IDLE_SPEED) * delta)


func _step(pos: Vector2, target: Vector2, step: float) -> Vector2:
	var d := target - pos
	if d.length() <= step:
		return target
	return pos + d.normalized() * step


func alive() -> int:
	var n := 0
	for u in units:
		if u.alive():
			n += 1
	return n


func nearest_distance(to: Vector2) -> float:
	var best := INF
	for u in units:
		if not u.alive():
			continue
		best = minf(best, u.pos.distance_to(to))
	return best


func center() -> Vector2:
	if units.is_empty():
		return home
	var sum := Vector2.ZERO
	for u in units:
		sum += u.pos
	return sum / float(units.size())


func describe() -> String:
	return "%s：%d 人（还能动的 %d）" % [group_name, units.size(), alive()]


# ------------------------------------------------------------ 存档（ShipState，和 culture 同一档）

func capture_state() -> Dictionary:
	var out := []
	for u in units:
		out.append({
			"id": u.id, "name": u.name, "weapon": u.weapon, "ammo": u.ammo,
			"skill": u.skill, "morale": u.morale, "health": u.health,
			"state": u.state, "shots": u.shots, "hits": u.hits,
			"pos": StateIO.v2(u.pos),
		})
	return {"id": id, "group_name": group_name, "home": StateIO.v2(home),
		"units": out, "_t": _t}


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	id = str(d.get("id", id))
	group_name = str(d.get("group_name", group_name))
	home = StateIO.to_v2(d.get("home", StateIO.v2(home)))
	_t = float(d.get("_t", 0.0))
	units.clear()
	_homes.clear()
	for raw in d.get("units", []):
		var u := LandBattle.Unit.new()
		u.id = str(raw.get("id", ""))
		u.side = "locals"
		u.name = str(raw.get("name", ""))
		u.weapon = str(raw.get("weapon", "spear_local"))
		u.ammo = str(raw.get("ammo", ""))
		u.skill = float(raw.get("skill", 0.45))
		u.morale = float(raw.get("morale", 0.6))
		u.health = float(raw.get("health", 1.0))
		u.state = str(raw.get("state", "ready"))
		u.shots = int(raw.get("shots", 0))
		u.hits = int(raw.get("hits", 0))
		u.pos = StateIO.to_v2(raw.get("pos", [0.0, 0.0]))
		_homes[u.id] = _ring_pos(units.size(), maxi(1, int(d.get("units", []).size())))
		units.append(u)
