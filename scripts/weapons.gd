class_name Weapons
extends RefCounted

# 武器与弹药（M6）：**把火器和货舱接起来的那一层**。
#
# 它只做三件事：
#   1. 给登陆队分武器（谁扛火绳枪、谁抬隼炮、谁只剩一根长矛）；
#   2. 算一发要吃掉货舱里的什么（火药 / 铅弹 / 火绳）；
#   3. 回答"现在还能不能开火"——打光了就是打光了（验收第 4 条的后半句）。
#
# 数值一概不在这里：全部来自 `data/defs/weapons.json`（铁律 12）。

const DEFS_PATH := "res://data/defs/weapons.json"


static func weapon_ids() -> Array:
	var out := []
	for w in Ballistics.defs().get("weapons", []):
		out.append(str(w.get("id", "")))
	return out


static func ammo_cost(weapon_id: String) -> Dictionary:
	var w := Ballistics.weapon(weapon_id)
	var out := {}
	for k in (w.get("ammo", {}) as Dictionary).keys():
		out[str(k)] = float(w["ammo"][k])
	return out


static func can_fire(cargo: Cargo, weapon_id: String) -> bool:
	"""弹药够不够打这一发（弹药是"按发扣"的，不是"有就无限用"）。"""
	if cargo == null:
		return false
	var need := ammo_cost(weapon_id)
	if need.is_empty():
		return true
	for k in need.keys():
		if float(cargo.qty(str(k))) < float(need[k]):
			return false
	return true


static func pay_ammo(cargo: Cargo, weapon_id: String) -> bool:
	"""扣弹药。**小数记账**：火绳枪一发只要 0.04 桶火药，
	按整件扣的话一桶能打出二十五发 —— 那是作弊（和 M4 的水一个道理）。"""
	if cargo == null:
		return false
	var need := ammo_cost(weapon_id)
	for k in need.keys():
		if not cargo.spend_fraction(str(k), float(need[k])):
			return false
	return true


static func loadout_for(members: Array, hand_prefix := "hand") -> Array:
	"""给登陆队分武器：有炮术的扛枪/操炮，其余人拿长矛剑盾。

	分配是**确定性**的（按名单顺序 + 技能阈值），所以同一支队伍每次上岸
	拿到的武器一样 —— 测试要的"同样初始状态 → 同样伤亡名单"从这里开始。
	"""
	var out := []
	var rifles := 4                      # 一个登陆队带得动的火绳枪数量
	var swivels := 1
	var falconets := 1
	var i := 0
	for m in members:
		var gun := float(m.skills.get("gunnery", 0.0))
		var seam := float(m.skills.get("seamanship", 0.0))
		var w := "pike"
		var a := ""
		if falconets > 0 and gun >= 0.45:
			w = "falconet"; a = "round_shot"; falconets -= 1
		elif swivels > 0 and gun >= 0.35:
			w = "swivel"; a = "scatter"; swivels -= 1
		elif rifles > 0 and seam >= 0.3:
			w = "arquebus"; a = "single_ball"; rifles -= 1
		elif i % 3 == 1:
			w = "sword"
		out.append({
			"unit": "%s_%d" % [hand_prefix, i],
			"member_id": str(m.id),
			"name": m.label(),
			"weapon": w,
			"ammo": a,
			"skill": maxf(seam, gun),
		})
		i += 1
	return out


static func describe_loadout(loadout: Array) -> String:
	var count := {}
	for u in loadout:
		var w := str(u["weapon"])
		count[w] = int(count.get(w, 0)) + 1
	var parts := PackedStringArray()
	for k in count.keys():
		parts.append("%s×%d" % [str(Ballistics.weapon(str(k)).get("name", k)), int(count[k])])
	return "、".join(parts)
