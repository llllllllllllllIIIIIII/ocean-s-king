extends SceneTree

# M6 的验收测试（下）：一场遭遇能不能**完整复现**、近战有没有用、死亡有没有被记住。
#
# 三条验收（docs/13 M6 卡片）：
#   2. 10 对 10 的遭遇在无头下能完整复现（同样的初始状态 → 同样的伤亡名单）
#   3. 只带火枪不带近战的人，会被冲上来打死（近战必须有用）
#   5. 死亡真的发生并且被记录（航海日志 + 结算的"船员成果"）
# （第 1、4 条在 tests/test_weapons.gd：四项硬指标与弹药账。）

const STEP := 0.5
const GEO := "res://data/world/atlantic/geography.json"

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_land_battle ===")
	_test_units_and_loadout()
	_test_reproducible()
	_test_melee_matters()
	_test_rain_and_ammo()
	_test_deaths_are_recorded()
	_test_culture()
	_test_village_encounter_is_wired()
	_test_save()
	_finish()


func _voyage() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	return v


func _battle(v: Voyage, crew := 10, locals := 10, weather := "dry") -> LandBattle:
	var members := []
	for i in crew:
		members.append(v.roster.members[i])
	var b := LandBattle.new()
	b.setup(members, locals, weather)
	return b


func _run(b: LandBattle, cargo: Cargo, seconds: float) -> void:
	var steps := int(seconds / STEP)
	for _i in steps:
		b.tick(STEP, cargo)
		if b.over:
			return


func _signature(b: LandBattle) -> String:
	var parts := PackedStringArray()
	for u in b.units:
		parts.append("%s:%s:%.4f:%.2f:%d:%d" % [
			u.id, u.state, u.health, u.morale, u.shots, u.hits])
	return "|".join(parts)


# ---------------------------------------------------------------- 1 单位与装备

func _test_units_and_loadout() -> void:
	var v := _voyage()
	var b := _battle(v, 10, 10)
	_check(b.crew_units().size() == 10 and b.locals_units().size() == 10,
		"10 对 10：两队各 10 个独立单位（%d / %d）" % [b.crew_units().size(), b.locals_units().size()])
	var ranged := 0
	var melee := 0
	for u in b.crew_units():
		if u.is_ranged():
			ranged += 1
		else:
			melee += 1
	_check(ranged >= 3 and melee >= 2,
		"登陆队既有火器也有近战（火器 %d 人 / 近战 %d 人）" % [ranged, melee])
	_check(str(b.crew_units()[0].member_id) != "", "每个单位都对着名册里的一个人")
	var dup := {}
	var clash := 0
	for u in b.units:
		if dup.has(u.id):
			clash += 1
		dup[u.id] = true
	_check(clash == 0, "单位 id 不重复（%d 个）" % b.units.size())


# ---------------------------------------------------------------- 2 复现（验收 2）

func _test_reproducible() -> void:
	var v1 := _voyage()
	var v2 := _voyage()
	var b1 := _battle(v1, 10, 10)
	var b2 := _battle(v2, 10, 10)
	_run(b1, v1.cargo, 240.0)
	_run(b2, v2.cargo, 240.0)
	_check(_signature(b1) == _signature(b2),
		"同样的初始状态 → 逐单位的状态与伤亡完全一样（%d 个单位、打了 %.0f 秒）" % [
			b1.units.size(), b1.t])
	_check(str(b1.casualties()) == str(b2.casualties()),
		"伤亡名单一致（船员倒 %d / 当地人倒 %d）" % [
			int(b1.stats()["crew_down"]), int(b1.stats()["locals_down"])])
	_check(str(b1.stats()) == str(b2.stats()), "统计一致（%s）" % str(b1.stats()))
	var v3 := _voyage()
	var b3 := _battle(v3, 10, 10, "rain")
	_run(b3, v3.cargo, 240.0)
	_check(int(b3.stats()["misfires"]) >= int(b1.stats()["misfires"]),
		"雨天哑火不会比晴天少（%d vs %d 次）" % [
			int(b3.stats()["misfires"]), int(b1.stats()["misfires"])])


# ---------------------------------------------------------------- 3 近战（验收 3）

