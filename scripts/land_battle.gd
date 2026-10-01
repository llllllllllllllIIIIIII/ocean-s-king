class_name LandBattle
extends RefCounted

# 实时小队遭遇（M6）：5–15 个独立单位互相打，会伤也会死。
#
# 三条设计：
#   1. **确定性**：没有随机数。命中走 `Ballistics` 的查表，哑火用 (射手, 第几发) 的哈希 ——
#      同样的初始状态 + 同样的时长，必然得到同样的伤亡名单（验收第 2 条）。
#   2. **装填间隙是这一期的核心**：火绳枪装一发一分多钟，那一分多钟里
#      近战武器是唯一的战斗力 —— 所以"只带火枪不带近战"会输（验收第 3 条）。
#   3. **伤亡写回名册**：倒地 → 重伤（需要外科医生 + 药品），死亡 → 名册上留名字、
#      航海日志留讣告、结算的"船员成果"扣分。死是真的死。

const STEP := 0.25                   # 战斗固定步长（秒）
const VOLLEY_PERIOD := 8.0           # 齐射节拍：每 8 秒一次齐射（装好的人一起打）
const CREW_SPEED := 3.2              # 米/秒（登陆队在岸上的速度）
const LOCALS_SPEED := 3.4
const FLEE_MORALE := 0.18
const START_GAP_M := 120.0           # 遭遇开始时两队的间距：够打三四轮齐射，然后见真章


class Unit:
	extends RefCounted

	var id := ""
	var side := "crew"               # "crew" / "locals"
	var member_id := ""
	var name := ""
	var pos := Vector2.ZERO
	var weapon := "pike"
	var ammo := ""
	var skill := 0.3
	var health := 1.0
	var morale := 0.8
	var reload_t := 0.0
	var loaded := true
	var state := "ready"             # ready / reloading / down / dead / fled
	var shots := 0
	var hits := 0
	var damage := 0.0
	var misfires := 0

	func alive() -> bool:
		return state != "dead" and state != "down" and state != "fled"

	func is_ranged() -> bool:
		return str(Ballistics.weapon(weapon).get("kind", "")) == "ranged"


var units: Array = []
var weather_id := "dry"
var powder_wet := false
var formation_crew := "close"
var formation_locals := "loose"
var volley := true                   # 玩家的命令：齐射（true）/ 各自为战（false）
var intent := "hold"                 # hold / charge / withdraw
var t := 0.0
var over := false
var outcome := ""
var log_lines: Array = []
var visibility_m := 1200.0
var smoke_t := 0.0

var _volley_clock := VOLLEY_PERIOD
var _casualties := {"crew": [], "locals": []}
var _dead := {"crew": [], "locals": []}
var _volleys := 0
var _shots := 0
var _misfires := 0
var _round := 0


func setup(crew_members: Array, locals_count := 10, weather := "dry", origin := Vector2.ZERO) -> void:
	units.clear()
	weather_id = weather
	t = 0.0
	over = false
	outcome = ""
	log_lines.clear()
	_casualties = {"crew": [], "locals": []}
	_dead = {"crew": [], "locals": []}
	_volleys = 0
	_shots = 0
	_misfires = 0
	_round = 0
	_volley_clock = VOLLEY_PERIOD
	visibility_m = float(Ballistics.weather(weather_id).get("visibility_m", 1200.0))
	# 船员一侧：按名册分武器（确定性）
	var loadout := Weapons.loadout_for(crew_members)
	var i := 0
	for lo in loadout:
		var u := Unit.new()
		u.id = "crew_%d" % i
		u.side = "crew"
		u.member_id = str(lo["member_id"])
		u.name = str(lo["name"])
		u.weapon = str(lo["weapon"])
		u.ammo = str(lo["ammo"])
		u.skill = float(lo["skill"])
		u.pos = origin + Vector2(-8.0 + float(i % 5) * 3.0, -6.0 + float(i / 5) * 4.0)
		u.morale = 0.80
		units.append(u)
		i += 1
	# 当地人一侧：木矛与棍棒，人多、士气不稳
	var cfg: Dictionary = Ballistics.defs().get("local_warriors", {})
	var lw: Array = cfg.get("weapons", ["spear_local"])
	for j in locals_count:
		var v := Unit.new()
		v.id = "local_%d" % j
		v.side = "locals"
		v.name = "当地人 %d" % (j + 1)
		v.weapon = str(lw[j % lw.size()])
		v.skill = float(cfg.get("skill", 0.45))
		v.morale = float(cfg.get("morale", 0.6))
		v.pos = origin + Vector2(START_GAP_M + float(j % 5) * 3.0, -6.0 + float(j / 5) * 4.0)
		units.append(v)


func weather_name() -> String:
	return str(Ballistics.weather(weather_id).get("name", weather_id))


func crew_units() -> Array:
	return units.filter(func(u): return u.side == "crew")


