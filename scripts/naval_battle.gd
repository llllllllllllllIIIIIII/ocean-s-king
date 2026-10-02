class_name NavalBattle
extends RefCounted

# 实时舷炮遭遇（M10）：两条船在海上咬上，炮组装填、舷侧齐射、接舷跳帮。
#
# 四条设计：
#   1. **复用陆战的框架**：确定性（不用随机数）、查表命中、受击方权威判命中、
#      近战用同一套 `Ballistics.boarding_rates`。
#   2. **单位是炮组**：一轮舷侧能打出几发，取决于"装好了几门"——
#      所以"急着开火"和"等一轮齐射"是两种打法（硬指标 2）。
#   3. **七处损伤复用既有链路**：船壳/桅杆/舵走 `ShipDynamics.apply_damage`
#      （和气动同一条链），货舱掉货、弹药区打坏炮、帆索算进桅杆。
#      （风帆作为独立的第七处、以及起火/进水这两种"状态"，
#        要等 M13 的长航程磨损系统 —— 记在 docs/23 的 M10 卡片里。）
#   4. **这一仗不进存档**：docs/14 已经定了"打起来了不许存"，
#      打完的结果（损伤、伤亡、弹药）才写回船与名册。

const STEP := 0.5

var guns_own: Guns = Guns.new()
var guns_foe: Guns = Guns.new()
var gap_m := 900.0
var closing := true
var weather_id := "dry"
var powder_wet := false
var skill_own := 0.6
var skill_foe := 0.45
var intent := "fire"                 # fire / hold / board / withdraw
var ammo_want := "round_shot"
var t := 0.0
var over := false
var outcome := ""                    # won / lost / broke_off / mutual
var log_lines: Array = []

# 我方的"船况"（打完之后写回 Voyage）：船壳/桅杆/舵在 ShipDynamics 里，
# 这里额外记货舱与弹药区（M10 新增的两处）
var hold_damage := 0.0
var magazine_damage := 0.0
var own_crew := 40
var foe_crew := 40
var own_hull_damage := 0.0           # 只用于判定"打不动了"
var foe_hull_damage := 0.0
var foe_morale := 0.8
var boarded := false
var board_t := 0.0

var _round := 0
var _foe_split_hint := 0
var _our_frac := 0.0
var _their_frac := 0.0


func setup(own_crew_count := 40, foe_crew_count := 40, weather := "dry",
		gap := 900.0) -> void:
	weather_id = weather
	gap_m = maxf(60.0, gap)
	own_crew = own_crew_count
	foe_crew = foe_crew_count
	guns_own.setup_default()
	guns_foe.setup_default()
	guns_own.weather_id = weather_id
	guns_foe.weather_id = weather_id
	# 对面的弹药库：它也得从自己的货舱里扣（不是"无限打"）
	_foe_cargo = Cargo.new()
	_foe_cargo.setup(27.0, false)
	_foe_cargo.add("powder", 60)
	_foe_cargo.add("lead", 600)
	over = false
	outcome = ""
	t = 0.0
	log_lines.clear()
	_say("两条船在 %d 米的距离上对上了。" % int(gap_m))


func _say(s: String) -> void:
	log_lines.append(s)
	if log_lines.size() > 60:
		log_lines.pop_front()


func enemy_name() -> String:
	return "对面的船"


func tick(delta: float, cargo: Cargo, ship: ShipDynamics = null) -> void:
	if over:
		return
	var dt := minf(delta, STEP)
	t += dt
	guns_own.tick(dt, skill_own)
	guns_foe.tick(dt, skill_foe)
	# 距离：两边都在动 → 相对运动（命中打折）；想跑就拉开
	var n := Ballistics.naval()
	match intent:
		"withdraw":
			gap_m += float(n.get("closing_ms", 1.2)) * dt * 1.6
		"board":
			gap_m -= float(n.get("closing_ms", 1.2)) * dt * 1.8
		_:
			gap_m -= float(n.get("closing_ms", 1.2)) * dt * (1.0 if closing else 0.0)
	gap_m = maxf(0.0, gap_m)
	closing = intent != "withdraw" and gap_m > 120.0
	if intent == "withdraw" and gap_m > 1400.0:
		over = true
		outcome = "broke_off"
		_say("拉开了距离 —— 这一仗就此收手。")
		return
	# 我方开火（不接舷、且不是收手的时候）
	if intent != "withdraw" and not boarded:
		_player_fire(cargo)
	_foe_act(dt, ship)
	_boarding_tick(dt)
	_check_over()


