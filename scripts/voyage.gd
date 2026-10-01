class_name Voyage
extends RefCounted

# 一次航行（Day 6 起）：海图 + 风 + 洋流 + 船 + 船员 + 剧情事件 + 登陆。
#
# 它把前五天做的东西串成一条体验链：
#   出港（Day 1-2 的船）→ 靠风航行（Day 3）→ 指挥链路（Day 4）
#   → 船员在船上过日子（Day 5）→ 发现岛、挑人上岸、船上交给大副（Day 6）
#   → 世界分块与海图（M2：同一套查询换成了 WorldMap，多岛、有海岸）
#
# 唯一一条"单向"规矩不变：**只有 ShipDynamics 能写船的位置与速度**。
# Voyage 只是每帧把风、洋流、指令喂给它，再读它的状态去推进剧情。

const KNOT := 0.514444
const LOOKOUT_M := 8000.0          # 瞭望视野（= tile 的一半）：看见即"发现"
# 四艘船的起航位置（在出发港附近的水面上散开，免得画成一坨）
const FLEET_OFFSETS := [
	Vector2(0, 0), Vector2(330, 300), Vector2(-340, 360), Vector2(80, 720),
]

var sea := Sea.new()
var wind := WindField.new()
var fleet := Fleet.new()           # 世界里的 4 艘远征船（M3）
var cargo := Cargo.new()           # 本船的货舱（M4，拥有者权威）
var ports := Ports.new()           # 四个港口的库存与价格（M4，房主权威）
var rules := Rules.new()           # 玩家定的规矩（M5，本船）
var society := Society.new()       # 船上社会（M5，本船）
var dilemmas := Dilemma.new()      # 三个高压抉择（M5，本船）
var battle: LandBattle = null      # 上岸打起来的那一场（M6，null = 没在打）
var culture := Culture.new()        # 当地文明的三档态度（M6）
var weather := Weather.new()        # 自然环境（M7）
var events := EventPool.new()       # 三类事件池（M7）
var knowledge := Knowledge.new()    # 知识：发现即记录（M7）
var memory := {}                    # 世界记住你做过什么（M7）：掠夺/救人/毁约/贸易
var reached_destination := false    # M8：四条船都到了终点港（抵达是个闩）
var following_route := false        # M8：玩家选了"沿航线走"（一键沿着航段开）
var route_waypoints: Array = []     # 跟着走的那串点（从当前位置最近的那个港起算）
# M8 收尾：给"朝着目标点却磨不出净前进"配一句话。**只说话，不动任何数** ——
# 操法本身要不要改是用户的决定（docs/07 的待决问题）。它是纯界面状态，不进存档
# （读档后重新数一遍就行，和 `_prev_pos` 同类）。
var _stall_t := 0.0
var _stall_best := INF
var _stall_nagged := false
var ending_score := {"wealth": 0, "voyage": 0, "knowledge": 0, "crew": 0, "history": 0}
var link: NetLink = null           # 联机（M3）：单机时是 null，走的是同一套调用
var region_path := Sea.DATA_PATH   # 这一局用的是哪片海（静态数据，不进存档）
var ship: ShipDynamics
var orders: ShipOrders
var nav: Navigator
var crew: Crew
var roster: CrewRoster
var journal := VoyageJournal.new()   # 文书的航海日志（Day 7）：结算页的唯一数据源
var story := Story.new()             # 三幕剧情（Day 7）：触发条件 + 文本 + 后果

var t := 0.0
var day := 0                       # 1519-09-20 起的天数（M2 起由日历算出来，见 docs/14）
var log_lines: Array = []          # 航海日志（文书记的）
var fired := {}                    # 已触发的事件 id
var pending_reports: Array = []    # 船长不在船时攒下的报告，回船一次性给他
var island_known := false
var visited := {}                  # 到过的地标
var discovered := {}               # 已发现的地图分块（tile 键 -> true）—— 房主权威
var known_places := {}             # 已经认得名字的地方：陆地与港口（特征 id -> true）
var reef_hit := false
var docked_port := ""              # 现在靠在哪个港（空 = 在海上）
var shortage_events := 0           # 欠过几次粮（M5 要拿它算士气）
var _supply_acc := 0.0             # 补给结算的累加器（游戏秒）
var _weather_acc := 0.0            # 风暴磨损的累加器（游戏秒）

# --- 登陆 ---
var ashore := false
var captain_pos := Vector2.ZERO
var captain_target := Vector2.ZERO
var party_speed := 14.0            # 岸上走路（米/秒）：别让玩家在等
var ashore_count := 0              # 跟船长一起上岸的水手数（关键船员另算）
var landing_point := Vector2.ZERO  # 上岸点：船旁边最近的那段岸（不是固定航标）
var landing_land := {}             # 上岸点踩在哪块陆地上（队伍活动的范围由它决定）
var party := LandingParty.new()    # 登陆队：一个一个下船 + 岸上排成队形
var last_message := ""             # 最新一条重要消息（HUD 上显示十几秒）
var message_timer := 0.0
var _shore_cooldown := 0.0         # 蹭滩提示的冷却
var _prev_pos := Vector2.ZERO      # 上一帧的船位：只用来算航程


func setup(region := Sea.DATA_PATH, ship_id := "trinidad", inherited := {}) -> void:
	region_path = region
	sea.setup(region)
	# 时间尺度：地图是压缩过的（48km ↔ 6000km），日历与补给按**真实航程**算
	VoyageJournal.voyage_time_scale = sea.real_time_scale()
	ports.setup()
	fleet.setup()
	fleet.claim_local(ship_id)
	fleet.goal = default_destination()   # 抵达判定用（M8：全队抵达才结算）
	var w: Dictionary = sea.wind()
	wind = WindField.new(float(w.get("base_tws_ms", 8.0)), float(w.get("base_from_deg", 20.0)))
	ship = ShipDynamics.new(ShipPhysics.load_default())
	cargo.setup(Cargo.deadweight_from_ship())
	var port_d: Dictionary = sea.port()
	var pos: Array = port_d.get("pos", [700, 4000])
	ship.set_pose(Vector2(float(pos[0]), float(pos[1])), 0.0)
	orders = ShipOrders.new()
	nav = Navigator.new(orders)
	crew = Crew.new(ship)
	roster = CrewRoster.new()
	roster.setup()
	crew.roster = roster
	rules.setup()
	society.setup(roster)
	dilemmas.setup()
	culture.setup()
	weather.setup()
	events.setup()
	memory = {}
	story.load_data()
	# 陆地：船开不上干地（沙滩那一圈是浅水，可以靠上去登陆）。
	# M2 起陆地是一张形状表（海岸 + 多个岛），不再是"一个圆心加一个半径"。
	ship.land_shapes = sea.land_shapes(true)
	ship.step(0.0, wind.velocity_world())
	crew.retrim()
	_prev_pos = ship.position_m()
	journal.record(0.0, "story", "%s，圣卢卡尔港。五艘船出海，你带的是那艘六十吨的拉丁帆船。" % VoyageJournal.date_cn(0.0))
	log_event("出发：%s。" % str(port_d.get("name", "出发港")))
	_setup_fleet_ships(Vector2(float(pos[0]), float(pos[1])))
	if not inherited.is_empty():
		_take_over(inherited)
	_survey()
	_publish_local_summary()