func locals_units() -> Array:
	return units.filter(func(u): return u.side == "locals")


func alive_of(side: String) -> Array:
	return units.filter(func(u): return u.side == side and u.alive())


func standing(side: String) -> int:
	return alive_of(side).size()


func casualties() -> Dictionary:
	return _casualties.duplicate(true)


func stats() -> Dictionary:
	return {
		"t": t, "volleys": _volleys, "shots": _shots, "misfires": _misfires,
		"crew_standing": standing("crew"), "locals_standing": standing("locals"),
		"crew_down": _casualties["crew"].size(), "locals_down": _casualties["locals"].size(),
		"crew_dead": _dead["crew"].size(), "locals_dead": _dead["locals"].size(),
		"weather": weather_id, "volley": volley, "outcome": outcome,
	}


# ------------------------------------------------------------ 每帧

func tick(delta: float, cargo: Cargo) -> void:
	if over:
		return
	var steps := maxi(1, int(round(delta / STEP)))
	var dt := delta / float(steps)
	for _i in steps:
		_step(dt, cargo)
		t += dt
		if over:
			return


func _step(dt: float, cargo: Cargo) -> void:
	smoke_t = maxf(0.0, smoke_t - dt)
	if smoke_t <= 0.0:
		visibility_m = float(Ballistics.weather(weather_id).get("visibility_m", 1200.0))
	_volley_clock -= dt
	if volley and _volley_clock <= 0.0:
		_fire_volley(cargo)
		_volley_clock = VOLLEY_PERIOD
	for u in units:
		if not u.alive():
			continue
		if u.is_ranged():
			_ranged_step(u, dt, cargo)
		else:
			_melee_step(u, dt)
	for u in units:
		if u.alive() and u.morale < FLEE_MORALE:
			u.state = "fled"
			_log("%s 跑了。" % u.name)
	if standing("crew") == 0 or standing("locals") == 0:
		_finish()


func _ranged_step(u: Unit, dt: float, cargo: Cargo) -> void:
	if not u.loaded:
		u.reload_t = maxf(0.0, u.reload_t - dt)
		if u.reload_t <= 0.0:
			u.loaded = true
			u.state = "ready"
		return
	if not volley:
		var target := _nearest_enemy(u)
		if target != null:
			var d := u.pos.distance_to((target as Unit).pos)
			if d <= float(Ballistics.weapon(u.weapon).get("range_max_m", 250.0)):
				_fire_one(u, target as Unit, d, cargo, 1)
	match intent:
		"charge":
			_advance(u, dt, CREW_SPEED * 0.8)
		"withdraw":
			u.pos.x -= CREW_SPEED * dt
		_:
			pass


func _melee_step(u: Unit, dt: float) -> void:
	var target := _nearest_enemy(u)
	if target == null:
		return
	var foe := target as Unit
	var reach := float(Ballistics.weapon(u.weapon).get("reach_m", 2.0))
	var d := u.pos.distance_to(foe.pos)
	if u.side == "crew" and intent == "withdraw":
		u.pos.x -= CREW_SPEED * dt
		return
	if d > reach:
		var speed := CREW_SPEED if u.side == "crew" else LOCALS_SPEED
		u.pos += (foe.pos - u.pos).normalized() * speed * dt
		return
	u.reload_t -= dt
	if u.reload_t <= 0.0:
		u.reload_t = float(Ballistics.weapon(u.weapon).get("cycle_s", 4.0))
		_swing(u, foe)


func _swing(u: Unit, foe: Unit) -> void:
	var p := Ballistics.hit_chance(u.weapon, u.skill, u.pos.distance_to(foe.pos),
		form_side(u.side), 1, false)
	var dmg := Ballistics.damage_to_person(u.weapon, "", 0.0)
	# 队形对近战的影响（密集/横队比散兵更能顶）
	var melee_mult := float(Ballistics.formation(form_side(u.side)).get("melee_mult", 1.0))
	dmg *= melee_mult
	if u.side == "crew":
		# 船员在近战里的优势：钢制武器 + 甲具（数值在 weapons.json 的 crew_quality）
		var q: Dictionary = Ballistics.defs().get("crew_quality", {})
		dmg *= float(q.get("melee_damage_mult", 1.0))
		p = clampf(p * float(q.get("melee_hit_mult", 1.0)), 0.0, 0.95)
	# **装填间隙被冲击**：对面正低头装药（火器、还没装好）的时候最好打 ——
	# 这一条就是"近战必须有用"的机制形态（验收第 3 条）。
	if foe.is_ranged() and not foe.loaded:
		p = clampf(p * 1.35, 0.0, 0.95)
		dmg *= 1.25
	u.shots += 1
	_round += 1
	if _coin_round(u, _round) > p:
		return
	u.hits += 1
	u.damage += dmg
	_hurt(foe, dmg)