func _player_fire(cargo: Cargo) -> void:
	if intent == "hold":
		return
	var res := guns_own.fire_broadside(gap_m, ammo_want, cargo, skill_own,
		true, closing, not powder_wet)
	if int(res["shots"]) == 0:
		return
	_round += 1
	foe_apply(res, ammo_want)
	if int(res["hits"]) > 0:
		_say("第 %d 轮：%d 门炮打出 %d 发，命中 %d 发。"
			% [_round, int(res["shots"]), int(res["shots"]), int(res["hits"])])
	elif int(res["misfires"]) > 0:
		_say("第 %d 轮：%d 发里有 %d 发哑火。" % [_round, int(res["shots"]), int(res["misfires"])])


func foe_apply(res: Dictionary, ammo_id: String) -> void:
	"""受击方结算：**这里就是"受击方权威"的位置** ——
	对面那一侧由它自己的机器调这个函数（联机时），单机就是本机。"""
	var split := _split_for(ammo_id)
	var structure := float(res["structure"])
	var rigging := float(res["rigging"])
	var personnel := float(res["personnel"])
	var hp := maxf(1.0, float(Ballistics.naval().get("hull_points", 8.0)))
	foe_hull_damage = clampf(foe_hull_damage
		+ structure * float(split.get("hull", 0.0)) / hp, 0.0, 1.0)
	# 士气按"挨了多少下"掉，不按"这一发有多重"掉 —— 一轮齐射不该直接打垮一条船的意志
	foe_morale = clampf(foe_morale - structure * 0.25 / hp - float(res["hits"]) * 0.02, 0.0, 1.0)
	if rigging > 0.0:
		foe_morale = clampf(foe_morale - rigging * 0.1, 0.0, 1.0)
	if personnel > 0.0:
		var losses := int(floor(personnel / 0.55 + 0.5))
		if losses > 0:
			foe_crew = maxi(0, foe_crew - losses)
			_say("对面甲板上倒了 %d 个。" % losses)
	# 弹药区被打中 → 打坏它的一门炮（确定性选哪一门）
	if structure > 0.0 and float(split.get("magazine", 0.0)) > 0.0:
		magazine_damage = clampf(magazine_damage
			+ structure * float(split.get("magazine", 0.0)) / hp, 0.0, 1.0)
		if magazine_damage > 0.25 and guns_foe.gun_count() > 1:
			var idx := int(floor(magazine_damage * 10.0)) % guns_foe.gun_count()
			guns_foe.guns.remove_at(idx)
			magazine_damage = 0.0
			_say("对面的炮位上腾起一团黑烟 —— 有一门炮哑了。")


func _split_for(ammo_id: String) -> Dictionary:
	var table: Dictionary = Ballistics.naval().get("damage_split", {})
	return table.get(ammo_id, {"hull": 1.0})


func _foe_act(_dt: float, ship: ShipDynamics) -> void:
	"""对面：够近就按自己的节奏打，船壳掉到 35% 以下就想跑。"""
	if foe_morale < 0.2 or foe_hull_damage > 0.65:
		gap_m += 60.0 * _dt
		return
	var res := guns_foe.fire_broadside(gap_m, "round_shot", _foe_cargo, skill_foe,
		true, closing, not powder_wet)
	if int(res["shots"]) == 0:
		return
	_take_hits(res, ship)