func tick(delta: float) -> void:
	t += delta
	day = VoyageJournal.day_index(t)
	wind.step(delta)
	# 船队：AI 船与"别人的船"各自往前走一步。本机那条走下面的细化链路。
	fleet.step_game(delta, sea)
	var pos := ship.position_m()
	journal.advance(_prev_pos, pos)
	_prev_pos = pos
	weather.step(delta, pos)           # 天气先走：它改风、改损伤、改瞭望距离
	# 洋流与背风区：同一个风，在岛后面就是软的；同一片水，在洋流带上自己会动
	ship.current_world = sea.current_at(pos)
	# **天气真的改风**：风暴里同样的信风是 1.9 倍，无风带里只剩两成
	var wind_vec := wind.velocity_world() * sea.lee_factor(pos) * weather.wind_mult()
	# 指挥链路（船长在不在船上都一样：不在就是大副在管）
	nav.decide(ship)
	crew.set_target_heading(nav.target_heading_deg)
	crew.hands_on_sails = orders.hands_on_sails
	ship.set_sail_area_scale(orders.sail_area_scale())
	ship.set_anchored(orders.anchored)
	roster.tick(delta, orders.hands_on_sails)
	crew.step(delta)
	ship.step(delta, wind_vec)
	_society_tick(delta)
	_survey()
	# 蹭上滩头：给一点损伤与提示（不该天天撞，所以有冷却）
	_shore_cooldown = maxf(0.0, _shore_cooldown - delta)
	if ship.last_blocked and _shore_cooldown <= 0.0:
		_shore_cooldown = 20.0
		ship.apply_damage("hull", 0.06)
		journal.decide("船底蹭上滩头，船体损伤 6% —— 靠得太近了。")
		_say("船底蹭上滩头，木匠皱着眉头看了一眼。", true)
	if not is_client():
		# 世界事件与剧情是**房主权威**：客户端这一块只读（WORLD 包每 0.5 秒覆盖一次）
		_events(delta)
		story.tick(self, delta)
		for msg in story.take_messages():
			# 演出的弹窗只给玩家看，不进"文书最后写下的一条"（否则第三幕的收尾句会被顶掉）
			_say(str(msg), true, false)
	if ashore:
		party.tick(delta)
		captain_pos = party.captain
		_walk_ashore(delta)
		if party.boarding and party.boarded_all():
			_finish_boarding()
	_weather_wear(delta)
	events.tick(delta, self)
	_consume_supplies(delta)
	if battle != null and not battle.over:
		battle.tick(delta, cargo)
		if battle.over:
			_resolve_battle()
	_check_fleet_arrival()
	_route_tick()
	_stall_hint(delta)
	_publish_local_summary()


func _stall_hint(delta: float) -> void:
	"""船朝目标点走了好几分钟却没有净前进 —— 跟玩家说一句人话。

	为什么要有它：v0.5 的验收第 4 条是"陌生人 15 分钟能上手"。实测过一种卡法 ——
	**目标点正好在正逆风上**时，航海官（v0.1 就有的抢风逻辑）在离港 2–3 公里处
	磨不出净前进，船以 0.2–0.3 节原地打转。这是"船怎么开"的机制问题，
	要不要改操法由用户拍板（`docs/07` 待决问题 / `docs/21` 第 4.6 节）；
	在那之前，至少不能让玩家**不知道自己卡住了**。

	只出一条消息、每次卡住只出一次；一旦真的在前进就重新武装。
	"""
	if not orders.has_target_point or ashore or orders.anchored \
			or orders.sail_level == ShipOrders.SailLevel.FURLED:
		_reset_stall()
		return
	var d := ship.position_m().distance_to(orders.target_point)
	if _stall_best == INF:
		_stall_best = d
		return
	if d < _stall_best - 40.0:          # 40 米算"真的近了"（比抖一格大得多）
		_reset_stall()
		_stall_best = d
		return
	_stall_best = minf(_stall_best, d)
	_stall_t += delta
	if _stall_t < 180.0 or _stall_nagged:      # 三个游戏分钟没挪窝才开口
		return
	_stall_nagged = true
	# 判断"有没有风"要看**船实际收到的风**：真风 8 m/s 碰上无风带（×0.22）或岛后
	# 的背风区，落在帆上的就只剩两成 —— 这时候说"正对着风"是把原因说错了。
	var felt := (wind.velocity_world()
		* sea.lee_factor(ship.position_m()) * weather.wind_mult()).length()
	if felt < 2.5:
		say("这一带没什么风（或者被岛挡住了），船在漂 —— 等风来，或者换个目标点（左键）。", true)
	elif following_route:
		# 跟着航线走还卡住，说明这一段本身就逆风 —— 让他自己接管
		say("这一段正顶着风，船磨不出前进 —— 左键点一个偏开一点的目标点，按 N 停下跟随。", true)
	else:
		say("目标点正对着风，船磨不出前进 —— 点一个偏开一点的目标点，或者按 N 沿航线走。", true)


func _reset_stall() -> void:
	_stall_t = 0.0
	_stall_best = INF
	_stall_nagged = false


func _check_fleet_arrival() -> void:
	"""M8 的终点：**四条船都到巴西**，这一程才算走完（docs/13 第 2 节第 11 条）。

	到了就宣布"可以结算了" —— 用的是和 v0.1 那一幕一样的旗标（`story.ending_ready`），
	所以结算页只有一处出口：返航（v0.1 的弧）与抵达终点（v0.5 的弧）都汇到它。
	"""
	if reached_destination:
		return
	if fleet.arrived.size() < fleet.count():
		return
	reached_destination = true
	story.ending_ready = true
	_say("【船队】四条船都到了圣阿莱克索。文书把这一路的账摊在桌上。", true)
	journal.decide("船队抵达圣阿莱克索，远征走完。")


# ------------------------------------------------------------ 沿航线走（M8 的"不会搁浅"辅助）

func start_route_follow() -> String:
	"""玩家按一下 `N`：沿着 `routes.json` 的航段一段一段开。

	为什么需要它：航海官只会算"朝目标点的航法"，不会绕开海岸 ——
	从塞维利亚直着点巴西，船会贴着西非海岸一路蹭（AI 船修好之前就是这样卡住的）。
	航线数据本来就是为"不穿干地"设计的，让玩家也能用它。
	"""
	route_waypoints = _fleet_route(ship.position_m())
	if route_waypoints.is_empty():
		return "这片海里没有航线数据"
	# 砍掉"身后"的点：只保留离当前位置最近的那个点之后的
	var best := 0
	var best_d := INF
	for i in route_waypoints.size():
		var d := (route_waypoints[i] as Vector2).distance_to(ship.position_m())
		if d < best_d:
			best_d = d
			best = i
	route_waypoints = route_waypoints.slice(best)
	following_route = true
	orders.set_target_point(route_waypoints[0] as Vector2)
	return "沿航线走：下一段去 %s" % _route_leg_name()


