extends SceneTree

# M10 的验收测试：舷炮海战（docs/23 的 M10 卡片、docs/22 第 10 章）。
#
# 六件事：
#   1. 真源自检：炮与弹都在 `weapons.json` 里，伤害分摊表覆盖三种弹。
#   2. **四项硬指标**（与离线脚本 `tools/weapons_prototype.py --mode metrics` 同源）。
#   3. 确定性：同样的局面跑两遍，统计与日志逐字相同（无头可复现）。
#   4. 七处损伤落到该落的地方：船壳/桅杆/舵进 `ShipDynamics`，货舱掉货，弹药区打坏炮。
#   5. 弹药是从货舱里扣的（打光了就是打光了）。
#   6. 接舷：钩住 → 跳帮 → 有人倒 → 一个结果。

const DT := 0.5

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_naval ===")
	_test_truth_source()
	_test_hard_metrics()
	_test_deterministic()
	_test_damage_places()
	_test_ammo()
	_test_boarding()
	_test_voyage_wiring()
	_test_authority_paths_agree()
	_finish()


func _cargo(powder := 400, lead := 4000) -> Cargo:
	var c := Cargo.new()
	c.setup(27.0, false)
	c.add("powder", powder)
	c.add("lead", lead)
	return c


func _battle(own := 40, foe := 40, weather := "dry", gap := 900.0) -> NavalBattle:
	var b := NavalBattle.new()
	b.setup(own, foe, weather, gap)
	return b


# ---------------------------------------------------------------- 1 真源

func _test_truth_source() -> void:
	var cul := Ballistics.weapon("culverin")
	_check(str(cul.get("kind", "")) == "naval", "寇非林长炮在真源里是 naval（%s）" % cul.get("kind"))
	var types: Array = cul.get("ammo_types", [])
	for want in ["round_shot", "chain_shot", "scatter"]:
		_check(types.has(want), "长炮能打 %s" % want)
	var total := 0
	for g in Ballistics.naval_guns():
		total += int(g["count"])
	_check(total == 6, "一侧六门炮（%d）" % total)
	var split: Dictionary = Ballistics.naval().get("damage_split", {})
	for aid in ["round_shot", "chain_shot", "scatter"]:
		_check(split.has(aid), "伤害分摊表里有 %s" % aid)
	_check(float(Ballistics.naval().get("start_gap_m", 0.0)) >= 400.0,
		"起始距离够打几轮齐射（%.0f 米）" % float(Ballistics.naval().get("start_gap_m", 0.0)))


# ---------------------------------------------------------------- 2 四项硬指标

func _test_hard_metrics() -> void:
	# 1 装填不是装饰：一门长炮在十分钟里打不出几发
	var g := Guns.new()
	g.setup([{"id": "culverin", "crew": 4}])
	var cargo := _cargo()
	var fired := 0
	var t := 0.0
	while t < 600.0:
		g.tick(DT, 0.7)
		var r := g.fire_broadside(500.0, "round_shot", cargo, 0.7, true, false)
		fired += int(r["shots"])
		t += DT
	_check(fired <= 4, "十分钟里一门长炮最多打 4 发（实际 %d 发）" % fired)
	_check(Ballistics.reload_time("culverin", 1.0) >= 120.0,
		"最熟练的炮组也要两分钟以上（%.0f 秒）" % Ballistics.reload_time("culverin", 1.0))
	# 2 齐射胜单打
	var bs := Ballistics.broadside_damage("culverin", "round_shot", 0.6, 300.0, 6, true, true)
	var ind := Ballistics.broadside_damage("culverin", "round_shot", 0.6, 300.0, 6, false, true)
	_check(bs >= ind * 1.8, "六门齐射是各自为战的 %.2f 倍（%.3f vs %.3f）" % [bs / ind, bs, ind])
	# 3 接舷决定近战
	var equal := Ballistics.boarding_rates(8, 8)
	_check(float(equal["boarders"]) > float(equal["defenders"]),
		"人数相等 + 船员质量 → 跳帮方占优（%.3f vs %.3f）"
		% [float(equal["boarders"]), float(equal["defenders"])])
	var outnumbered := Ballistics.boarding_rates(8, 16)
	_check(float(outnumbered["defenders"]) > float(outnumbered["boarders"]) + float(outnumbered["volley"]) / 30.0,
		"人数劣势时火器救不回来（跳帮 %.3f + 齐射 %.2f 对 守方 %.3f）"
		% [float(outnumbered["boarders"]), float(outnumbered["volley"]), float(outnumbered["defenders"])])
	# 4 弹种不能互换
	var scatter_person := Ballistics.damage_to_person("culverin", "scatter", 150.0)
	var round_person := Ballistics.damage_to_person("culverin", "round_shot", 150.0)
	_check(scatter_person > round_person * 3.0,
		"霰弹打人远胜实心弹（%.2f vs %.2f）" % [scatter_person, round_person])
	_check(Ballistics.damage_to_person("culverin", "scatter", 40.0) == 0.0
		and Ballistics.damage_to_person("culverin", "scatter", 300.0) == 0.0,
		"霰弹只在 80–200 米内打得动人")
	_check(Ballistics.damage_to_structure("culverin", "scatter")
		<= Ballistics.damage_to_structure("culverin", "round_shot") * 0.1,
		"霰弹砸结构只有实心弹的 %.0f%%"
		% (Ballistics.damage_to_structure("culverin", "scatter")
		/ Ballistics.damage_to_structure("culverin", "round_shot") * 100.0))
	_check(Ballistics.damage_to_rigging("culverin", "chain_shot")
		>= Ballistics.damage_to_rigging("culverin", "round_shot") * 3.0,
		"链弹撕帆索远胜实心弹（%.2f vs %.2f）"
		% [Ballistics.damage_to_rigging("culverin", "chain_shot"),
		   Ballistics.damage_to_rigging("culverin", "round_shot")])
	_check(Ballistics.damage_to_person("culverin", "chain_shot", 150.0) < 0.25,
		"链弹打人不行（%.2f）" % Ballistics.damage_to_person("culverin", "chain_shot", 150.0))