func _take_hits(res: Dictionary, ship: ShipDynamics) -> void:
	"""我方挨打：船壳/桅杆/舵走和气动同一条链路（`ShipDynamics.apply_damage`），
	货舱掉货、弹药区打坏我们的炮。"""
	var split := _split_for("round_shot")
	var structure := float(res["structure"])
	var hp := maxf(1.0, float(Ballistics.naval().get("hull_points", 8.0)))
	if ship != null:
		ship.apply_damage("hull", structure * float(split.get("hull", 0.0)) / hp)
		ship.apply_damage("mast", structure * float(split.get("mast", 0.0)) / hp)
		ship.apply_damage("rudder", structure * float(split.get("rudder", 0.0)) / hp)
	own_hull_damage = clampf(own_hull_damage + structure / hp, 0.0, 1.0)
	hold_damage = clampf(hold_damage + structure * float(split.get("hold", 0.0)) / hp, 0.0, 1.0)
	magazine_damage = clampf(magazine_damage
		+ structure * float(split.get("magazine", 0.0)) / hp, 0.0, 1.0)
	var personnel := float(res["personnel"])
	if personnel > 0.0:
		var losses := int(floor(personnel / 0.55 + 0.5))
		if losses > 0:
			own_crew = maxi(1, own_crew - losses)
			_say("我们甲板上倒了 %d 个。" % losses)
	if int(res["hits"]) > 0:
		_say("对面命中 %d 发 —— 船壳在响。" % int(res["hits"]))


# ------------------------------------------------------------ 接舷

var _foe_cargo: Cargo = null


func set_foe_cargo(c: Cargo) -> void:
	_foe_cargo = c


func can_board() -> bool:
	return gap_m <= float(Ballistics.naval().get("boarding", {}).get("grapple_range_m", 60.0))


func _boarding_tick(dt: float) -> void:
	if not boarded:
		if intent == "board" and can_board():
			boarded = true
			board_t = 0.0
			var r := Ballistics.boarding_rates(own_crew, foe_crew, skill_own, skill_foe, true)
			foe_crew = maxi(0, foe_crew - int(floor(float(r["volley"]) / 0.55 + 0.5)))
			_say("钩住了。跳帮的人跳过去 —— 甲板上乱成一团。")
		return
	board_t += dt
	var r := Ballistics.boarding_rates(own_crew, foe_crew, skill_own, skill_foe, true)
	var our_dps := float(r["boarders"]) / 0.55      # 每秒打倒几个人
	var their_dps := float(r["defenders"]) / 0.55
	# 按帧累计（小数先攒着）—— 用 board_t 直接乘会把每一帧都算成"从头到现在"
	var dmg_foe := our_dps * dt + _our_frac
	var n_foe := int(floor(dmg_foe))
	_our_frac = dmg_foe - float(n_foe)
	foe_crew = maxi(0, foe_crew - n_foe)
	var dmg_own := their_dps * dt + _their_frac
	var n_own := int(floor(dmg_own))
	_their_frac = dmg_own - float(n_own)
	own_crew = maxi(1, own_crew - n_own)
	if foe_crew <= 2:
		over = true
		outcome = "won"
		_say("对面甲板上没人了。船是你们的了。")
	elif own_crew <= 2:
		over = true
		outcome = "lost"
		_say("跳过去的人没回来。")


# ------------------------------------------------------------ 收尾

func _check_over() -> void:
	if over:
		return
	if foe_hull_damage >= 1.0 or foe_morale <= 0.05:
		over = true
		outcome = "won"
		_say("对面的船打不动了 —— 降旗了。")
	elif own_hull_damage >= 1.0:
		over = true
		outcome = "lost"
		_say("船吃水太深，打不下去了。")
	elif t > 1800.0:
		over = true
		outcome = "mutual"
		_say("两边都打累了，各自收帆。")


func stats() -> Dictionary:
	return {
		"t": t,
		"gap_m": gap_m,
		"shots_own": guns_own.shots_fired,
		"misfires_own": guns_own.misfires,
		"own_crew": own_crew,
		"foe_crew": foe_crew,
		"own_hull": own_hull_damage,
		"foe_hull": foe_hull_damage,
		"boarded": boarded,
		"outcome": outcome,
	}
