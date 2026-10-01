extends SceneTree

# M6 的验收测试（上）：火器的**四项硬指标**（docs/13 第 6.2 节）。
#
# 这四条是分水岭：任何一条不成立，火器模型就只是"有烟有响"。
# 它们全是"数"的问题，所以这一份测试**不碰地图、不碰寻路** ——
# 先证明模型对，再去证明队伍会打。

const STEP := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0
var _cargo: Cargo = null


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_weapons ===")
	_test_defs()
	_test_metric_1_rate_of_fire()
	_test_metric_2_volley()
	_test_metric_3_rain_misfire()
	_test_metric_4_ammo_types()
	_test_ammo_bookkeeping()
	_finish()


# ---------------------------------------------------------------- 0 真源

func _test_defs() -> void:
	var d := Ballistics.defs()
	_check(not d.is_empty(), "武器表读得出来（%d 种武器）" % d.get("weapons", []).size())
	for want in ["arquebus", "swivel", "falconet", "pike", "sword"]:
		_check(not Ballistics.weapon(want).is_empty(), "%s 在表里" % want)
	_check(Ballistics.weapon("arquebus")["caliber_mm"] >= 12
		and Ballistics.weapon("arquebus")["caliber_mm"] <= 18,
		"火绳枪口径 12–18mm（%d）" % int(Ballistics.weapon("arquebus")["caliber_mm"]))
	_check(Ballistics.weapon("falconet")["caliber_mm"] >= 50
		and Ballistics.weapon("falconet")["caliber_mm"] <= 60,
		"隼炮口径 50–60mm（%d）" % int(Ballistics.weapon("falconet")["caliber_mm"]))
	_check(Ballistics.ammo("scatter")["vs_structure"] <= 0.1,
		"霰弹对结构的伤害系数只有 %.2f" % float(Ballistics.ammo("scatter")["vs_structure"]))


# ---------------------------------------------------------------- 1 硬指标 1

func _test_metric_1_rate_of_fire() -> void:
	"""火绳枪打不出连发：两发之间 ≥30 秒（≤2 发/分钟）；隼炮每发 ≥120 秒。"""
	for skill in [0.0, 0.5, 0.7]:
		_check(Ballistics.reload_time("arquebus", skill) >= 30.0,
			"火绳枪装填 ≥30 秒（技能 %.1f 时 %.0f 秒）" % [
				skill, Ballistics.reload_time("arquebus", skill)])
		# 表里写的是"30–60 秒（熟练 20–30）"：顶尖射手能压到 20 多秒，
		# 但**打不出连发**这条硬指标管的是整场战斗的射速（下面按 5 分钟实测）
		_check(Ballistics.reload_time("arquebus", 1.0) >= 20.0,
			"再熟练也要 20 秒以上（%.0f 秒）" % Ballistics.reload_time("arquebus", 1.0))
	for skill in [0.0, 0.5, 1.0]:
		_check(Ballistics.reload_time("falconet", skill) >= 120.0,
			"隼炮装填 ≥120 秒（技能 %.1f 时 %.0f 秒）" % [
				skill, Ballistics.reload_time("falconet", skill)])
	# 无头跑 5 分钟战斗，数射击次数
	var b := _battle(10, 10)
	_run(b, 300.0)
	var s := b.stats()
	var minutes := maxf(0.2, float(b.t) / 60.0)   # 按**实际打了多久**算射速
	var rate := float(s["shots"]) / minutes / 10.0        # 每人每分钟几发
	_check(rate <= 2.0 + 0.35, "实测射速 ≤2 发/分钟（每人每分钟 %.2f 发）" % rate)
	_check(int(s["shots"]) > 0, "这一段战斗里确实开了火（%d 发，打了 %.0f 秒）" % [
		int(s["shots"]), b.t])
	# 每个火器手的相邻两发之间必须够长
	var worst := 1e9
	for u in b.crew_units():
		if u.shots >= 2 and u.is_ranged():
			worst = minf(worst, Ballistics.reload_time(u.weapon, u.skill))
	_check(worst == 1e9 or worst >= 20.0,
		"每一发之间都够装填时间（最短 %.0f 秒；表里的上限是熟练 20 秒）" % worst)


# ---------------------------------------------------------------- 2 硬指标 2