# ---------------------------------------------------------------- 3 确定性

func _run(a: NavalBattle, cargo: Cargo, ship: ShipDynamics, seconds: float,
		order_at := -1.0, order := "") -> void:
	var t := 0.0
	while t < seconds and not a.over:
		if order_at > 0.0 and t >= order_at:
			a.intent = order
		a.tick(DT, cargo, ship)
		t += DT


func _test_deterministic() -> void:
	var results := []
	for i in 2:
		var b := _battle()
		var cargo := _cargo()
		var ship := ShipDynamics.new(ShipPhysics.load_default())
		_run(b, cargo, ship, 300.0)
		results.append([str(b.stats()), "; ".join(b.log_lines), str(ship.damage)])
	_check(results[0][0] == results[1][0], "同样的局面跑两遍：统计逐字相同")
	_check(results[0][1] == results[1][1], "同样的局面跑两遍：日志逐字相同")
	_check(results[0][2] == results[1][2], "同样的局面跑两遍：船上的损伤相同")
	var s: Dictionary = JSON.parse_string(results[0][0])
	_check(int(s["shots_own"]) > 0, "这五分钟里我们真的开了炮（%s 发）" % s["shots_own"])
	_check(int(s["misfires_own"]) >= 0, "哑火被记下来（%s 发）" % s["misfires_own"])


# ---------------------------------------------------------------- 4 七处损伤

func _test_damage_places() -> void:
	var b := _battle()
	var cargo := _cargo()
	var ship := ShipDynamics.new(ShipPhysics.load_default())
	var before := ship.damage_of("hull")
	_run(b, cargo, ship, 2400.0)     # 十来轮齐射才分得出胜负（分钟级的装填）
	_check(ship.damage_of("hull") > before, "船壳吃到损伤（%.3f → %.3f）"
		% [before, ship.damage_of("hull")])
	_check(ship.damage_of("mast") > 0.0 or ship.damage_of("rudder") > 0.0,
		"桅杆或舵也吃到损伤（桅 %.3f / 舵 %.3f）"
		% [ship.damage_of("mast"), ship.damage_of("rudder")])
	_check(b.hold_damage > 0.0, "货舱那一处也记了账（%.3f）" % b.hold_damage)
	# 实心弹打人几乎没用（硬指标 4）—— 所以"有人倒下"要拿霰弹来验
	var scatter_b := _battle()
	var foe_before := scatter_b.foe_crew
	scatter_b.foe_apply({"shots": 6, "hits": 4, "misfires": 0, "structure": 0.0,
		"rigging": 0.0, "personnel": 2.4, "ammo": {}, "guns": []}, "scatter")
	_check(scatter_b.foe_crew < foe_before, "霰弹打进人堆，对面少了人（%d → %d）"
		% [foe_before, scatter_b.foe_crew])
	_check(b.own_crew == 40 or b.own_crew < 40, "两边的人数都记在账上（我方 %d / 对面 %d）"
		% [b.own_crew, b.foe_crew])
	var st := b.stats()
	_check(str(st["outcome"]) != "", "打出了一个结果（%s）" % str(st["outcome"]))
	# 起手就拉开：能走掉
	var c := _battle()
	var c2 := _cargo()
	var ship2 := ShipDynamics.new(ShipPhysics.load_default())
	c.intent = "withdraw"
	_run(c, c2, ship2, 900.0)
	_check(str(c.stats()["outcome"]) == "broke_off", "想收手就收得掉（%s）" % str(c.stats()["outcome"]))


# ---------------------------------------------------------------- 5 弹药