func stop_route_follow() -> String:
	following_route = false
	return "不再跟航线走（左键可以自己点目标）"


func _route_leg_name() -> String:
	if route_waypoints.is_empty():
		return "终点"
	var p := route_waypoints[0] as Vector2
	for port in sea.ports():
		if Geom2D.centroid(port["shape"]).distance_to(p) < 1.0:
			return str(port.get("name", "下一站"))
	return "航点 %.0f,%.0f" % [p.x, p.y]


func _route_tick() -> void:
	if not following_route:
		return
	if route_waypoints.is_empty():
		following_route = false
		return
	var p := route_waypoints[0] as Vector2
	if ship.position_m().distance_to(p) < 500.0:
		if route_waypoints.size() <= 1:
			following_route = false
			_say("（航线）到终点港了。", true)
			return
		route_waypoints.pop_front()
		orders.set_target_point(route_waypoints[0] as Vector2)
		_say("（航线）下一段：%s" % _route_leg_name(), false)


# ------------------------------------------------------------ 补给与港口（M4）

func crew_on_board() -> int:
	var n := 0
	for m in roster.members:
		if not m.ashore:
			n += 1
	return n


func voyage_days_for(distance_m: float, speed_kn := 5.0) -> float:
	"""一段航程要几个"航程日"：地图距离 × 压缩系数 ÷ 真实日速。

	速度取 5 节（这艘船在常见风下的巡航速度），算的是"要带多少天的口粮"，
	不是导航预测 —— 真正的用时由风和操帆决定。
	"""
	var real_km := distance_m / 1000.0 * sea.real_time_scale()
	var km_per_day := maxf(1.0, speed_kn * 1.852 * 24.0)
	return real_km / km_per_day


func supply_need_for(distance_m: float, speed_kn := 5.0, crew := -1) -> Dictionary:
	"""按距离算这一程要多少口粮与淡水（验收第 1 条的那把尺子）。"""
	var c := crew if crew >= 0 else crew_on_board()
	var days := voyage_days_for(distance_m, speed_kn)
	var cons: Dictionary = Cargo.defs_data().get("consumption", {})
	var food := int(ceil(float(c) * float(cons.get("ration_per_person_day", 1.0)) * days))
	var water := int(ceil(float(c) * float(cons.get("water_l_per_person_day", 3.0)) * days
		/ Cargo.item_liters("water")))
	return {"days": days, "crew": c, "food": food, "water": water}


func next_port_id() -> String:
	"""下一个没到过的港（没有就回出发港）——"要不要补给"这个问题问的是它。"""
	var best := ""
	var best_d := INF
	for p in sea.ports():
		var id := str(p.get("id", ""))
		if id == docked_port:
			continue
		var d := Geom2D.centroid(p["shape"]).distance_to(ship.position_m())
		if d < best_d:
			best_d = d
			best = id
	return best


func next_port_position() -> Vector2:
	for p in sea.ports():
		if str(p.get("id", "")) == next_port_id():
			return Geom2D.centroid(p["shape"])
	return sea.port_pos()


func _consume_supplies(delta: float) -> void:
	"""按**航程日**扣口粮与淡水：每 60 个游戏秒结算一次。

	60 游戏秒 = 0.5 个航程小时（×125 的压缩系数），所以一程横渡下来
	要吃掉几十个航程日的东西 —— 这正是"不带够就走不到巴西"的那个"够"。
	"""
	_supply_acc += delta
	if _supply_acc < 60.0:
		return
	var days := 60.0 * VoyageJournal.voyage_time_scale / 86400.0
	_supply_acc = 0.0
	var was_starving := cargo.starving
	# **规矩在这里生效**：口粮制度与饮水制度直接改消耗量（验收第 1 条）
	var r := cargo.consume(days, crew_on_board(), rules.food_mult(), rules.water_mult())
	if int(r["short"]) > 0 and not was_starving:
		shortage_events += 1
		_say("桶匠把最后几桶淡水锁了起来：船上开始缺粮缺水。", true)
		journal.decide("补给见底，还在海上 —— 只能咬牙往前。")
	elif int(r["short"]) == 0 and was_starving:
		cargo.starving = false
		_say("在港口补上了水和食物，船上又有了底气。", true)


func _society_tick(delta: float) -> void:
	"""船上社会：规则给的乘数灌进名册，关系与紧张度往前走，事件冒出来。"""
	# 规矩管一半，天气管另一半：风暴里更累、更闷（M7 把天气接进 M5 的两个乘数）
	roster.fatigue_mult = rules.fatigue_mult() * weather.fatigue_mult()
	roster.mood_bias = rules.mood_bias() + weather.mood_bias()
	var near_land: bool = (not sea.land_containing(ship.position_m()).is_empty()) \
		or float(sea.nearest_shore(ship.position_m())["distance_m"]) < 2500.0
	society.tick(delta, roster, rules, cargo, near_land)
	for ev in society.take_events():
		_say("【%s】%s" % [str(ev["name"]), str(ev["text"])], true)
		journal.record(t, "society", "%s：%s" % [str(ev["name"]), str(ev["text"])])
	for m in roster.members:
		if m.job == "deserted" and not fired.has("deserted_" + m.id):
			fired["deserted_" + m.id] = true
	dilemmas.check(self)


func _weather_wear(delta: float) -> void:
	"""风暴每小时往船体和桅杆上砸损伤 —— 这是"风暴真的改变航行结果"的一半
	（另一半是 `wind_mult`：同样的航程，风暴里到得晚、伤得多）。"""
	var per_hour := weather.damage_per_hour()
	if per_hour.is_empty():
		return
	_weather_acc += delta
	if _weather_acc < 60.0:
		return
	_weather_acc = 0.0
	var hours := 60.0 * VoyageJournal.voyage_time_scale / 3600.0
	for part in per_hour.keys():
		ship.apply_damage(str(part), float(per_hour[part]) * hours)


func _note_weather() -> void:
	"""天气也是知识：第一次遇到风暴/浓雾/无风带的人会把它写下来。"""
	if weather.state_id == "clear" or knowledge.has("current", "weather_" + weather.state_id):
		return
	if weather.spells == 0 and weather.hours_left > 30.0:
		return                        # 开局那一段不算"遇到过"
	knowledge.note("current", "weather_" + weather.state_id,
		"天气：%s" % weather.state_name(), str(weather.state().get("text", "")), t)


func set_rule(rule_id: String, option_id: String) -> bool:
	var ok := rules.set_rule(rule_id, option_id)
	if ok:
		_say("规矩改了：%s → %s。" % [
			str(rules.rule_def(rule_id).get("name", rule_id)), rules.option_name(rule_id)], true)
		journal.decide("改了规矩：%s。" % rules.option_name(rule_id))
	return ok


func answer_dilemma(option_id: String) -> Dictionary:
	var id := dilemmas.current()
	if id == "":
		return {"ok": false, "reason": "现在没有要你拿主意的事"}
	return dilemmas.resolve(self, id, option_id)


# ------------------------------------------------------------ 陆战（M6）