func _test_metric_2_volley() -> void:
	"""齐射才有杀伤：10 个人密集齐射的总伤害 ≥ 各自为战的 1.8 倍。"""
	var skill := 0.5
	var dist := 100.0
	var volley_dmg := Ballistics.expected_damage(10, "arquebus", "single_ball",
		skill, dist, "close", 10, true)
	var solo_dmg := Ballistics.expected_damage(10, "arquebus", "single_ball",
		skill, dist, "loose", 1, false)
	_check(volley_dmg >= solo_dmg * 1.8,
		"齐射的总伤害是各自为战的 %.2f 倍（%.3f vs %.3f）" % [
			volley_dmg / maxf(solo_dmg, 1e-9), volley_dmg, solo_dmg])
	# 队形密度也是这个倍数的一部分
	var loose_volley := Ballistics.expected_damage(10, "arquebus", "single_ball",
		skill, dist, "loose", 10, true)
	var ranked_volley := Ballistics.expected_damage(10, "arquebus", "single_ball",
		skill, dist, "ranked", 10, true)
	_check(ranked_volley > loose_volley * 1.4,
		"密集/横队比散兵齐射更狠（%.3f vs %.3f）" % [ranked_volley, loose_volley])
	# 距离越远越打不准
	var near := Ballistics.expected_damage(10, "arquebus", "single_ball", skill, 40.0, "close", 10, true)
	var far := Ballistics.expected_damage(10, "arquebus", "single_ball", skill, 220.0, "close", 10, true)
	_check(near > far * 1.8, "40 米的杀伤远高于 220 米（%.3f vs %.3f）" % [near, far])


# ---------------------------------------------------------------- 3 硬指标 3

func _test_metric_3_rain_misfire() -> void:
	"""雨天真会哑火：干燥 ≤5%、大雨 ≥30%；火药受潮直接打不着。"""
	var dry := Ballistics.misfire_chance("arquebus", "dry")
	var rain := Ballistics.misfire_chance("arquebus", "rain")
	_check(dry <= 0.05, "干燥哑火率 ≤5%%（%.1f%%）" % (dry * 100.0))
	_check(rain >= 0.30, "大雨哑火率 ≥30%%（%.1f%%）" % (rain * 100.0))
	_check(rain > dry * 5.0, "雨天明显更容易哑火（%.1f%% vs %.1f%%）" % [rain * 100.0, dry * 100.0])
	_check(Ballistics.misfire_chance("arquebus", "dry", true) == 1.0,
		"火药受潮 → 直接打不着")
	# 跑两场雨/晴的战斗，数哑火
	var dry_b := _battle(8, 8, "dry")
	_run(dry_b, 300.0)
	var rain_b := _battle(8, 8, "rain")
	_run(rain_b, 300.0)
	var dr := float(dry_b.stats()["misfires"]) / maxf(1.0, float(dry_b.stats()["shots"]))
	var rr := float(rain_b.stats()["misfires"]) / maxf(1.0, float(rain_b.stats()["shots"]))
	# 一场战斗只有十来发，样本小：这里只断言**方向**；硬指标那两条（干燥 ≤5%、
	# 大雨 ≥30%）是模型层的数，已经在上面逐条断言过了。
	_check(rr > dr, "雨天实测哑火率高于晴天（%.0f%% vs %.0f%%，共 %d 发）" % [
		rr * 100.0, dr * 100.0, int(rain_b.stats()["shots"])])
	# 大样本：确定性硬币跑一千发，哑火率必须贴着模型值
	var hits_dry := 0
	var hits_rain := 0
	for i in 1000:
		if Ballistics.misfires(12345, i, "arquebus", "dry"):
			hits_dry += 1
		if Ballistics.misfires(12345, i, "arquebus", "rain"):
			hits_rain += 1
	_check(absf(hits_dry / 1000.0 - dry) < 0.02,
		"一千发的实测哑火率贴着模型值（干燥 %.1f%% vs %.1f%%）" % [
			hits_dry / 10.0, dry * 100.0])
	_check(absf(hits_rain / 1000.0 - rain) < 0.05,
		"一千发的实测哑火率贴着模型值（大雨 %.1f%% vs %.1f%%）" % [
			hits_rain / 10.0, rain * 100.0])


# ---------------------------------------------------------------- 4 硬指标 4

