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

var own_id := "trinidad"             # 我这条船的 id（联机时用来认"这一炮是打给我的"）
var foe_id := ""                     # 对面那条船的 id（对面是另一个玩家时用）
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
var foe_rounds := 0                 # 对面朝我打了几轮（对账与面板要看的数）
var volleys_sent := 0               # 我朝对面打了几轮（联机时记在"等回执"上）
# M13：起火 / 进水的硬币**每场只掷一次**（掷出"没有"也不能反复掷 —— 那等于必中）
var _fire_rolled := false
var _flood_rolled := false
var last_incoming: Dictionary = {}   # 最近一次挨打的结果（受击方权威那一份）
var last_outgoing: Dictionary = {}   # 最近一次打出去的结果（对面权威广播回来的那一份）
# 联机时挂上它：开火不再本机判命中，而是把 `volley_request()` 交给受击方的拥有者
# （谁挨打谁说了算 —— docs/22 第 10.4 节）。单机时它是空的，走本机解析那条路。
var fire_delegate := Callable()


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
	if fire_delegate.is_valid():
		fire_delegate.call()
		return
	var res := guns_own.fire_broadside(gap_m, ammo_want, cargo, skill_own,
		true, closing, not powder_wet)
	if int(res["shots"]) == 0:
		return
	_round += 1
	apply_outgoing(res)
	if int(res["hits"]) > 0:
		_say("第 %d 轮：%d 门炮打出 %d 发，命中 %d 发。"
			% [_round, int(res["shots"]), int(res["shots"]), int(res["hits"])])
	elif int(res["misfires"]) > 0:
		_say("第 %d 轮：%d 发里有 %d 发哑火。" % [_round, int(res["shots"]), int(res["misfires"])])


# ------------------------------------------------------------ 联机：受击方权威（M10 剩下那半）

func volley_request() -> Dictionary:
	"""把"这一轮舷侧"的**全部输入**打成一包，交给受击方权威去算。

	包里每一样都是"开火那一刻的事实"：装好的炮位、炮组技能、距离、弹种、
	以及确定性硬币的起点（`shot_base`）。所以同一包请求在**任何一台机器上**
	算出来的结果都一样 —— 这是"受击方权威判命中"能成立的前提（docs/22 第 10.4 节）。
	"""
	var guns := []
	for g in guns_own.ready_guns():
		guns.append({"slot": int(g["slot"]), "id": str(g["id"])})
	return {
		"shooter": own_id,
		"target": foe_id,
		"guns": guns,
		"skill": skill_own,
		"distance_m": gap_m,
		"ammo": ammo_want,
		"broadside": true,
		"closing": closing,
		"weather": weather_id,
		"powder_wet": powder_wet,
		"shot_base": guns_own.shots_fired,
		"round": _round,
	}


static func resolve(req: Dictionary) -> Dictionary:
	"""**纯函数**：同样的请求必得同样的结果（不碰任何状态）。

	受击方权威用它算"我挨了什么"；开火方拿同一份返回核对 ——
	两边的伤亡名单因此不可能对不上（`tests/test_net_naval` 就是盯这条）。
	"""
	var out := {
		"shots": 0, "hits": 0, "misfires": 0,
		"structure": 0.0, "rigging": 0.0, "personnel": 0.0,
		"personnel_losses": 0, "ammo": str(req.get("ammo", "round_shot")),
		"shooter": str(req.get("shooter", "")), "target": str(req.get("target", "")),
	}
	var guns: Array = req.get("guns", [])
	if guns.is_empty():
		return out
	var n := guns.size()
	var skill := float(req.get("skill", 0.5))
	var dist := float(req.get("distance_m", 900.0))
	var ammo_id := str(req.get("ammo", "round_shot"))
	var broadside := bool(req.get("broadside", true))
	var closing := bool(req.get("closing", true))
	var weather_id := str(req.get("weather", "dry"))
	var wet := bool(req.get("powder_wet", false))
	var idx := int(req.get("shot_base", 0))
	for g in guns:
		var wid := str((g as Dictionary).get("id", "culverin"))
		var slot := int((g as Dictionary).get("slot", 0))
		var p := Ballistics.naval_hit_chance(wid, skill, dist, n, broadside, closing)
		out["shots"] = int(out["shots"]) + 1
		if Ballistics.misfires(slot * 97 + 7, idx, wid, weather_id, wet):
			out["misfires"] = int(out["misfires"]) + 1
			idx += 1
			continue
		var hit := Ballistics.roll(slot * 31 + 3, idx) < p
		idx += 1
		if not hit:
			continue
		out["hits"] = int(out["hits"]) + 1
		out["structure"] = float(out["structure"]) + Ballistics.damage_to_structure(wid, ammo_id)
		out["rigging"] = float(out["rigging"]) + Ballistics.damage_to_rigging(wid, ammo_id)
		out["personnel"] = float(out["personnel"]) + Ballistics.damage_to_person(wid, ammo_id, dist)
	out["personnel_losses"] = int(floor(float(out["personnel"]) / 0.55 + 0.5))
	return out


func apply_incoming(res: Dictionary, ship: ShipDynamics = null) -> void:
	"""别人算好的结果落到**我**身上（受击方权威广播回来的那一份）。"""
	_take_hits(res, ship)
	foe_rounds = int(foe_rounds) + 1
	last_incoming = res.duplicate()


func apply_outgoing(res: Dictionary) -> void:
	"""开火方把**受击方权威广播回来**的结果记到自己账上（"对面挨了什么"）。

	单机时它紧跟在 `fire_broadside` 后面（本机既是开火方也是受击方权威）；
	联机时它由收到 `naval` 回执那一下调用。
	"""
	foe_apply(res, str(res.get("ammo", ammo_want)))
	volleys_sent = int(volleys_sent) + 1
	last_outgoing = res.duplicate()


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
		# M13：货舱与弹药区也留在船上（不然打完这一仗账就丢了）
		ship.apply_damage("hold", structure * float(split.get("hold", 0.0)) / hp)
		ship.apply_damage("magazine", structure * float(split.get("magazine", 0.0)) / hp)
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
	if ship != null:
		_roll_ignition(ship)


func _roll_ignition(ship: ShipDynamics) -> void:
	"""挨到那一下之后掷"起火 / 进水"的确定性硬币（docs/22 第 5.4 节的第七处）。

	由**受击方**掷（谁挨打谁说了算）—— 单机时是 `_take_hits` 里这一下，
	联机时是受击方机器上同一个函数。每场只掷一次。
	"""
	var ig: Dictionary = Ballistics.naval().get("ignition", {})
	if ig.is_empty():
		return
	var key := int(floor(t * 10.0))
	if not _fire_rolled and magazine_damage >= float(ig.get("magazine_threshold", 0.25)):
		_fire_rolled = true
		if Ballistics.roll(811, key) < float(ig.get("fire_coin", 0.5)):
			ship.apply_hazard("fire", float(ig.get("fire_start", 0.3)))
			_say("弹药区被打穿 —— 甲板上窜起火苗！")
	if not _flood_rolled and own_hull_damage >= float(ig.get("hull_threshold", 0.45)):
		_flood_rolled = true
		if Ballistics.roll(577, key) < float(ig.get("flood_coin", 0.5)):
			ship.apply_hazard("flood", float(ig.get("flood_start", 0.35)))
			_say("水线下面破了个口子 —— 开始进水！")


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
