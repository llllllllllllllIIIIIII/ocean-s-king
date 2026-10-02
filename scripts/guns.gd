class_name Guns
extends RefCounted

# 炮组（M10）：一门炮 + 一个炮组（2–4 人）。
#
# 三条设计（docs/22 第 10.2 节）：
#   1. **单位是炮，不是"船有一根血条"**：每门炮自己装填（分钟级），
#      炮组人数与技能决定装填快慢；打出去多少发是有数的。
#   2. **确定性**：命中走 `Ballistics` 的查表，(炮位, 第几发) 的哈希当硬币 ——
#      同样的初始状态必得同样的伤亡与损伤（无头可测、联机可复现、逐发可复盘）。
#   3. **数值一概不在这里**：炮与弹的口径、装填、射程、命中、伤害分摊
#      全部来自 `data/defs/weapons.json`（铁律 12）。
#
# 这一层不认识船、不认识地图：它只管"这一轮舷侧能打出什么"。
# 把结果落到船的哪几处（七处损伤）是 `NavalBattle` 的事。
#
# 开打时炮是**装好的**（真的船进战斗前先把炮装好）—— 所以第一轮舷侧立刻能打，
# 之后的每一发才要等那两三分半钟。

var guns: Array = []              # [{slot, id, crew, reload_t}]
var weather_id := "dry"
var powder_wet := false
var crew_skill := 0.5             # 炮组的技能（由调用方每帧灌进来）
var shots_fired := 0              # 整场打出去多少发（统计用）
var misfires := 0
# M13：弹药区损伤（0..1）。它不炸（那是起火那条链的事），但它让火药取不出来 ——
# 最后几门炮哑着。数值落地在 `ShipDynamics.damage.magazine`，这里只读。
var magazine_damage := 0.0


func setup_default() -> void:
	"""按真源摆一排炮：一侧的 `guns_per_side`。"""
	var list := []
	for g in Ballistics.naval_guns():
		var w := Ballistics.weapon(str(g["id"]))
		for _i in range(int(g["count"])):
			list.append({"id": str(g["id"]), "crew": int(w.get("gun_crew", w.get("crew", 3)))})
	setup(list)


func setup(list: Array) -> void:
	guns.clear()
	for i in list.size():
		var g: Dictionary = list[i]
		guns.append({
			"slot": i,
			"id": str(g.get("id", "culverin")),
			"crew": int(g.get("crew", 3)),
			"reload_t": 0.0,
			"loaded": true,
		})
	shots_fired = 0
	misfires = 0


func tick(dt: float, skill: float) -> void:
	crew_skill = clampf(skill, 0.0, 1.0)
	for g in guns:
		g["reload_t"] = float(g["reload_t"]) + dt


func reload_time_of(g: Dictionary) -> float:
	"""炮组人数与技能决定装填：人数不足按比例变慢（一个人推不动一门长炮）。"""
	var w := Ballistics.weapon(str(g["id"]))
	if w.is_empty():
		return 999.0
	var base := float(w.get("reload_s", 300.0))
	var skilled := float(w.get("reload_skilled_s", base))
	var t := base + (skilled - base) * crew_skill
	var need := maxi(1, int(w.get("gun_crew", 3)))
	var have := maxi(1, int(g["crew"]))
	if have < need:
		t *= float(need) / float(have)
	return t


func ready_guns() -> Array:
	var out := []
	for g in guns:
		if bool(g.get("loaded", false)) or float(g["reload_t"]) >= reload_time_of(g):
			out.append(g)
	# M13：弹药区被打坏 → 末端几门炮取不到药，这一轮哑着（docs/22 第 5.4 节）
	if magazine_damage > 0.001 and not out.is_empty():
		var blocked := int(floor(float(out.size()) * magazine_damage))
		if blocked > 0:
			out = out.slice(0, maxi(0, out.size() - blocked))
	return out


func ready_count() -> int:
	return ready_guns().size()


func gun_count() -> int:
	return guns.size()


func ammo_types_of(g: Dictionary) -> Array:
	return Ballistics.weapon(str(g["id"])).get("ammo_types", [])


func pick_ammo(g: Dictionary, want: String, cargo: Cargo) -> String:
	"""这一门炮这次打什么弹：玩家点的那个；打不了就退到它能打的。"""
	var types := ammo_types_of(g)
	if types.has(want) and Weapons.can_fire(cargo, str(g["id"])) and _ammo_ok(str(want)):
		return want
	for t in types:
		if Weapons.can_fire(cargo, str(g["id"])) and _ammo_ok(str(t)):
			return str(t)
	return ""


func _ammo_ok(_ammo_id: String) -> bool:
	# 目前只有一种发射药与弹重（真源里的 ammo 是"一门炮一发"的账）；
	# 弹种只改打什么，不改消耗 —— 留给以后的细化一个口子。
	return true