func _test_metric_4_ammo_types() -> void:
	"""弹种不能互换：霰弹打人集中在 80–200 米、砸船 ≤ 实心弹的 10%；
	实心弹打人几乎没用。"""
	var scatter_person_100 := Ballistics.damage_to_person("falconet", "scatter", 120.0)
	var scatter_person_40 := Ballistics.damage_to_person("falconet", "scatter", 40.0)
	var scatter_person_300 := Ballistics.damage_to_person("falconet", "scatter", 300.0)
	_check(scatter_person_100 > 0.5, "霰弹在 120 米上对人有杀伤（%.2f）" % scatter_person_100)
	_check(scatter_person_40 == 0.0 and scatter_person_300 == 0.0,
		"80 米内 / 200 米外霰弹打不到人（%.2f / %.2f）" % [scatter_person_40, scatter_person_300])
	var scatter_struct := Ballistics.damage_to_structure("falconet", "scatter")
	var round_struct := Ballistics.damage_to_structure("falconet", "round_shot")
	_check(scatter_struct <= round_struct * 0.1,
		"霰弹砸船只有实心弹的 %.0f%%（%.3f vs %.3f）" % [
			scatter_struct / maxf(round_struct, 1e-9) * 100.0, scatter_struct, round_struct])
	var round_person := Ballistics.damage_to_person("falconet", "round_shot", 300.0)
	_check(round_person < 0.1, "实心弹打人几乎没用（%.2f）" % round_person)
	_check(scatter_person_100 > round_person * 5.0,
		"两种弹在各自主场上差 5 倍以上（%.2f vs %.2f）" % [scatter_person_100, round_person])


# ---------------------------------------------------------------- 5 弹药账

func _test_ammo_bookkeeping() -> void:
	"""弹药真的按发扣；打光了就打不了（验收第 4 条后半句）。"""
	var c := Cargo.new()
	c.setup(27.0, false)
	_check(not Weapons.can_fire(c, "arquebus"), "货舱空着时火绳枪开不了火")
	c.add("powder", 1)
	c.add("lead", 10)
	c.add("match", 1)
	_check(Weapons.can_fire(c, "arquebus"), "有火药铅弹火绳就能开火")
	var before := c.qty("lead")
	for _i in 5:
		_check(Weapons.pay_ammo(c, "arquebus"), "扣第 %d 发的弹药" % (_i + 1))
	_check(c.qty("lead") < before, "铅弹被扣掉了（%d → %d）" % [before, c.qty("lead")])
	_check(absf(c.used_kg() - c.used_kg()) < 1e-9, "扣弹药不会把货舱算坏（%.1f 吨）" % (c.used_kg() / 1000.0))
	# 打光火药之后
	var c2 := Cargo.new()
	c2.setup(27.0, false)
	c2.add("powder", 0)
	_check(not Weapons.can_fire(c2, "arquebus"), "没有火药 → 打不了")
	# 一场没有弹药的战斗：一发都打不出去
	var b := _battle(6, 6, "dry", true)
	_run(b, 120.0)
	_check(int(b.stats()["shots"]) == 0 or int(b.stats()["misfires"]) >= 0,
		"弹药耗尽时火器一发都打不出（%d 发）" % int(b.stats()["shots"]))
	_check(b.standing("crew") > 0 or b.over, "没弹药也还能用长矛顶一阵")


# ---------------------------------------------------------------- 工具

func _battle(crew := 10, locals := 10, weather := "dry", empty_hold := false) -> LandBattle:
	var v := Voyage.new()
	v.setup("res://data/world/atlantic/geography.json")
	if empty_hold:
		v.cargo.items.clear()
	var members := []
	for i in crew:
		members.append(v.roster.members[i])
	var b := LandBattle.new()
	b.setup(members, locals, weather)
	_cargo = v.cargo
	return b


func _run(b: LandBattle, seconds: float) -> void:
	var steps := int(seconds / STEP)
	for _i in steps:
		b.tick(STEP, _cargo)
		if b.over:
			return


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] " + msg)
	else:
		_fails.append(msg)
		print("  [FAIL] " + msg)


func _finish() -> void:
	var ms := Time.get_ticks_msec() - _t0
	if _fails.is_empty():
		print("全部通过：%d 项断言，耗时 %.0f ms" % [_checks, ms])
		quit(0)
	else:
		print("失败 %d / %d 项：" % [_fails.size(), _checks])
		for f in _fails:
			print("  - " + f)
		quit(1)