func ashore_squad() -> Array:
	"""岸上这支队伍：跟着下船的关键船员 + 派下去的水手。"""
	var out := []
	for m in roster.key_crew():
		if m.ashore and not m.dead:
			out.append(m)
	for m in roster.hands():
		if m.ashore and not m.dead:
			out.append(m)
	return out


func begin_land_battle(locals_count := 10, weather := "") -> Dictionary:
	"""打起来了。只有**船长在岸上**的时候才由玩家指挥（不然是留守的人在打）。"""
	if battle != null and not battle.over:
		return {"ok": false, "reason": "已经在打了"}
	if not ashore:
		return {"ok": false, "reason": "船长不在岸上"}
	var squad := ashore_squad()
	if squad.is_empty():
		return {"ok": false, "reason": "岸上没有人"}
	var w := weather if weather != "" else "dry"
	battle = LandBattle.new()
	# 打起来的地方就是队伍站的地方（不然画面上的两支队在世界的另一个角落）
	battle.setup(squad, locals_count, w, captain_pos)
	var load := Weapons.describe_loadout(Weapons.loadout_for(squad))
	_say("【遭遇】当地人围了上来（%d 人对 %d 人）。你们带着：%s。" % [
		locals_count, squad.size(), load], true)
	journal.record(t, "battle", "上岸遭遇：%d 名当地人对 %d 名船员。" % [locals_count, squad.size()])
	if culture.stance("green_cape") != Culture.HOSTILE:
		culture.shift("green_cape", -0.15, "冲突")
	return {"ok": true, "locals": locals_count, "crew": squad.size(), "loadout": load}


func battle_report() -> String:
	return battle.describe() if battle != null else ""


func _resolve_battle() -> void:
	"""打完之后的账：伤员能不能救回来、死者写进名册与航海日志。

	规则（M6 卡片）：重伤需要**外科医生 + 药品**；救不回来的就是死了。
	死是永久的：名册里留名字、日志里留讣告、结算的"船员成果"扣分。
	"""
	var surgeon := false
	for m in roster.key_crew():
		if m.post == "外科医生" and m.ashore and not m.dead:
			surgeon = true
	var meds := cargo.qty("medicine")
	var saved := 0
	var lost := 0
	for u in battle.downed_units("crew"):
		var member := _member_by_id(str(u.member_id))
		if member == null:
			continue
		member.health = 0.25
		if surgeon and meds > 0:
			meds -= 1
			cargo.remove("medicine", 1)
			saved += 1
			member.health = 0.45
		else:
			battle.kill_down(u)
			lost += 1
	for u in battle.dead_units("crew"):
		var m2 := _member_by_id(str(u.member_id))
		if m2 == null or m2.dead:
			continue
		m2.dead = true
		m2.health = 0.0
		m2.job = "dead"
		ending_score["crew"] = int(ending_score.get("crew", 0)) - 1
		_say("【讣告】%s 没能从岸上回来。" % m2.label(), true)
		journal.record(t, "death", "讣告：%s 在岸上阵亡。" % m2.label())
		fired["lost_" + m2.id] = true
	var locals_lost := int(battle.stats()["locals_dead"]) + int(battle.stats()["locals_down"])
	var head := "打完了：%s。" % battle.outcome
	if saved > 0:
		head += "外科医生救回了 %d 个人。" % saved
	if lost > 0:
		head += "有 %d 个人没救回来。" % lost
	head += "当地人倒下 %d 个。" % locals_lost
	_say(head, true)
	journal.decide("上岸打了一仗：船员倒 %d、阵亡 %d；当地人倒下 %d。" % [
		int(battle.stats()["crew_down"]) + lost, lost, locals_lost])
	if battle.outcome == "crew_wins":
		culture.react("green_cape", "kill", "打退了当地人")
		ending_score["history"] = int(ending_score.get("history", 0)) - 1
	elif battle.outcome == "locals_win":
		culture.react("green_cape", "trespass", "被赶回海滩")
		society.tension = clampf(society.tension + 0.15, 0.0, 1.0)


func _member_by_id(id: String) -> CrewMember:
	for m in roster.members:
		if m.id == id:
			return m
	return null


func can_dock() -> bool:
	if ashore or docked_port != "" or not orders.anchored:
		return false
	return not sea.port_at(ship.position_m()).is_empty()


func dock() -> String:
	if docked_port != "":
		return "已经靠在港里了"
	if not can_dock():
		return "要先抛锚，而且得停在港里（锚地那个圈）"
	var p := sea.port_at(ship.position_m())
	docked_port = str(p.get("id", ""))
	journal.decide("靠上%s，开始盘点货舱。" % str(p.get("name", "港口")))
	# 知识：到过的港都记一条（M7 的"发现即记录"）
	knowledge.note("trade", "port_" + docked_port,
		"港口：%s" % str(p.get("name", "")), "锚地在这一带。", t)
	_say("靠上%s。" % str(p.get("name", "港口")), true)
	return ""


func undock() -> String:
	if docked_port == "":
		return "本来就没靠港"
	var name := docked_port
	docked_port = ""
	journal.decide("从%s出海。" % name)
	return ""


func port_name() -> String:
	if docked_port == "":
		return ""
	return sea.port_name_of(docked_port)


func can_trade_here() -> bool:
	"""买卖会动**港口库存**（房主权威），所以 v0.5 只让房主在港里交易。

	客户端可以看价格与库存（只读），但按不下"买"—— 这条写进 docs/17 的限制清单，
	两段式确认（申请→房主执行→回执）留给以后。
	"""
	# M7：因果链里那一环 —— 坏名声会让港口不做你的生意（`ports_refuse`）
	return docked_port != "" and not is_client() and not fired.has("ports_refuse")


func port_buy(item: String, n: int) -> Dictionary:
	if not can_trade_here():
		return {"ok": false, "reason": "只能在靠港时交易（联机时由房主交易）"}
	var r := ports.buy(docked_port, item, n, cargo)
	if bool(r.get("ok", false)):
		_say("买了 %d %s %s，花了 %d 金币。" % [
			int(r["qty"]), cargo.item_name(item), cargo.item_unit(item), int(r["cost"])], true)
	return r


func port_sell(item: String, n: int) -> Dictionary:
	if not can_trade_here():
		return {"ok": false, "reason": "只能在靠港时交易（联机时由房主交易）"}
	var r := ports.sell(docked_port, item, n, cargo)
	if bool(r.get("ok", false)):
		_say("卖了 %d %s %s，得到 %d 金币。" % [
			int(r["qty"]), cargo.item_name(item), cargo.item_unit(item), int(r["gain"])], true)
	return r