func _test_melee_matters() -> void:
	"""只带火枪不带近战：装填的那一分多钟里没人挡得住冲上来的人。"""
	var v1 := _voyage()
	var all_guns := _battle(v1, 10, 10)
	for u in all_guns.crew_units():
		u.weapon = "arquebus"
		u.ammo = "single_ball"
	_run(all_guns, v1.cargo, 300.0)

	var v2 := _voyage()
	var with_pikes := _battle(v2, 10, 10)
	_run(with_pikes, v2.cargo, 300.0)

	var guns_down := int(all_guns.stats()["crew_down"]) + int(all_guns.stats()["crew_dead"])
	var pikes_down := int(with_pikes.stats()["crew_down"]) + int(with_pikes.stats()["crew_dead"])
	_check(guns_down > pikes_down,
		"只带火枪的伤亡更重（倒 %d vs 带长矛的 %d）" % [guns_down, pikes_down])
	_check(guns_down >= 3, "只带火枪的队伍真的被冲垮了（倒 %d 人／10 人）" % guns_down)
	_check(all_guns.standing("crew") < 10, "火枪队站不住（还剩 %d 人）" % all_guns.standing("crew"))
	var swings := 0
	for u in with_pikes.crew_units():
		if not u.is_ranged():
			swings += u.shots
	_check(swings > 0, "带长矛/剑的人真的近战了（挥了 %d 下）" % swings)


# ---------------------------------------------------------------- 4 雨天与弹药

func _test_rain_and_ammo() -> void:
	var v1 := _voyage()
	var dry := _battle(v1, 8, 8, "dry")
	_run(dry, v1.cargo, 240.0)
	var v2 := _voyage()
	var rain := _battle(v2, 8, 8, "rain")
	_run(rain, v2.cargo, 240.0)
	var dry_bad := float(dry.stats()["misfires"]) / maxf(1.0, float(dry.stats()["shots"]))
	var rain_bad := float(rain.stats()["misfires"]) / maxf(1.0, float(rain.stats()["shots"]))
	_check(rain_bad > dry_bad, "雨天的哑火率更高（%.0f%% vs %.0f%%）" % [
		rain_bad * 100.0, dry_bad * 100.0])
	var v3 := _voyage()
	v3.cargo.remove("powder", v3.cargo.qty("powder"))
	v3.cargo.remove("lead", v3.cargo.qty("lead"))
	v3.cargo.remove("match", v3.cargo.qty("match"))
	var empty := _battle(v3, 10, 10)
	_run(empty, v3.cargo, 240.0)
	_check(int(empty.stats()["shots"]) == 0,
		"火药铅弹打光 → 一发都没打出去（%d 发）" % int(empty.stats()["shots"]))


# ---------------------------------------------------------------- 5 死亡（验收 5）

func _test_deaths_are_recorded() -> void:
	var v := _voyage()
	v.ship.set_pose(v.sea.poi_pos("beach") + Vector2(-200.0, 0.0), 0.0)
	v.orders.anchored = true
	var ids := []
	for m in v.roster.key_crew():
		if m.post != "外科医生":
			ids.append(m.id)
	v.fired.erase("landed")
	var msg := v.land(ids, 6)
	_check(v.ashore, "带人上岸了（%s）" % msg)
	var r := v.begin_land_battle(12)
	_check(bool(r.get("ok", false)), "打起来了（%s）" % str(r))
	var guard := 0
	while v.battle != null and not v.battle.over and guard < 4000:
		v.tick(STEP)
		guard += 1
	_check(v.battle.over, "打完收工（第 %.0f 秒，%s）" % [v.battle.t, v.battle.outcome])
	var dead := 0
	for m in v.roster.members:
		if m.dead:
			dead += 1
	_check(dead > 0, "真的死了人（%d 人）" % dead)
	_check(int(v.ending_score["crew"]) < 0,
		"死亡计入了结算的「船员成果」（%d）" % int(v.ending_score["crew"]))
	var obituary := ""
	for line in v.journal.entries:
		if str(line.get("kind", "")) == "death":
			obituary = str(line.get("text", ""))
	_check(obituary != "", "航海日志里留了讣告（%s）" % obituary)
	_check(v.log_lines.size() > 0 and str(v.log_lines[-1]).find("打完了") >= 0,
		"消息条上写了这一仗的结果（%s）" % str(v.log_lines[-1]))
	var still_working := 0
	for m in v.roster.members:
		if m.dead and m.job != "dead":
			still_working += 1
	_check(still_working == 0, "阵亡的人不再担任任何岗位")


# ---------------------------------------------------------------- 6 当地文明