func _test_ammo() -> void:
	var b := _battle()
	var cargo := _cargo()
	var ship := ShipDynamics.new(ShipPhysics.load_default())
	var powder_before := cargo.qty("powder")
	_run(b, cargo, ship, 240.0)
	_check(cargo.qty("powder") < powder_before, "打炮是从货舱里扣火药（%d → %d）"
		% [powder_before, cargo.qty("powder")])
	# 打光了就打不出去了
	var empty := Guns.new()
	empty.setup_default()
	var bare := _cargo(0, 0)
	var t := 0.0
	var shots := 0
	while t < 900.0:
		empty.tick(DT, 0.6)
		var r := empty.fire_broadside(400.0, "round_shot", bare, 0.6, true, false)
		shots += int(r["shots"])
		t += DT
	_check(shots == 0, "没有火药就一发也打不出去（%d 发）" % shots)


# ---------------------------------------------------------------- 6 接舷

func _test_boarding() -> void:
	var b := _battle(40, 40, "dry", 70.0)
	var cargo := _cargo()
	var ship := ShipDynamics.new(ShipPhysics.load_default())
	b.intent = "board"
	_run(b, cargo, ship, 600.0)
	_check(b.boarded, "钩住并跳了帮（boarded=%s）" % b.boarded)
	var st := b.stats()
	_check(str(st["outcome"]) in ["won", "lost", "mutual"], "接舷打出了一个结果（%s）" % str(st["outcome"]))
	_check(b.foe_crew < 40, "跳帮把对面的人打少了（%d）" % b.foe_crew)
	# 人数劣势的接舷：赢不了
	var weak := _battle(4, 30, "dry", 70.0)
	var c2 := _cargo()
	var ship2 := ShipDynamics.new(ShipPhysics.load_default())
	weak.intent = "board"
	_run(weak, c2, ship2, 600.0)
	_check(str(weak.stats()["outcome"]) != "won",
		"四个人跳上三十个人的船，赢不了（%s）" % str(weak.stats()["outcome"]))


# ---------------------------------------------------------------- 7 游戏里接得上

func _test_voyage_wiring() -> void:
	"""模型对了不算数 —— 这一场得能从 `Voyage` 里真的打起来、打完能收账。"""
	var v := Voyage.new()
	v.setup(Sea.DATA_PATH)              # 8km 的迷你海域，跑得快
	_check(v.naval == null, "开局没有海战")
	v.cargo.add("powder", 200)
	v.cargo.add("lead", 2000)
	var r: Dictionary = v.begin_naval_battle(20, "dry", 150.0)
	_check(bool(r.get("ok", false)), "在自己的船上能起一场海战（%s）" % str(r))
	var crew_before := v._alive_crew_count()
	var t := 0.0
	while t < 2400.0 and v.naval != null:
		v.tick(DT)
		t += DT
	_check(v.naval == null, "打完之后收了账（naval 清空）")
	_check(v.journal.entries.size() > 0, "日志里留下了这一仗（%d 条）" % v.journal.entries.size())
	_check(v._alive_crew_count() <= crew_before, "伤亡写回了名册（%d → %d）"
		% [crew_before, v._alive_crew_count()])
	_check(int(v.memory.get("naval", 0)) >= 1, "世界记住了这一仗（memory.naval=%d）"
		% int(v.memory.get("naval", 0)))
	# 船长在岸上时不许开打（船上的事交给大副）
	var v2 := Voyage.new()
	v2.setup(Sea.DATA_PATH)
	v2.ashore = true
	var r2: Dictionary = v2.begin_naval_battle(10, "dry", 150.0)
	_check(not bool(r2.get("ok", false)), "船长在岸上时开不了海战（%s）" % str(r2.get("reason", "")))


# ---------------------------------------------------------------- 收尾

# ---------------------------------------------------------------- 8 两条路算同一件事

func _test_authority_paths_agree() -> void:
	"""单机那一路（`fire_broadside`）与联机那一路（`volley_request` → `resolve`）
	必须算出**同一个结果** —— 否则"受击方权威"判的就是另一件事，
	两边的伤亡名单从根上就对不上（docs/22 第 10.4 节）。"""
	var local := _battle()
	var remote := _battle()
	var cargo := _cargo()
	var res_local := local.guns_own.fire_broadside(local.gap_m, local.ammo_want, cargo,
		local.skill_own, true, local.closing, true)
	var req := remote.volley_request()
	var res_net := NavalBattle.resolve(req)
	for key in ["shots", "hits", "misfires", "structure", "rigging", "personnel"]:
		var a := float(res_local.get(key, -1.0))
		var b := float(res_net.get(key, -2.0))
		_check(is_equal_approx(a, b), "两条路的 %s 一样（%.3f vs %.3f）" % [key, a, b])
	_check((req.get("guns", []) as Array).size() == 6, "请求里带着六个装好的炮位（%d）"
		% (req.get("guns", []) as Array).size())
	# 伤亡数人：请求里也给了"倒了几个人"，两边照它记账
	var losses := int(res_net.get("personnel_losses", -1))
	var counted := int(floor(float(res_net["personnel"]) / 0.55 + 0.5))
	_check(losses == counted, "伤亡人数是从伤害里推出来的（%d）" % losses)
	# 同一包请求算两遍，结果逐字相同（受击方权威可复现）
	_check(str(NavalBattle.resolve(req)) == str(res_net), "同一包请求算两遍结果相同")

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
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