func port_supply_bundle(margin := 1.15) -> Dictionary:
	"""一键补给：按"开到下一个港要多少"买齐，留一点余量。"""
	if not can_trade_here():
		return {"ok": false, "reason": "先靠港"}
	var need := supply_need_for(next_port_position().distance_to(ship.position_m()))
	var want_food := int(ceil(float(need["food"]) * margin)) - cargo.qty("food")
	var want_water := int(ceil(float(need["water"]) * margin)) - cargo.qty("water")
	var spent := 0
	var bought := []
	for pair in [["food", want_food], ["water", want_water]]:
		var item := str(pair[0])
		var n := int(pair[1])
		if n <= 0:
			continue
		var afford := mini(n, int(floor(float(cargo.money) / maxf(1.0, float(ports.buy_price(docked_port, item))))))
		afford = mini(afford, ports.stock_of(docked_port, item))
		afford = mini(afford, cargo.how_many_fit(item))
		if afford <= 0:
			continue
		var r := ports.buy(docked_port, item, afford, cargo)
		if bool(r.get("ok", false)):
			spent += int(r["cost"])
			bought.append("%d %s" % [afford, cargo.item_name(item)])
	if bought.is_empty():
		return {"ok": false, "reason": "补给已经够了，或者买不起"}
	_say("补给了 %s，花了 %d 金币。" % ["、".join(bought), spent], true)
	return {"ok": true, "bought": bought, "spent": spent, "need": need}


func port_repair(part: String, amount := 1.0) -> Dictionary:
	if not can_trade_here():
		return {"ok": false, "reason": "先靠港"}
	var have := ship.damage_of(part)
	var do_amount := minf(amount, have)
	if do_amount <= 0.001:
		return {"ok": false, "reason": "这一处没有损伤"}
	var r := ports.repair(docked_port, part, do_amount, cargo, ship)
	if bool(r.get("ok", false)):
		_say("修好了 %s 的 %.0f%%。" % [
			{"hull": "船体", "mast": "桅杆", "rudder": "舵"}.get(part, part),
			do_amount * 100.0], true)
		journal.decide("在%s修船：%s %.0f%%。" % [port_name(),
			{"hull": "船体", "mast": "桅杆", "rudder": "舵"}.get(part, part), do_amount * 100.0])
	return r


func tick_real(real_delta: float) -> void:
	"""真实时间的那一帧：网络收发与远端船插值。

	和 `tick()` 分开是刻意的：游戏时间可以被快进 ×36，**网络不行** ——
	20Hz 是真实世界的 20Hz，插值的 100ms 也是真实世界的 100ms。
	"""
	fleet.advance_clock(real_delta)
	if link != null:
		link.step(real_delta)


func attach_link(l: NetLink) -> void:
	link = l
	if l != null:
		l.voyage = self
		# 客户端不自己推 AI 船：它们的动态只从房主发出
		fleet.mirror_world = l.session != null and l.session.is_client()


func is_client() -> bool:
	return link != null and link.session != null and link.session.is_client()


# ------------------------------------------------------------ 船队（M3）

func _setup_fleet_ships(port_pos: Vector2) -> void:
	"""四艘船摆在出发港外的水面上；没人开的那三条由 AI 带着走。

	单机 = 1 条细化 + 3 条 AI，联机 = 每个玩家各自细化自己那条、其余交回 AI ——
	**两条路径是同一条代码路径**（docs/13 M3 卡片第 4 条验收）。
	"""
	var target := default_destination()
	var route := _fleet_route(port_pos)
	for i in fleet.slots.size():
		var s: Dictionary = fleet.slots[i]
		var id := str(s["id"])
		if id == fleet.local_id:
			continue
		var a := AbstractShip.new()
		var at := port_pos + (FLEET_OFFSETS[i % FLEET_OFFSETS.size()] as Vector2)
		if sea.is_dry_land(at):
			at = port_pos
		a.setup(id, str(s["name"]), at, 90.0)
		if target != Vector2.ZERO:
			# 照着航段走（每条船稍微让开一点，免得三条船叠在一起）
			var offset := Vector2((float(i) - 2.0) * 420.0, (float(i) - 2.0) * 260.0)
			a.waypoints = route.duplicate()
			for k in a.waypoints.size():
				a.waypoints[k] = (a.waypoints[k] as Vector2) + offset
			a.target = target + offset
			a.has_target = true
		s["ship"] = a
		s["kind"] = Fleet.KIND_AI


func _fleet_route(from: Vector2) -> Array:
	"""给 AI 船的航点表：把 `routes.json` 的三段接起来，从**最近的港**开始走。

	为什么要这一张表：M8 验收第 1 条要求"四条船都到达"，而照着终点直线开的 AI
	会一头撞上西非海岸，然后永久卡在岸边（实测：三条船全部"受阻"在离终点 18.5km 处）。
	航线数据本来就是为"不穿干地"设计的（`test_worldmap` 每 250 米采样验过），直接用它。
	"""
	var out := []
	var best_port := ""
	var best_d := INF
	for p in sea.ports():
		var d := Geom2D.centroid(p["shape"]).distance_to(from)
		if d < best_d:
			best_d = d
			best_port = str(p.get("id", ""))
	var started := false
	for r in sea.routes():
		var pts := sea.route_points(r)
		var ids := [str(r.get("from", "")), str(r.get("to", ""))]
		if not started and ids.has(best_port):
			started = true
		if not started:
			continue
		for p in pts:
			if out.is_empty() or (out[out.size() - 1] as Vector2).distance_to(p) > 1.0:
				out.append(p)
	return out


func default_destination() -> Vector2:
	"""这一程要往哪儿去：**终点港**（v0.5 的巴西），没有就依次退到后面的港、那座岛。

	AI 船用它当目标；玩家掉线时房主也用它把那艘船接过去继续开。
	M8 起改成"最后的那个港"—— 因为全队结算要求四条船都开到巴西，
	AI 船要是只开到加那利就停，那条验收永远签不了。
	"""
	var ports := sea.ports()
	if ports.size() > 0:
		return Geom2D.centroid(ports[ports.size() - 1]["shape"])
	var isl := sea.island()
	if not isl.is_empty():
		var c: Array = isl.get("center", [0, 0])
		return Vector2(float(c[0]), float(c[1]))
	return Vector2.ZERO


func _take_over(summary: Dictionary) -> void:
	"""中途加入 / 重进：按**继承来的摘要**把这条船接着开（docs/13 第 5.3 节）。

	继承的是"别人的船"那几个数：船体% / 人数 / 位置 / 艏向 / 帆档 / 锚。
	逐人细节（谁在哪儿、累不累）没有继承，也不该有 —— 名册按同一份数据集重新生成，
	这也正是"不允许进入别人的船的内部视图"那条规矩的技术形态。
	"""
	var p: Array = summary.get("pos", [
		ship.position_m().x, ship.position_m().y])
	ship.set_pose(Vector2(float(p[0]), float(p[1])), float(summary.get("heading", 0.0)))
	ship.apply_damage("hull", 1.0 - float(summary.get("hull_pct", 1.0)))
	orders.set_sail_level(int(summary.get("sail_level", 0)) as ShipOrders.SailLevel)
	orders.anchored = bool(summary.get("anchored", false))
	crew.retrim()
	_prev_pos = ship.position_m()
	_survey()


func _publish_local_summary() -> void:
	"""把本机这条船压成摘要 —— 它就是 20Hz 广播出去的那一份。

	**只有这一份上网**：40 个人的逐人状态、帆的实时攻角、舵的积分项都不出去。
	"""
	fleet.set_local_summary(local_summary())