func _test_culture() -> void:
	var v := _voyage()
	_check(v.culture.stance_name("green_cape") == "中立",
		"开局时绿岬岛是中立（%s）" % v.culture.describe("green_cape"))
	_check(not v.culture.will_fight("green_cape"), "中立不会主动打你")
	v.culture.react("green_cape", "trade")
	v.culture.react("green_cape", "trade")
	_check(v.culture.stance_name("green_cape") == "友善",
		"做过两回交易就友善了（%s）" % v.culture.describe("green_cape"))
	v.culture.react("green_cape", "kidnap")
	_check(v.culture.stance_name("green_cape") != "友善",
		"抓人当向导会立刻翻脸（%s）" % v.culture.describe("green_cape"))
	v.culture.react("green_cape", "fire")
	v.culture.react("green_cape", "fire")
	_check(v.culture.stance_name("green_cape") == "敌对" and v.culture.will_fight("green_cape"),
		"开火之后就是敌对，上岸就会打起来（%s）" % v.culture.describe("green_cape"))


# ---------------------------------------------------------------- 7 存档

func _test_village_encounter_is_wired() -> void:
	"""**上岸到底会不会打起来** —— 这一条量的是"接线"，不是"数值"。

	踩过的坑：`culture` 的态度、`begin_land_battle()`、HUD 上那句"上岸就可能打起来"
	全都写好了、也有断言，但**没有任何地方在游戏里开过一场仗**（`begin_land_battle()`
	只在截图脚本里被调用）—— 于是"陆战与火器"这一期在正常玩法里根本摸不到，
	连 M7 那条因果链的第一环都开不了头。所以这里从"上岸"一路演到"真的打起来"。
	"""
	var v := _voyage()
	v.ship.set_pose(v.sea.poi_pos("beach") + Vector2(-200.0, 0.0), 0.0)
	v.orders.anchored = true
	var ids := []
	for m in v.roster.key_crew():
		ids.append(m.id)
	v.land(ids, 6)
	_check(v.ashore, "带人上岸了")
	var shot := v.shoot_warning()
	_check(shot.find("枪声") >= 0, "岸上可以开枪示警（%s）" % shot.substr(0, 18))
	_check(v.culture.attitude("green_cape") < 0.0, "开一枪态度就掉（%+.2f）" % v.culture.attitude("green_cape"))
	v.shoot_warning()
	_check(v.culture.will_fight("green_cape"),
		"两枪之后他们翻脸（%s）" % v.culture.describe("green_cape"))

	# 走进村子 → 他们先动手
	v.move_party_to(v.sea.poi_pos("village"))
	var guard := 0
	while v.battle == null and guard < 2000:
		v.tick(STEP)
		guard += 1
	_check(v.battle != null, "踏进村子就被围上来（第 %d 步）" % guard)
	if v.battle == null:
		return
	_check(v.battle.units.size() > 0, "场上真的有两队人（%d 个单位）" % v.battle.units.size())
	_check(str(v.journal.decisions[-1]).find("先动手") >= 0 or
		str(v.log_lines[-1]).find("围上来") >= 0, "航海日志/消息条记了这件事")
	# 只伏击一次：打完还站在村里也不会凭空再开一场
	var first := v.battle
	guard = 0
	while v.battle != null and not v.battle.over and guard < 6000:
		v.tick(STEP)
		guard += 1
	_check(v.battle.over, "这一仗打完了（%s）" % v.battle.outcome)
	for _i in 60:
		v.tick(STEP)
	_check(v.battle == first, "打完不会被反复伏击（还是同一场）")

	# 中立的一方：走到村子是"和平接触"，不会凭空开打，而且态度 +0.05
	var w := _voyage()
	w.ship.set_pose(w.sea.poi_pos("beach") + Vector2(-200.0, 0.0), 0.0)
	w.orders.anchored = true
	w.land(ids, 6)
	var before := w.culture.attitude("green_cape")
	w.move_party_to(w.sea.poi_pos("village"))
	for _i in 400:                      # 队伍要真的走到村子（滩头→村子约 1.7 km）
		w.tick(STEP)
	_check(w.battle == null, "中立时走到村子不会开打")
	_check(w.culture.attitude("green_cape") > before,
		"和平接触让态度涨一点（%+.2f → %+.2f）" % [before, w.culture.attitude("green_cape")])


# ---------------------------------------------------------------- 7 存档

func _test_save() -> void:
	var a := _voyage()
	a.culture.react("green_cape", "trade")
	var b := Voyage.new()
	b.setup(GEO)
	b.apply_world_state(a.capture_world_state())
	b.apply_ship_state(a.capture_ship_state())
	_check(absf(b.culture.attitude("green_cape") - a.culture.attitude("green_cape")) < 1e-9,
		"读档后当地人的态度一致（%+.2f）" % b.culture.attitude("green_cape"))


# ---------------------------------------------------------------- 断言框架

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