# ------------------------------------------------------------ 开火

func fire_broadside(distance_m: float, ammo_id: String, cargo: Cargo, skill: float,
		broadside := true, closing := true, powder_available := true) -> Dictionary:
	"""打一轮：**所有装填好的炮**一起打（或者各自为战）。

	返回一份结算：几发、几中、哑火几发、以及打出来的三类伤害
	（structure / rigging / personnel）。具体落到船的哪几处由调用方按
	`naval.damage_split` 分摊 —— 这一层不认识"船壳"这些名字。
	"""
	var out := {
		"shots": 0, "hits": 0, "misfires": 0,
		"structure": 0.0, "rigging": 0.0, "personnel": 0.0,
		"ammo": {}, "guns": [],
	}
	if cargo == null or ammo_id == "":
		return out
	crew_skill = clampf(skill, 0.0, 1.0)
	var ready := ready_guns()
	if ready.is_empty():
		return out
	var guns_n := ready.size()
	for g in ready:
		var wid := str(g["id"])
		var p := Ballistics.naval_hit_chance(wid, skill, distance_m, guns_n,
			broadside, closing)
		# 火药受潮：这一发打不着，但弹药不消耗（湿药不能用），炮组白忙一轮
		if powder_wet or not powder_available:
			out["misfires"] = int(out["misfires"]) + 1
			misfires += 1
			g["loaded"] = false
			g["reload_t"] = 0.0
			continue
		# 先看能不能打、再扣弹药，然后才算这一发 ——
		# ⚠️ 必须用 `Weapons.can_fire` 先挡一道：`Cargo.spend_fraction` 对**不足一件**的
		#    数量只累加小数、不看库存（0 库存也会返回 true），只靠它会把"打光了"放过。
		#    陆战那边也是同样的挡法。
		if not Weapons.can_fire(cargo, wid) or not Weapons.pay_ammo(cargo, wid):
			out["exhausted"] = true
			break
		g["loaded"] = false
		# 每一发都是确定性硬币：(炮位, 全局第几发)
		var idx := shots_fired
		shots_fired += 1
		out["shots"] = int(out["shots"]) + 1
		if Ballistics.misfires(int(g["slot"]) * 97 + 7, idx, wid, weather_id, powder_wet):
			out["misfires"] = int(out["misfires"]) + 1
			misfires += 1
			g["reload_t"] = 0.0
			continue
		for k in Weapons.ammo_cost(wid).keys():
			out["ammo"][k] = float(out["ammo"].get(k, 0.0)) + float(Weapons.ammo_cost(wid)[k])
		g["reload_t"] = 0.0
		var hit := Ballistics.roll(int(g["slot"]) * 31 + 3, idx) < p
		if not hit:
			continue
		out["hits"] = int(out["hits"]) + 1
		out["structure"] = float(out["structure"]) \
			+ Ballistics.damage_to_structure(wid, ammo_id)
		out["rigging"] = float(out["rigging"]) \
			+ Ballistics.damage_to_rigging(wid, ammo_id)
		out["personnel"] = float(out["personnel"]) \
			+ Ballistics.damage_to_person(wid, ammo_id, distance_m)
		(out["guns"] as Array).append(int(g["slot"]))
	return out


# ------------------------------------------------------------ 存档契约

func capture_state() -> Dictionary:
	"""只有"会变的值"：每一门炮装到哪儿了。炮的种类与人数是静态的（来自真源）。"""
	var out := []
	for g in guns:
		out.append({
			"id": str(g["id"]), "crew": int(g["crew"]),
			"reload_t": float(g["reload_t"]), "loaded": bool(g.get("loaded", false)),
		})
	return {
		"guns": out,
		"weather_id": weather_id,
		"powder_wet": powder_wet,
		"shots_fired": shots_fired,
		"misfires": misfires,
		"magazine_damage": magazine_damage,
	}


func apply_state(d: Dictionary) -> void:
	var raw: Array = d.get("guns", [])
	guns.clear()
	for i in raw.size():
		var g: Dictionary = raw[i]
		guns.append({
			"slot": i,
			"id": str(g.get("id", "culverin")),
			"crew": int(g.get("crew", 3)),
			"reload_t": float(g.get("reload_t", 0.0)),
			"loaded": bool(g.get("loaded", true)),
		})
	weather_id = str(d.get("weather_id", "dry"))
	powder_wet = bool(d.get("powder_wet", false))
	shots_fired = int(d.get("shots_fired", 0))
	misfires = int(d.get("misfires", 0))
	magazine_damage = clampf(float(d.get("magazine_damage", 0.0)), 0.0, 1.0)


func describe() -> String:
	var ready := ready_guns().size()
	return "%d 门炮（装好 %d）" % [guns.size(), ready]