func local_summary() -> Dictionary:
	var on_board := crew_on_board()
	return {
		"id": fleet.local_id,
		"name": fleet.name_of(fleet.local_id),
		"pos": [ship.position_m().x, ship.position_m().y],
		"heading": ship.heading_deg(),
		"sail_level": int(orders.sail_level),
		"anchored": orders.anchored,
		"hull_pct": 1.0 - ship.damage_of("hull"),
		"crew_count": on_board,
		"action": ("抛锚" if orders.anchored else nav.method_name()),
		# M4：别人的船能看到的"装了多少 / 有多少钱"（docs/14 第 3 节的 cargo_summary）
		"hold_kg": cargo.used_kg(),
		"money": cargo.money,
	}


# ------------------------------------------------------------ 剧情事件

func _survey() -> void:
	"""把"看见"变成"记录"：走过的分块、认出来的陆地名字。

	它不是玩法，是**地图** —— 海图上的雾就是靠这里一条条散开的（docs/15 第 4 节）。
	判据只有一条：船离这个 tile 的方块在瞭望视野（8km）以内，就算瞭望员看见了。
	因为 tile 是 16km、视野是 8km，所以跨块**之前**邻块就已经亮了 ——
	不会出现"开过界了地形才突然冒出来"。
	"""
	if is_client():
		return            # 已发现的图是房主权威，客户端只读覆盖
	# 地图是**全队**探出来的：本机那条 + 船队里其他船的摘要位置都算
	for pos in _survey_points():
		_survey_at(pos)


func _survey_points() -> Array:
	var out := [ship.position_m()]
	for id in fleet.others():
		if fleet.kind_of(id) != Fleet.KIND_LOCAL:
			out.append(fleet.pose_of(id))
	return out


func _survey_at(pos: Vector2) -> void:
	for ty in sea.tiles().y:
		for tx in sea.tiles().x:
			var t := Vector2i(tx, ty)
			if discovered.has(sea.tile_key(t)):
				continue
			if _rect_dist(pos, sea.world.tile_rect(t)) <= LOOKOUT_M:
				discovered[sea.tile_key(t)] = true
	for f in sea.lands():
		var id := str(f["id"])
		if known_places.has(id):
			continue
		if Geom2D.center_dist(f["shape"], pos) <= Geom2D.extent(f["shape"]) + LOOKOUT_M:
			known_places[id] = true
			# 知识：认出一块陆地就记一条（M7 的"发现即记录"）
			knowledge.note("chart", "land_" + id, "陆地：%s" % str(f.get("name", id)), "", t)
	# 港口和陆地一样：走到了才在地图上写得出名字（出发港开局就在脚下）
	for p in sea.world.ports():
		var pid := str(p["id"])
		if known_places.has(pid):
			continue
		if Geom2D.center_dist(p["shape"], pos) <= Geom2D.extent(p["shape"]) + LOOKOUT_M:
			known_places[pid] = true


func record_decision(text: String) -> void:
	"""玩家做的一个决定。联机时它要进**房主**那本日志（客户端的日志是镜像）。"""
	if link != null:
		link.record_decision(text)
	else:
		journal.decide(text)
		journal.record(t, "decision", text)


static func _rect_dist(p: Vector2, r: Rect2) -> float:
	var far := r.position + r.size
	var dx := maxf(maxf(r.position.x - p.x, p.x - far.x), 0.0)
	var dy := maxf(maxf(r.position.y - p.y, p.y - far.y), 0.0)
	return sqrt(dx * dx + dy * dy)


func discovered_tiles() -> int:
	return discovered.size()


func total_tiles() -> int:
	return sea.tiles().x * sea.tiles().y


func is_tile_discovered(t: Vector2i) -> bool:
	return discovered.has(sea.tile_key(t))


func date_string() -> String:
	return VoyageJournal.date_of(t)


func date_cn() -> String:
	return VoyageJournal.date_cn(t)


func clock_string() -> String:
	return VoyageJournal.clock_of_day(t)


func _events(_delta: float) -> void:
	var pos := ship.position_m()
	# ① 瞭望员报告：离岛近了
	if not fired.has("lookout") and pos.distance_to(_island_center()) < 2600.0:
		fired["lookout"] = true
		island_known = true
		_say("瞭望员 佩德罗·卡斯科：右前方有陆地！", true)
	# ② 风向突变（Day 3 的风场只会缓变，这里是"意外"）
	if not fired.has("wind_shift") and t > 300.0:
		fired["wind_shift"] = true
		wind.base_from_dir += 55.0
		journal.decide("风向从东北转成东南，船头被压向下风。")
		_say("风向变了：从东北转成东南，船头被压向下风。", true)
	# ③ 触礁：这是那条**可见的因果链**的中间一环 ——
	#    风转了 → 船被压向暗礁 → 撞上 → 船体受损 → 木匠去修
	if not reef_hit and sea.is_reef(pos) and not orders.anchored:
		reef_hit = true
		ship.apply_damage("hull", 0.28)
		ship.apply_damage("rudder", 0.10)
		journal.decide("没有绕过暗礁：船体损伤 28%、舵 10%。")
		_say("船底刮上礁石。木匠喊着要人下去看船缝。", true)
		report("触礁：船体损伤约三成，舵也蹭到了一点。")
		fired["reef_hit"] = true
	# ④ 船员伤病（触礁之后才可能发生 —— 因果链的第二环）
	if fired.has("reef_hit") and not fired.has("injury") and t > 60.0:
		fired["injury"] = true
		var hurt := _jury_target()
		if hurt != null:
			hurt.health = clampf(hurt.health - 0.35, 0.05, 1.0)
			journal.decide("%s 在摇晃的甲板上摔断了肩膀。" % hurt.label())
			_say("%s 在摇晃的甲板上滑倒，肩膀脱臼。外科医生把他扶了下去。" % hurt.label(), true)
			report("%s 受了伤，已经交给外科医生。" % hurt.label())
	# ⑤ 抉择的另一半：见过岛、又把它甩在船尾 —— 那就是决定不上岸
	#    第二幕问的是"要不要登陆"，玩家可以回答"不"。这个"不"也必须被记下来，
	#    否则结算页只会写"你什么也没干"。
	if island_known and not fired.has("passed_by") and not ashore \
			and not fired.has("landed") and pos.distance_to(_island_center()) > 3200.0:
		fired["passed_by"] = true
		journal.decide("绕过了绿岬岛，没有上岸。")
		_say("绿岬岛被甩在船尾：你决定不在那儿停靠。", true)


func _jury_target() -> CrewMember:
	# 优先在甲板上干活的木匠/捻缝工（触礁之后最该受伤的就是他们），
	# 他们要是上岸了就换任何一个还在船上的人。
	for m in roster.key_crew():
		if m.ashore:
			continue
		if m.post == "木匠" or m.post == "捻缝工":
			return m
	for m in roster.key_crew():
		if not m.ashore:
			return m
	return null