func _fire_volley(cargo: Cargo) -> void:
	"""齐射：所有**装好且有弹药**的人一起打 —— 这就是硬指标 2 的那一半。"""
	var shooters: Array = []
	for u in units:
		if u.side == "crew" and u.alive() and u.is_ranged() and u.loaded:
			if Weapons.can_fire(cargo, u.weapon):
				shooters.append(u)
	if shooters.is_empty():
		return
	_volleys += 1
	for u in shooters:
		var target := _nearest_enemy(u)
		if target == null:
			return
		_fire_one(u, target as Unit, u.pos.distance_to((target as Unit).pos),
			cargo, shooters.size())
	smoke_t = Ballistics.smoke_duration(weather_id)
	visibility_m = Ballistics.visibility_after_volley(weather_id)


func _fire_one(u: Unit, target: Unit, distance: float, cargo: Cargo, shooters: int) -> void:
	if not Weapons.can_fire(cargo, u.weapon):
		return                        # 打光了就是打光了（验收第 4 条后半句）
	u.loaded = false
	u.state = "reloading"
	u.reload_t = Ballistics.reload_time(u.weapon, u.skill)
	u.shots += 1
	_shots += 1
	_round += 1
	Weapons.pay_ammo(cargo, u.weapon)
	if Ballistics.misfires(u.id.hash(), _round, u.weapon, weather_id, powder_wet):
		u.misfires += 1
		_misfires += 1
		u.morale = clampf(u.morale - 0.01, 0.0, 1.0)
		return
	var p := Ballistics.hit_chance(u.weapon, u.skill, distance, form_side(u.side),
		shooters, volley)
	if _coin_round(u, _round) > p:
		_hurt_morale(target, 0.01)
		return
	u.hits += 1
	var dmg := Ballistics.damage_to_person(u.weapon, u.ammo, distance)
	u.damage += dmg
	_hurt(target, dmg)


func _advance(u: Unit, dt: float, speed: float) -> void:
	var target := _nearest_enemy(u)
	if target == null:
		return
	u.pos += ((target as Unit).pos - u.pos).normalized() * speed * dt


func _nearest_enemy(u: Unit) -> Unit:
	var best: Unit = null
	var best_d := INF
	for o in units:
		var foe := o as Unit
		if foe.side == u.side or not foe.alive():
			continue
		var d := u.pos.distance_to(foe.pos)
		if d < best_d:
			best_d = d
			best = foe
	return best


func form_side(side: String) -> String:
	return formation_crew if side == "crew" else formation_locals


static func _coin_round(u: Unit, round_index: int) -> float:
	"""确定性硬币（第几个射手、第几发都在里面）—— 不用 randf()。"""
	return Ballistics._coin(u.id.hash() * 7 + u.shots, round_index)


func _hurt(target: Unit, amount: float) -> void:
	target.health = clampf(target.health - amount, 0.0, 1.0)
	_hurt_morale(target, 0.06)
	if target.health <= 0.05:
		_down(target)


func _hurt_morale(u: Unit, amount: float) -> void:
	u.morale = clampf(u.morale - amount, 0.0, 1.0)


func _down(u: Unit) -> void:
	u.state = "down"
	_casualties[u.side].append(u.id)
	_log("%s 倒下了。" % u.name)
	for o in units:
		var mate := o as Unit
		if mate.side == u.side:
			_hurt_morale(mate, 0.05)
		else:
			mate.morale = clampf(mate.morale + 0.03, 0.0, 1.0)


func kill_down(u: Unit) -> void:
	"""重伤员没救回来 —— 由 Voyage 按"有没有外科医生 + 药品"决定。死是真的死。"""
	if u.state != "down":
		return
	u.state = "dead"
	_casualties[u.side].erase(u.id)
	_dead[u.side].append(u.id)


func downed_units(side := "crew") -> Array:
	return units.filter(func(u): return u.side == side and u.state == "down")


func dead_units(side := "crew") -> Array:
	return units.filter(func(u): return u.side == side and u.state == "dead")


func _finish() -> void:
	over = true
	if standing("locals") == 0 and standing("crew") > 0:
		outcome = "crew_wins"
	elif standing("crew") == 0:
		outcome = "locals_win"
	else:
		outcome = "draw"
	_log("打完了：%s（船员 %d 人还站着，当地人 %d 人）" % [
		outcome, standing("crew"), standing("locals")])


func _log(text: String) -> void:
	log_lines.append("[%.0f 秒] %s" % [t, text])
	if log_lines.size() > 40:
		log_lines.pop_front()


func describe() -> String:
	var s := stats()
	return "第 %.0f 秒　%s　船员 %d/%d　当地人 %d/%d　倒 %d　死 %d　齐射 %d 次　哑火 %d" % [
		t, weather_name(), int(s["crew_standing"]), crew_units().size(),
		int(s["locals_standing"]), locals_units().size(),
		int(s["crew_down"]), int(s["crew_dead"]), int(s["volleys"]), int(s["misfires"])]