func _walk_ashore(delta: float) -> void:
	var d := captain_target - captain_pos
	if d.length() > 4.0:
		captain_pos += d.normalized() * minf(party_speed * delta, d.length())
	var poi := sea.poi_at(captain_pos)
	if poi.is_empty():
		return
	var id := str(poi["id"])
	if visited.has(id):
		return
	visited[id] = true
	# 知识：上岸看到的东西按类记下来（遗迹/村落/溪流各有各的类别）
	match id:
		"ruins":
			knowledge.note("language", "ruins_mark", "遗迹上的刻字",
				str(poi.get("text", "")), t)
		"village":
			knowledge.note("culture", "village_contact", "部落村落（初次接触）",
				str(poi.get("text", "")), t)
		"stream":
			knowledge.note("chart", "fresh_water", "岛上的淡水溪流",
				str(poi.get("text", "")), t)
		_:
			knowledge.note("chart", "poi_" + id, str(poi.get("name", id)), "", t)
	journal.landfall(str(poi["name"]), str(poi.get("text", "")), t)
	_say("【%s】%s" % [str(poi["name"]), str(poi.get("text", ""))], true)
	if id == "ruins" and not fired.has("ruins"):
		fired["ruins"] = true
		journal.decide("把遗迹墙上看不懂的字抄了下来 —— 和《圣经》的字母不一样。")
		report("文书把遗迹墙上的字抄了下来 —— 和《圣经》的字母不一样。")
	if id == "village" and not fired.has("village"):
		fired["village"] = true
		journal.decide("和部落接触：他们没有动手，你们也没有。")
		report("和部落接触了：他们用手势比划着要交换，没有动手。")
	if id == "stream":
		journal.decide("在岛上的淡水溪流补了水：够装二十桶。")
		report("找到淡水溪流，桶匠说够装二十桶。")


# ------------------------------------------------------------ 登陆

func can_land() -> bool:
	"""船就在岸边上吗？"最近的岸"由海图算（WorldMap.nearest_shore）——

	v0.1 只能从固定的那个登陆航标上岸；多岛之后这句话必须变成"你旁边这段岸"。
	"""
	if ashore:
		return false
	return float(sea.nearest_shore(ship.position_m())["distance_m"]) < 420.0


func _island_center() -> Vector2:
	return sea.primary_center()


func landing_candidates() -> Array:
	"""谁能上岸：12 名关键船员 + 手下的水手（水手按人数算，不逐个列）。"""
	var out := []
	for m in roster.key_crew():
		out.append(m)
	return out


func land(ids: Array, hands := 6) -> String:
	"""带人上岸：选中的关键船员离开船，船上立刻少一双手。"""
	if ashore:
		return "已经在岸上了"
	if not can_land():
		return "离滩头太远（先开过去、抛锚，再登陆）"
	var names := PackedStringArray()
	for m in roster.key_crew():
		if ids.has(m.id):
			m.ashore = true
			names.append(m.post)
	ashore_count = clampi(hands, 0, 12)
	# 水手也真的下船：从还没上岸的普通船员里按顺序抽 N 个
	var taken := 0
	for m in roster.hands():
		if taken >= ashore_count:
			break
		if m.ashore:
			continue
		m.ashore = true
		taken += 1
	ashore_count = taken
	ashore = true
	fired["landed"] = true
	var shore := sea.nearest_shore(ship.position_m())
	landing_point = shore["pos"]
	landing_land = shore["land"]
	captain_pos = landing_point
	captain_target = captain_pos
	# 队伍：船长先上岸，船员按名单一个一个跟下来（小船一趟一个人）
	var party_crew := []
	for m in roster.key_crew():
		if m.ashore:
			party_crew.append(m)
	party.start(party_crew, landing_point, ship.position_m(), taken)
	var msg := "带 %s 和 %d 名水手上岸。" % [
		"、".join(names) if names.size() > 0 else "（不带关键船员）", ashore_count]
	record_decision(msg)
	_say(msg, true)
	return msg


func return_to_ship() -> String:
	if not ashore:
		return "你还在船上"
	if party.boarding:
		return "正在上船，等大家到齐…"
	if captain_pos.distance_to(landing_point) > 420.0:
		return "得先走回下船的地方才能上船"
	party.begin_boarding()
	return "招呼人上船：一个一个来。"


func _finish_boarding() -> void:
	"""所有人都回到船上：清掉上岸标记，把攒下的报告一次性交给船长。

	⚠️ 必须清**所有人**，不是只清 12 名关键船员 —— 第一版只清了关键船员，
	6 名普通水手就一直挂着"上岸"，船从此永远少 6 双手（结算页上还会写
	"岸上还有 6 人"）。Day 6 的测试只查了关键船员，所以一直没暴露。
	"""
	ashore = false
	for m in roster.members:
		m.ashore = false
	journal.decide("从滩头起锚，带着全队返航。")
	var msg := "回到船上。"
	if pending_reports.size() > 0:
		msg += "你不在的时候，船上发生了：\n" + "\n".join(pending_reports)
		pending_reports.clear()
	_say(msg, true)


func move_party_to(pos: Vector2) -> void:
	# 队伍只能在陆地上走：点远了就收到岸线以内（走的哪块陆地由上岸点决定）
	if landing_land.is_empty():
		landing_land = sea.world.land_containing(landing_point)
	if landing_land.is_empty():
		landing_land = sea.primary_land()
	if not landing_land.is_empty():
		pos = Geom2D.clamp_inside(landing_land["shape"], pos, 40.0)
	captain_target = pos
	party.move_to(pos)


func party_size() -> int:
	return party.size()


# ------------------------------------------------------------ 日志与报告

func log_event(text: String, tracks_last_line := true) -> void:
	if text.strip_edges() == "":
		return
	log_lines.append(text)
	if log_lines.size() > 40:
		log_lines.pop_front()
	journal.record(t, "log", text, tracks_last_line)


func _say(text: String, important := false, tracks_last_line := true) -> void:
	log_event(text, tracks_last_line)
	if important:
		last_message = text
		message_timer = 12.0


func say(text: String, important := false, tracks_last_line := true) -> void:
	"""给界面用的公开入口（跨类调用私有方法不好，Day 6 已经栽过一次）。"""
	_say(text, important, tracks_last_line)


func tick_ui(real_delta: float) -> void:
	"""界面自己的计时（消息条多久收回去）。

	必须用**真实**时间。第一版把消息计时放在了 tick() 里，于是 ×12 快进时
	"这条 12 秒的消息"实际只亮 1 秒 —— 玩家正看得见风景，字已经没了。
	模拟时间和界面时间是两回事。
	"""
	message_timer = maxf(0.0, message_timer - real_delta)


func report(text: String) -> void:
	"""船上的事：船长在船上就直接告诉他，不在就先攒着（延迟消息）。"""
	if ashore:
		pending_reports.append(text)
	else:
		_say("（报告）" + text, true)


func describe() -> String:
	var dmg := ship.describe_damage()
	return "%s %s　船速 %.1f 节　%s　损伤：%s　%s" % [
		date_string(), clock_string(), ship.speed_kn(), nav.method_name(), dmg,
		"船长在岸上" if ashore else "船长在船上"]


# ------------------------------------------------------------ 存档（docs/14）
# 状态分三层，这里交出的是"一局"的两块：世界（房主权威）与本船（拥有者权威）。
# 每块内部的字段由各自的类负责（Story / VoyageJournal / WindField / ShipDynamics /
# ShipOrders / Navigator / Crew / CrewRoster / CrewMember / LandingParty）。
#
# 静态数据（海域、剧本、物理参数、配平表）**不进存档** —— 读档时 setup() 已经重新加载过。

func capture_world_state() -> Dictionary:
	return {
		"t": t,
		"day": day,
		"wind": wind.capture_state(),
		"fired": fired.duplicate(),
		"island_known": island_known,
		"visited": visited.duplicate(),
		"discovered": discovered.duplicate(),
		"known_places": known_places.duplicate(),
		# 船队：AI 船与"别人的船"的摘要（房主权威，docs/14 第 2 节）
		"fleet": fleet.capture_state(),
		# 港口库存与价格：房主权威（docs/14 第 2 节）
		"ports": ports.capture_state(),
		# M7：自然环境、事件池、知识、世界记忆 —— 同一片海对所有人一样，所以都在世界状态里
		"weather": weather.capture_state(),
		"events": events.capture_state(),
		"knowledge": knowledge.capture_state(),
		"memory": memory.duplicate(),
		"reached_destination": reached_destination,
		"reef_hit": reef_hit,
		"shortage_events": shortage_events,
		"last_message": last_message,
		"message_timer": message_timer,
		"log_lines": log_lines.duplicate(),
		"pending_reports": pending_reports.duplicate(),
		"_shore_cooldown": _shore_cooldown,
		"story": story.capture_state(),
		"journal": journal.capture_state(),
	}


func apply_world_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	t = float(d.get("t", 0.0))
	day = int(d.get("day", 0))
	wind.apply_state(d.get("wind", {}))
	fired = (d.get("fired", {}) as Dictionary).duplicate()
	island_known = bool(d.get("island_known", false))
	visited = (d.get("visited", {}) as Dictionary).duplicate()
	discovered = (d.get("discovered", {}) as Dictionary).duplicate()
	known_places = (d.get("known_places", {}) as Dictionary).duplicate()
	fleet.apply_state(d.get("fleet", []))
	ports.apply_state(d.get("ports", {}))
	weather.apply_state(d.get("weather", {}))
	events.apply_state(d.get("events", {}))
	knowledge.apply_state(d.get("knowledge", {}))
	memory = (d.get("memory", {}) as Dictionary).duplicate()
	reached_destination = bool(d.get("reached_destination", false))
	reef_hit = bool(d.get("reef_hit", false))
	shortage_events = int(d.get("shortage_events", 0))
	last_message = str(d.get("last_message", ""))
	message_timer = float(d.get("message_timer", 0.0))
	log_lines = (d.get("log_lines", []) as Array).duplicate()
	pending_reports = (d.get("pending_reports", []) as Array).duplicate()
	_shore_cooldown = float(d.get("_shore_cooldown", 0.0))
	story.apply_state(d.get("story", {}))
	journal.apply_state(d.get("journal", {}))


func capture_ship_state() -> Dictionary:
	return {
		"id": fleet.local_id,
		"kind": "detailed",
		"ship_name": fleet.name_of(fleet.local_id),
		"ship": ship.capture_state(),
		"orders": orders.capture_state(),
		"nav": nav.capture_state(),
		"crew": crew.capture_state(),
		"roster": roster.capture_state(),
		"ashore": ashore,
		"captain_pos": StateIO.v2(captain_pos),
		"captain_target": StateIO.v2(captain_target),
		"ashore_count": ashore_count,
		"landing_point": StateIO.v2(landing_point),
		"landing_land_id": str(landing_land.get("id", "")),
		"party": party.capture_state(),
		# 货舱与金币是本船状态（拥有者权威，docs/14 第 3 节）
		"cargo": cargo.capture_state(),
		"docked_port": docked_port,
		# 规矩与社会（M5）：每条船有自己的四十个人，所以都算本船状态
		"rules": rules.capture_state(),
		"society": society.capture_state(),
		"dilemmas": dilemmas.capture_state(),
		"ending_score": ending_score.duplicate(),
		"culture": culture.capture_state(),
		# M8 收尾：按 `N` 沿航线走的状态。它是"这条船现在怎么开"，算本船状态；
		# 不存的话，存档时正在跟航线、读档回来就跟丢了（航点没了，船开到下一段就停）。
		"following_route": following_route,
		"route_waypoints": StateIO.v2_list(route_waypoints),
	}


func apply_ship_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	ship.apply_state(d.get("ship", {}))
	orders.apply_state(d.get("orders", {}))
	nav.apply_state(d.get("nav", {}))
	crew.apply_state(d.get("crew", {}))
	roster.apply_state(d.get("roster", {}))
	ashore = bool(d.get("ashore", false))
	captain_pos = StateIO.to_v2(d.get("captain_pos", [0.0, 0.0]))
	captain_target = StateIO.to_v2(d.get("captain_target", [0.0, 0.0]))
	ashore_count = int(d.get("ashore_count", 0))
	landing_point = StateIO.to_v2(d.get("landing_point", [0.0, 0.0]))
	# landing_land 是"上岸点踩在哪块陆地上"。形状本身是静态世界数据，所以只存 id、
	# 读档时按 id 找回来（理由同 docs/14 第 4.2 节的第 2 条：只存会变的值）。
	landing_land = {}
	var land_id := str(d.get("landing_land_id", ""))
	for f in sea.lands():
		if str(f["id"]) == land_id:
			landing_land = f
			break
	party.apply_state(d.get("party", {}), roster)
	cargo.apply_state(d.get("cargo", {}))
	docked_port = str(d.get("docked_port", ""))
	rules.apply_state(d.get("rules", {}))
	society.apply_state(d.get("society", {}))
	dilemmas.apply_state(d.get("dilemmas", {}))
	ending_score = (d.get("ending_score", {}) as Dictionary).duplicate()
	culture.apply_state(d.get("culture", {}))
	following_route = bool(d.get("following_route", false))
	route_waypoints = StateIO.to_v2_list(d.get("route_waypoints", []))
	if following_route and route_waypoints.is_empty():
		following_route = false          # 没剩下航点就没什么可跟的了
	# 航程累计用的"上一帧船位"是派生值：读档后必须对齐到读回来的位置，
	# 否则这一刻会被当成一次瞬移（或者被算成几百米的航程）。
	_prev_pos = ship.position_m()


# ------------------------------------------------------------ 船队存档（M3）
# docs/14 第 4.1 节的 `ships[]`：**本机那条是 detailed（带 40 人名册），
# 其余是 abstract（只有摘要）**。这正是 v0.5 第 2 节第 5 条说的形状 ——
# 存档和网络要的是同一样东西：清楚的状态边界。

func capture_fleet() -> Array:
	var out := [capture_ship_state()]
	for entry in fleet.capture_state():
		out.append(entry)
	return out


func apply_fleet(arr: Array) -> void:
	for raw in arr:
		var d: Dictionary = raw
		if str(d.get("kind", "")) == "detailed":
			apply_ship_state(d)
	# 抽象船那一半由 apply_world_state 里的 fleet.apply_state 负责（它在世界状态里）
