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
var naval: NavalBattle = null      # 海上咬上的那一场（M10，null = 没在打）
var factions := Factions.new()     # M11：六类势力的态度与王室命令
var pursuit := Pursuit.new()       # M11：葡萄牙追捕的当前环（世界状态）
var npcs := NpcShips.new()         # M11：商人/海盗/其他航海者（抽象船，房主推进）
var _npc_cooldown := 0.0           # 一场遭遇之后的冷却（游戏秒）
# 给**测试与教程**用的总开关：关掉之后海面上没有别的船、也不会被追捕。
# 它默认开着 —— 正式玩的时候海盗与葡萄牙人都该在。
# （为什么需要它：有些断言盯的是**航线与风**这类东西，不该因为"半路被截击、
#   船被打慢了"而变红 —— 那是另一套内容，另有断言盯着。）
var encounters_enabled := true
# M13：离开新鲜食物多少航程日（坏血病）/ 连着缺粮缺水多少航程日（断粮致死）。
# 两个都进 ShipState —— 它们是"这条船上的日子"，存读档要跟着走。
var days_since_fresh := 0.0
var days_short := 0.0
var _hurricane_day_rolled := -1     # 飓风季的硬币：每个航程日只掷一次（M13）
# M13：沿航线走时的"磨不动"计时（只影响航线跟随：磨够久就改走下一段）
const ROUTE_STALL_S := 1800.0       # 30 个游戏分钟没有净前进就算了
var _route_stall := 0.0
var _route_stall_pos := Vector2.ZERO
# M13：起火 / 进水（第七处损伤）。`hazard_crew` = 派去救火抢险的人数（0 = 没人管）。
# 状态在 `ship.hazard` 上（跟着船走），这里只管"派了几个人"。
var hazard_crew := 0
var _hazard_acc := 0.0
# M13：搁浅计时 —— 卡在滩上太久（背风岸 + 无风区）就绞缆脱浅（见 `_aground_tick`）。
const AGROUND_LIMIT_H := 12.0
var _aground_t := 0.0
var culture := Culture.new()        # 当地文明的三档态度（M6）
var locals := LocalGroup.new()      # 岛上那伙人（M6 收尾：他们是常驻实体，不是打起来才刷出来的）
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
var _battle_entry_of: Dictionary = {}   # 战斗单位的序号 -> 队形里的下标（打完把状态写回队伍）
var _naval_start_crew := 0              # 这一场海战开打时我们有多少人（收账时用它算伤亡）


func setup(region := Sea.DATA_PATH, ship_id := "trinidad", inherited := {}) -> void:
	region_path = region
	sea.setup(region)
	# 时间尺度：地图是压缩过的（48km ↔ 6000km），日历与补给按**真实航程**算
	VoyageJournal.voyage_time_scale = sea.real_time_scale()
	# 港口经济表跟着海域走（全球图有自己的 ports.json；迷你海域退回大西洋那份）
	ports.setup(sea.ports_path())
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
	# 圆柱世界（M12）：导航官、船、船队插值都按"走最短一边"算
	if sea.wraps():
		nav.wrap_width = sea.size_m().x
		ship.wrap_width = sea.size_m().x
		fleet.wrap_width = sea.size_m().x
	crew = Crew.new(ship)
	roster = CrewRoster.new()
	roster.setup()
	crew.roster = roster
	rules.setup()
	society.setup(roster)
	dilemmas.setup()
	culture.setup()
	factions.setup()
	pursuit.setup()
	npcs.setup(sea)
	# 岛上的当地人：**从一开始就住在村子里**（站位确定性）。打了才少人，不会重新刷满。
	# （老海域没有 village 这个地标就让他们空着 —— 那种世界里也打不起来。）
	if sea.poi_pos("village") != Vector2.ZERO:
		locals.setup(sea.poi_pos("village"), 12)
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
	journal.advance(_prev_pos, pos, sea.dist(_prev_pos, pos))
	_prev_pos = pos
	weather.step(delta, pos)           # 天气先走：它改风、改损伤、改瞭望距离
	# 洋流与背风区：同一个风，在岛后面就是软的；同一片水，在洋流带上自己会动
	ship.current_world = sea.current_at(pos)
	# **天气真的改风**：风暴里同样的信风是 1.9 倍，无风带里只剩两成
	var wind_vec := wind.velocity_world() * sea.lee_factor(pos) * weather.wind_mult()
	# 指挥链路（船长在不在船上都一样：不在就是大副在管）
	# M13：避岸规则的输入 —— 离岸多远、岸在哪边、是不是正顶着干地（见 navigator.gd）
	var shore_info := sea.nearest_shore(pos)
	nav.shore_distance_m = float(shore_info.get("distance_m", INF))
	var shore_delta := sea.delta(pos, shore_info.get("pos", pos))
	nav.shore_bearing_deg = fposmod(rad_to_deg(atan2(shore_delta.y, shore_delta.x)), 360.0)
	nav.blocked = ship.last_blocked
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
		# ⚠️ 冷却按**航程小时**算（M13）：原来是 20 游戏秒 —— 那等于 42 个航程分钟就撞一次。
		# ⚠️ 损伤按**撞击速度**给（M13 长跑第二轮抓到的）：船被洋流按在背风岸上、
		#    速度近零的时候，定值 6% 会把船体 3 天磨到 0%，然后进入
		#    "没速度 → 一直被按着 → 继续磨" 的死循环（背风岸 50 天出不来）。
		#    撞击能量 ∝ v²，这里取线性档：3 节以上才是满 6%，0.4 节只有 0.8%。
		#    这不是改操法（那条仍在等用户拍板），是让损伤与"撞得多重"对得上。
		var dmg := 0.06 * clampf(ship.speed_kn() / 3.0, 0.0, 1.5)
		_shore_cooldown = 6.0 * 3600.0 / VoyageJournal.voyage_time_scale
		if dmg >= 0.005:
			ship.apply_damage("hull", dmg)
			journal.decide("船底蹭上滩头，船体损伤 %.0f%% —— 靠得太近了。" % (dmg * 100.0))
			_say("船底蹭上滩头，木匠皱着眉头看了一眼。", true)
	if not is_client():
		# 世界事件与剧情是**房主权威**：客户端这一块只读（WORLD 包每 0.5 秒覆盖一次）
		_events(delta)
		story.tick(self, delta)
		for msg in story.take_messages():
			# 演出的弹窗只给玩家看，不进"文书最后写下的一条"（否则第三幕的收尾句会被顶掉）
			_say(str(msg), true, false)
	if ashore:
		# 打起来的时候队伍不动：他们在打，不是在走路（队形与战场是同一批人，
		# 队伍要是还在走，画面上就会出现"人一边打仗一边列队前进"）。
		if battle == null or battle.over:
			party.tick(delta)
		captain_pos = party.captain
		_walk_ashore(delta)
		_locals_tick(delta)
		if party.boarding and party.boarded_all():
			_finish_boarding()
	_weather_wear(delta)
	_hazard_tick(delta)
	_aground_tick(delta)
	events.tick(delta, self)
	_consume_supplies(delta)
	if battle != null and not battle.over:
		battle.tick(delta, cargo)
		if battle.over:
			_resolve_battle()
	if naval != null and not naval.over:
		# 海战不走陆地那套单位寻路：它只认识距离、装填与弹药，
		# 挨打的那几下直接落在 `ship` 的三处损伤上（和气动同一条链路）。
		naval.tick(delta, cargo, ship)
		if naval.over:
			_resolve_naval()
	_pursuit_tick(delta)
	_npc_contact_tick(delta)
	_climate_wind_tick()
	_check_fleet_arrival()
	_route_tick(delta)
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
	var d := sea.dist(ship.position_m(), orders.target_point)
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
	var home := goal_port_name()
	_say("【船队】%d 条船都回到了%s。文书把这一路的账摊在桌上。"
		% [fleet.count(), home], true)
	journal.decide("船队抵达%s，远征走完。" % home)
	settle_royal_orders()


# ------------------------------------------------------------ 势力 · 追捕 · 王室命令（M11）

func _pursuit_tick(delta: float) -> void:
	"""追捕按**航程日**走（与补给同一个尺度：60 游戏秒 × 压缩系数 = 一天）。"""
	if not encounters_enabled:
		return
	var days := delta * VoyageJournal.voyage_time_scale / 86400.0
	if days <= 0.0:
		return
	var ev := pursuit.tick(days, in_portuguese_waters())
	if bool(ev.get("entered", false)):
		_say("【葡萄牙】一条巡逻船在视野里 —— 他们看见我们了。", true)
		journal.record(t, "pursuit", "被葡萄牙巡逻船发现。")
		factions.react("portugal", "spy", 1)
	elif bool(ev.get("advanced", false)):
		_say("【葡萄牙】追捕到了下一环：%s。" % Pursuit.ring_name(int(ev["ring"])), true)
		journal.record(t, "pursuit", "追捕进入「%s」。网越收越紧。" % Pursuit.ring_name(int(ev["ring"])))
		# 最后一环就是"被攻击" —— 追到这一步的人不会只是警告你
		if int(ev["ring"]) >= Pursuit.ring_count() and not ashore:
			var r := begin_naval_battle(30, weather.state_id, 0.0)
			if bool(r.get("ok", false)):
				_say("【葡萄牙】他们升起了战旗，炮门推出来了。", true)
				journal.record(t, "pursuit", "葡萄牙人开火。")
				factions.react_all("fire", 1)
	elif bool(ev.get("escaped", false)):
		_say("【葡萄牙】已经三天没看见他们的帆了 —— 甩掉了。", true)
		journal.decide("甩掉了葡萄牙的追捕。")
		memory["escaped_pursuit"] = int(memory.get("escaped_pursuit", 0)) + 1


func latitude() -> float:
	"""船现在在南纬/北纬多少度。**只有带投影的世界（全球图）才有纬度** ——
	平面海域（8km 迷你海、48km 大西洋）返回 0，于是季风与飓风都不参与（那两片海是教程与回归用的）。"""
	if not sea.world.has_projection():
		return 0.0
	return sea.m_to_lonlat(ship.position_m()).y


func _climate_wind_tick() -> void:
	"""M13：季风按"当前纬度 + 日历"灌进风场；飓风季里进那片海是在赌。"""
	if not sea.world.has_projection():
		wind.season_shift_deg = 0.0
		wind.season_gain = 1.0
		return
	var lat := latitude()
	wind.season_shift_deg = Climate.wind_shift_deg(lat, t)
	wind.season_gain = Climate.wind_gain(lat, t)
	var band := Climate.hurricane_band(lat, t)
	if band.is_empty():
		return
	# 已经在坏天气里就不叠加；平静的时候按"日子 + 带子"的确定性硬币赌一把
	if weather.state_id != "clear" and weather.state_id != "calm":
		return
	# ⚠️ **每个航程日只掷一次**：按帧掷的话一进那片海几乎立刻就挨风暴，
	#    "赌"这个选择就没有意义了（它该是"待上十天，多半会碰上一场"）。
	var day := VoyageJournal.day_index(t)
	if day == _hurricane_day_rolled:
		return
	_hurricane_day_rolled = day
	var roll := Ballistics.roll(day, str(band.get("band", "")).hash())
	if roll < 0.10:
		weather.force("storm", float(band.get("hours", 24.0)))
		if not fired.has("hurricane_" + str(band.get("band", ""))):
			fired["hurricane_" + str(band.get("band", ""))] = true
			_say("【天气】%s" % str(band.get("text", "")), true)
			journal.record(t, "weather", "在飓风季里闯进了%s。" % str(band.get("name", "")))


func in_portuguese_waters() -> bool:
	"""船在不在葡萄牙的水域里：离他们那几个据点任一个够近就算。

	M14：**据点外还有巡弋的船** —— 巡逻的发现距离比据点水域再远 `patrol_gap_m`。
	手里有**通行许可**的时候，巡逻当没看见你（只算据点自己的水域）。
	"""
	return bool(_portuguese_watch()["spotted"])


func _portuguese_watch() -> Dictionary:
	"""葡萄牙的眼睛（M14）：据点水域 + 据点外的巡逻船。返回"被看见了没有"。

	它把 M11 的追捕线**接到东方**：莫桑比克 / 马六甲 / 德那第三处据点的旗与巡逻，
	和里斯本那边的追捕是同一条状态机（`Pursuit`）。
	"""
	var here := ship.position_m()
	var out := {"spotted": false, "in_waters": false, "by_patrol": false,
		"outpost": "", "distance_m": INF}
	var permit := pursuit.has_permit()
	# 1) 据点自己的水域（M11 那四个：圣地亚哥 + 东方三个）—— 这一步一条都不许少，
	#    少了它，M11 在佛得角外面的追捕线就断了。
	for pid in Pursuit.waters():
		for p in sea.ports():
			if str(p.get("id", "")) != str(pid):
				continue
			var d := sea.dist(here, Geom2D.centroid(p["shape"]))
			if d < float(out["distance_m"]):
				out["distance_m"] = d
				out["outpost"] = str(p.get("name", pid))
			if d <= Pursuit.water_radius_m():
				out["in_waters"] = true
	# 2) 东方据点外还**巡弋着船**（M14）：发现距离再远 `patrol_gap_m`；有许可就不拦你
	if not permit:
		for o in Pursuit.outposts():
			for p in sea.ports():
				if str(p.get("id", "")) != str((o as Dictionary).get("port", "")):
					continue
				var d2 := sea.dist(here, Geom2D.centroid(p["shape"]))
				if d2 > Pursuit.water_radius_m() \
						and d2 <= Pursuit.water_radius_m() \
							+ float((o as Dictionary).get("patrol_gap_m", 4000.0)):
					out["by_patrol"] = true
					if float(out["distance_m"]) > d2:
						out["distance_m"] = d2
						out["outpost"] = str((o as Dictionary).get("name", ""))
	out["spotted"] = bool(out["in_waters"]) or bool(out["by_patrol"])
	return out


func buy_permit() -> Dictionary:
	"""在葡萄牙**据点**买通行许可（M14）：花钱，之后 `permit_days` 天里巡逻不拦你、
	追捕线也不往前推。

	据点名单与价钱在 `data/defs/factions.json` 的 `outposts`（数值只有一个真源）。
	"""
	if not can_trade_here():
		return {"ok": false, "reason": "先靠港"}
	var o := Pursuit.outpost_for(docked_port)
	if o.is_empty():
		return {"ok": false, "reason": "这里不是葡萄牙据点"}
	if pursuit.has_permit():
		return {"ok": false, "reason": "许可还没到期（还剩 %.0f 天）" % pursuit.permit_days_left}
	var cost := int((o as Dictionary).get("permit_ducats", 260))
	if cargo.money < cost:
		return {"ok": false, "reason": "钱不够（要 %d，有 %d）" % [cost, cargo.money]}
	cargo.money -= cost
	var days := pursuit.grant_permit()
	var where := str((o as Dictionary).get("name", docked_port))
	_say("在%s买了通行许可：%d 枚杜卡特，%d 天之内他们的巡逻不拦你。"
		% [where, cost, int(days)], true)
	journal.decide("在%s买了通行许可（%d 杜卡特 / %.0f 天）。" % [where, cost, days])
	return {"ok": true, "cost": cost, "days": days, "outpost": where}


func permit_report() -> String:
	"""面板要读的一行：有没有许可、还剩几天、最近的是哪个据点。"""
	var w := _portuguese_watch()
	var bits := PackedStringArray()
	if pursuit.has_permit():
		bits.append("通行许可剩 %.0f 天" % pursuit.permit_days_left)
	if bool(w["in_waters"]):
		bits.append("在%s水域里" % str(w["outpost"]))
	elif bool(w["by_patrol"]):
		bits.append("离%s的巡逻 %.1f 公里" % [str(w["outpost"]), float(w["distance_m"]) / 1000.0])
	return "　".join(bits)


func _npc_contact_tick(delta: float) -> void:
	"""别的船在动；海盗够近就咬上来 —— 「被截击」就是这一行。"""
	if not encounters_enabled:
		return
	if _npc_cooldown > 0.0:
		_npc_cooldown = maxf(0.0, _npc_cooldown - delta)
	npcs.tick(delta, sea)
	if ashore or (naval != null and not naval.over) or _npc_cooldown > 0.0:
		return
	var range_m := NpcShips.encounter_range_m()
	var here := ship.position_m()
	var pirate := npcs.nearest_hostile(here, range_m, sea, factions)
	if pirate.is_empty():
		# 不是海盗就不动手：商人和其他航海者只是擦肩而过（写一条消息）
		var other := npcs.nearest_any(here, range_m, sea)
		if not other.is_empty() and str(other["kind"]) != "pirate":
			_say("【海上】%s：%s" % [str(other["name"]), str(other["text"])], true)
			factions.react(str(other["faction"]), "trade", 0)   # 只是看见，不改态度
			npcs.mark_engaged(str(other["id"]), NpcShips.cooldown_s() * 0.5)
			_npc_cooldown = NpcShips.cooldown_s() * 0.5
		return
	var r := begin_naval_battle(int(pirate.get("crew", 30)), weather.state_id, 0.0)
	if bool(r.get("ok", false)):
		npcs.mark_engaged(str(pirate["id"]), NpcShips.cooldown_s())
		_npc_cooldown = NpcShips.cooldown_s()
		_say("【遭遇】%s 朝你压过来 —— %s" % [str(pirate["name"]), str(pirate["text"])], true)
		journal.record(t, "encounter", "海上被%s截击。" % str(pirate["name"]))


func royal_order_ctx() -> Dictionary:
	"""三条王室命令的判定材料 —— 都是这个世界里已经在算的东西。"""
	var visited_ports := []
	for p in sea.ports():
		var id := str(p.get("id", ""))
		if known_places.has(id) or visited.has(id):
			visited_ports.append(id)
	var goods_value := 0.0
	for id in cargo.ids_of_kind("goods"):
		goods_value += float(cargo.qty(str(id))) * float(cargo.item_def(str(id)).get("base_price", 0))
	return {
		"visited_ports": visited_ports,
		"goods_value": goods_value,
		"friendly_kills": int(memory.get("friendly_kills", 0)),
	}


func settle_royal_orders() -> Dictionary:
	var r := factions.settle_orders(royal_order_ctx(), ending_score)
	for nm in (r.get("done", []) as Array):
		_say("【王室】交得出账的一条：%s。" % str(nm), true)
	for nm in (r.get("broken", []) as Array):
		_say("【王室】这一条你违了：%s。" % str(nm), true)
	return r


func pursuit_action(action: String) -> Dictionary:
	"""玩家的四种手段：改线 / 伪装 / 谈判 / 战斗（数值与代价在真源里）。"""
	var r := pursuit.act(action, cargo)
	if not bool(r.get("ok", false)):
		return r
	if bool(r.get("battle", false)):
		journal.decide("对葡萄牙人动了手。")
		factions.react_all("fire", 1)
		return r
	_say("【葡萄牙】%s（现在是「%s」）" % [str(r.get("text", "")), str(r.get("name", ""))], true)
	journal.decide("对付追捕：%s。" % str(r.get("text", "")))
	return r


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
		var d := sea.dist(route_waypoints[i] as Vector2, ship.position_m())
		if d < best_d:
			best_d = d
			best = i
	route_waypoints = route_waypoints.slice(best)
	# 已经站在第一个航点上（刚出港就是这种情况）就别把"去自己脚下"当下一段 ——
	# 不然按 N 会被告知"下一段去 圣卢卡尔"，而人就在圣卢卡尔。
	if best_d < 500.0 and route_waypoints.size() > 1:
		route_waypoints = route_waypoints.slice(1)
	following_route = true
	_route_stall = 0.0
	_route_stall_pos = ship.position_m()
	orders.set_target_point(route_waypoints[0] as Vector2)
	# 顺手把这一段的"要几天 / 路上有什么"告诉玩家（M8 收尾的航线元数据）
	var info := leg_info(_route_of_next())
	var extra := ""
	if not info.is_empty():
		extra = "（%.1f 个航程日%s）" % [float(info["days"]),
			"" if str(info["risk_text"]) == "" else "，要穿过 " + str(info["risk_text"])]
	return "沿航线走：下一段去 %s%s" % [_route_leg_name(), extra]


func _route_of_next() -> Dictionary:
	"""接下来要走的那一段航线数据（给 `N` 的提示用）。"""
	var want := next_port_id()
	for r in sea.routes():
		if str(r.get("to", "")) == want:
			return r
	for r in sea.routes():
		if str(r.get("from", "")) == want:
			return r
	return {}


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


func _route_tick(delta: float) -> void:
	if not following_route:
		return
	if route_waypoints.is_empty():
		following_route = false
		return
	var p := route_waypoints[0] as Vector2
	if sea.dist(ship.position_m(), p) < 500.0:
		if route_waypoints.size() <= 1:
			following_route = false
			# 顺手把"下一步做什么"说清楚：船这会儿还是张着帆的，
			# 不定住就会被流带着走（港外那条几内亚洋流真的能把船送上滩）。
			_say("（航线）到终点港了 —— 按 X 抛锚、P 靠港。", true)
			return
		route_waypoints.pop_front()
		orders.set_target_point(route_waypoints[0] as Vector2)
		_route_stall = 0.0
		_route_stall_pos = ship.position_m()
		_say("（航线）下一段：%s" % _route_leg_name(), false)
		return
	# M13 长跑扫描抓到的：有一段航线会**磨不进最后几百米**（正逆风 + 无风带，
	# 船的速度掉光之后舵效 ∝ 速度²，转不过去 —— 这是 v0.5 就记过的"顶风失速"）。
	# 兜底只动**航线跟随**：磨够久就认下这一段、改走下一段，而不是在那儿待五十天。
	# （操法一个字没改；玩家自己点目标点的时候不受这条影响。）
	var moved := sea.dist(_route_stall_pos, ship.position_m())
	# 阈值取 400 米/30 游戏分钟（≈0.43 节）：低于这个速度**等于没在走** ——
	# 长跑扫描里出现过"0.1–0.2 节爬了几十天、最后被洋流推上背风岸"的船，
	# 120 米的阈值太松，那种船永远够得着。
	if moved > 400.0:
		_route_stall = 0.0
		_route_stall_pos = ship.position_m()
	else:
		_route_stall += delta
		if _route_stall >= ROUTE_STALL_S:
			_route_stall = 0.0
			_route_stall_pos = ship.position_m()
			if route_waypoints.size() <= 1:
				following_route = false
				_say("（航线）最后这一段磨不动 —— 点一个偏开一点的目标点，或者按 X 抛锚。", true)
			else:
				route_waypoints.pop_front()
				orders.set_target_point(route_waypoints[0] as Vector2)
				_say("（航线）这一段磨不进去，改走下一段。", true)


# ------------------------------------------------------------ 补给与港口（M4）

func crew_on_board() -> int:
	"""船上现在有多少人：**在船上且活着的**才算（上岸的由登陆队那本账管）。

	⚠️ M15 修的一处：这里原来只排除 `ashore`，没排除 `dead` —— 死掉的人照样算
	"船上的人"，于是**口粮照吃、摘要里人数照报**。三年尺度上这就露馅了。
	"""
	var n := 0
	for m in roster.members:
		if not m.ashore and not m.dead:
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
		var d := sea.dist(Geom2D.centroid(p["shape"]), ship.position_m())
		if d < best_d:
			best_d = d
			best = id
	return best


func next_port_position() -> Vector2:
	for p in sea.ports():
		if str(p.get("id", "")) == next_port_id():
			return Geom2D.centroid(p["shape"])
	return sea.port_pos()


func next_leg() -> Dictionary:
	"""下一段要走的航线数据。

	靠港时看"从这儿出去的那一段"（那是真的下一段）；在海上时看"通向最近那个港的那一段"。
	"""
	var routes := sea.routes()
	if docked_port != "":
		for r in routes:
			if str(r.get("from", "")) == docked_port:
				return r
	var want := next_port_id()
	for r in routes:
		if str(r.get("to", "")) == want:
			return r
	for r in routes:
		if str(r.get("from", "")) == want:
			return r
	return {}


func leg_info(route := {}) -> Dictionary:
	"""一段航线的"出发前清单"：多远、几天口粮、路上穿过什么天气带、到港什么值得买卖。

	M7 的卡片把"航线元数据（风险/补给/价值）"留给了 M8，这一半在这里补齐：
	  · **补给** —— 图上距离 / 真实公里 / 航程日 / 口粮 / 淡水（`supply_need_for`，早就有）
	  · **风险** —— 这一段穿过哪些天气带、哪些带要小心（从 `weather.json` 的 `bands` 现推）
	  · **价值** —— 终点港什么好卖、什么好买（从 `ports.json` 的 `mul` 现推）

	三样都是**推出来的**，不另写一份表 —— 玩家看到的就是他真会遇上的那份数据。
	"""
	if route.is_empty():
		route = next_leg()
	if route.is_empty():
		return {}
	var pts := sea.route_points(route)
	var dist := Geom2D.path_length(pts)
	var need := supply_need_for(dist)
	var risky := Weather.risky_bands_on(pts)
	var to_id := str(route.get("to", ""))
	var trade: Dictionary = ports.best_trades(to_id) if to_id != "" else {"sell": [], "buy": []}
	return {
		"id": str(route.get("id", "")),
		"name": str(route.get("name", "")),
		"from": _port_display(str(route.get("from", ""))),
		"to": _port_display(to_id),
		"map_km": dist / 1000.0,
		"real_km": dist / 1000.0 * sea.real_time_scale(),
		"days": float(need["days"]),
		"food": int(need["food"]),
		"water": int(need["water"]),
		"risky": risky,
		"risk_text": _bands_display(risky),
		"sell": _item_names(trade["sell"]),
		"buy": _item_names(trade["buy"]),
		"note": str(route.get("note", route.get("text", ""))),
	}


func _port_display(id: String) -> String:
	for p in sea.ports():
		if str(p.get("id", "")) == id:
			return str(p.get("name", id))
	return id


func _bands_display(bands: Array) -> String:
	var parts := PackedStringArray()
	for b in bands:
		parts.append(Weather.band_states_text(b))
	return "、".join(parts)


func _item_names(ids: Array) -> Array:
	var out := []
	for id in ids:
		out.append(Ports.item_name(str(id)))
	return out


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
	# --- M13：坏血病 / 断粮断水 / 船体老化（都按**航程日**算）---
	days_since_fresh += days
	var short_food := int(r["want_food"]) - int(r["got_food"])
	var short_water := int(r["want_water"]) - int(r["got_water"])
	days_short = days_short + days if (short_food > 0 or short_water > 0) else 0.0
	_climate_health_tick(days, short_food > 0, short_water > 0)
	_wear_tick(days)
	_sea_repair(days)


func _climate_health_tick(days: float, short_food: bool, short_water: bool) -> void:
	"""坏血病与断粮断水的长期后果：健康按天掉，见底就死人。

	门槛与速率全部来自 `climate.json`（铁律：数值只有一个真源）。
	"""
	var scurvy_h := Climate.scurvy_health_per_day(days_since_fresh)
	var scurvy_m := Climate.scurvy_mood_per_day(days_since_fresh)
	var att_h := 0.0
	if days_short >= Climate.attrition_grace_days():
		att_h = Climate.attrition_health_per_day(short_food, short_water)
	if scurvy_h <= 0.0 and att_h <= 0.0 and scurvy_m <= 0.0:
		return
	var deaths := 0
	var threshold := Climate.death_health()
	for m in roster.members:
		if m.dead:
			continue
		m.health = clampf(m.health - (scurvy_h + att_h) * days, 0.0, 1.0)
		m.mood = clampf(m.mood - scurvy_m * days, 0.0, 1.0)
		if m.health <= threshold:
			_kill_of_the_sea(m)
			deaths += 1
	if deaths > 0:
		fired["attrition_deaths"] = int(fired.get("attrition_deaths", 0)) + deaths
		if not fired.has("attrition_first"):
			fired["attrition_first"] = true
			_say("【讣告】这一趟海上带走了 %d 个人 —— 咸肉和饼干留不住人。" % deaths, true)
			journal.decide("长期只吃咸肉与饼干，船上开始死人。")


func _kill_of_the_sea(m: CrewMember) -> void:
	"""海上病死（与陆战、海战共用同一条写回链：名册 → 讣告 → 结算）。"""
	m.dead = true
	m.health = 0.0
	m.job = "dead"
	ending_score["crew"] = int(ending_score.get("crew", 0)) - 1
	_say("【讣告】%s 没能撑到下一个港。" % m.label(), true)
	journal.record(t, "death", "讣告：%s 死于长期的咸肉与坏血病。" % m.label())
	fired["lost_" + m.id] = true


func _wear_tick(step_days: float) -> void:
	"""船体老化：在海上过了 start_day 个航程日之后，每一类损伤按天累一点。"""
	var days_at_sea := t * VoyageJournal.voyage_time_scale / 86400.0
	var wear := Climate.wear_for_day(days_at_sea)
	for part in wear.keys():
		ship.apply_damage(str(part), float(wear[part]) * step_days)


func _sea_repair(step_days: float) -> void:
	"""**海上自修**（M13 卡片里"长期磨损与修补"的另一半，M15 落地）。

	木匠带着人在航行中捻缝、补帆、换缆：慢、吃木料与帆布、人手不够就不干。
	长跑抓到的账：太平洋那一整段（约 130 个航程日）没有港口 ——
	只靠"靠港修"是撑不过去的，而真船上本来就有这一手。

	材料按**真的修了多少**折算：修满一天的量就吃一天的量，修不满就少扣。
	"""
	var cfg: Dictionary = Climate.defs().get("sea_repair", {})
	if cfg.is_empty():
		return
	if crew_on_board() < int(cfg.get("min_crew", 8)):
		return
	var total_per_day := 0.0
	for part in ["hull", "mast", "sail"]:
		total_per_day += maxf(0.0, float(cfg.get("%s_per_day" % part, 0.0)))
	if total_per_day <= 0.0:
		return
	# 先算这一次能修多少（受"每天的修复量"和"实际损伤"两头限制）
	var plan := {}
	var fixed_total := 0.0
	for part in ["hull", "mast", "sail"]:
		var per_day := maxf(0.0, float(cfg.get("%s_per_day" % part, 0.0)))
		var have := ship.damage_of(part)
		if per_day <= 0.0 or have <= 0.001:
			continue
		var done := minf(per_day * step_days, have)
		plan[part] = done
		fixed_total += done
	if fixed_total <= 0.0:
		return
	# 材料：按"修了多少 / 一天能干多少"折算（攒小数，见 Cargo.spend_fraction）
	var work := clampf(fixed_total / (total_per_day * step_days), 0.0, 1.0)
	var wood := float(cfg.get("wood_per_day", 0.0)) * step_days * work
	var canvas := float(cfg.get("canvas_per_day", 0.0)) * step_days * work
	# 料要两样都够（够不着就这一轮不修 —— 不能"扣了木头没帆布"白扣一半）
	var need := {}
	if wood > 0.0:
		need["wood"] = wood
	if canvas > 0.0:
		need["canvas"] = canvas
	if not need.is_empty() and not bool(cargo.can_pay(need)["ok"]):
		return
	for k in need.keys():
		cargo.spend_fraction(str(k), float(need[k]))
	for part in plan.keys():
		ship.apply_damage(str(part), -float(plan[part]))


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


func _hazard_tick(delta: float) -> void:
	"""起火与进水（M13，docs/22 第 5.4 节的第七处）：每 60 游戏秒（= 0.5 航程小时）结算一次。

	它**不是损伤值，是状态**：不派人 → 强度自己涨、还持续烧/灌；派人 → 按人头压下去。
	强度涨到真源的 `loss_at` 这条船就保不住了（换旗舰是 M16 的事，这里先把旗标立起来）。
	"""
	if not ship.hazard_any():
		_hazard_acc = 0.0
		return
	_hazard_acc += delta
	if _hazard_acc < 60.0:
		return
	var hours := 60.0 * VoyageJournal.voyage_time_scale / 3600.0
	_hazard_acc = 0.0
	var hands_left := maxi(0, hazard_crew)
	var total := ship.hazard_of("fire") + ship.hazard_of("flood")
	for part in ["fire", "flood"]:
		var h := ship.hazard_of(part)
		if h <= 0.0:
			continue
		var cfg: Dictionary = ship.physics.hazard.get(part, {})
		# 派人：按这一处在总强度里的占比分人手（两处同时着火就一人一半）
		var share := (h / total) if total > 0.0 else 0.0
		var fight := float(cfg.get("fight_per_hour_per_hand", 0.0)) * float(hands_left) * share
		var spread := float(cfg.get("spread_per_hour", 0.0))
		ship.hazard[part] = clampf(h + (spread - fight) * hours, 0.0, 1.0)
		# 持续恶化：火往帆索上烧、水往船壳与货里灌（"上层看得见"就落在这条链上）
		if part == "fire":
			ship.apply_damage("hull", float(cfg.get("burn_hull_per_hour", 0.0)) * hours)
			ship.apply_damage("mast", float(cfg.get("burn_mast_per_hour", 0.0)) * hours)
			ship.apply_damage("sail", float(cfg.get("burn_sail_per_hour", 0.0)) * hours)
		else:
			ship.apply_damage("hull", float(cfg.get("ingress_hull_per_hour", 0.0)) * hours)
			ship.apply_damage("hold", float(cfg.get("soak_hold_per_hour", 0.0)) * hours)
			var lost := cargo.spoil(float(cfg.get("soak_hold_per_hour", 0.0)) * hours)
			if lost > 0:
				_say("海水泡掉了 %d 件货。" % lost, true)
	# 抢险的人累、也怕（士气按人·小时掉一点）
	if hands_left > 0:
		var mood_cost := float(ship.physics.hazard.get("crew_mood_per_hour", 0.02)) * hours
		for m in roster.members:
			if not m.dead:
				m.mood = clampf(m.mood - mood_cost, 0.0, 1.0)
	# 压不住了：船保不住（换旗舰与轻编队是 M16；这里先把旗标与讣闻立起来）
	var loss_at := float(ship.physics.hazard.get("loss_at", 1.0))
	if not fired.has("ship_lost") \
			and (ship.hazard_of("fire") >= loss_at or ship.hazard_of("flood") >= loss_at):
		fired["ship_lost"] = true
		if ship.hazard_of("fire") >= loss_at:
			_say("【危难】火压不住了 —— 这条船保不住了。", true)
			journal.decide("甲板上的火没扑灭，船保不住了。")
		else:
			_say("【危难】水压不住了 —— 这条船在往下沉。", true)
			journal.decide("水线下的破口堵不住，船在往下沉。")


func fight_hazard(hands: int) -> Dictionary:
	"""派人去救火 / 抢险（0 就是把人都撤回来）。返回这一决定的现状。"""
	hazard_crew = clampi(hands, 0, _alive_crew_count())
	if hazard_crew == 0:
		_say("没人管火与水 —— 它们会自己长大。", true)
	else:
		_say("派了 %d 个人去救火抢险。" % hazard_crew, true)
	return {
		"ok": true, "hands": hazard_crew,
		"fire": ship.hazard_of("fire"), "flood": ship.hazard_of("flood"),
	}


func hazard_report() -> String:
	if not ship.hazard_any():
		return ""
	var bits := PackedStringArray()
	if ship.hazard_of("fire") > 0.001:
		bits.append("起火 %.0f%%" % (ship.hazard_of("fire") * 100.0))
	if ship.hazard_of("flood") > 0.001:
		bits.append("进水 %.0f%%" % (ship.hazard_of("flood") * 100.0))
	if hazard_crew > 0:
		bits.append("抢险 %d 人" % hazard_crew)
	return "　".join(bits)


func _aground_tick(delta: float) -> void:
	"""搁浅太久就**绞缆脱浅**（M13，自拍可否决 —— docs/07 的待决问题）。

	为什么要有它：长跑扫描里船被按在巴塔哥尼亚的背风岸上，那一片是被陆地挡住的无风区
	（`lee_factor`），帆使不上劲、洋流又把船往岸上推 —— 避岸规则能避免"磨死"，
	但出不来。现实里的水手这时候放小艇把锚带出去，绞回来脱浅；这里就补这一下。

	触发条件：贴着干地 + 几乎不动，连续 12 个航程小时。代价：全员士气掉一点。
	"""
	if not ship.last_blocked or ship.speed_kn() > 0.5:
		_aground_t = 0.0
		return
	_aground_t += delta
	if _aground_t < AGROUND_LIMIT_H * 3600.0 / VoyageJournal.voyage_time_scale:
		return
	_aground_t = 0.0
	var offing := _find_offing()
	if not bool(offing.get("ok", false)):
		return
	var away: Vector2 = offing["away"]
	ship.kedge_off(offing["pos"], rad_to_deg(atan2(away.y, away.x)))
	_say("放小艇把锚带出去，绞了半天 —— 船终于离开了滩头。", true)
	journal.decide("搁浅太久，靠抛锚绞缆把船拖了出来。")
	for m in roster.members:
		if not m.dead:
			m.mood = clampf(m.mood - 0.03, 0.0, 1.0)


func _find_offing() -> Dictionary:
	"""找一处**离岸足够远的水面**当脱浅目标（顺着"从岸指向船"的方向往外找）。"""
	var pos := ship.position_m()
	var shore := sea.nearest_shore(pos)
	var away: Vector2 = pos - shore.get("pos", pos)
	if away.length() < 1.0:
		away = Vector2(1.0, 0.0)
	away = away.normalized()
	for k in 12:
		var dir := away.rotated(TAU * float(k) / 12.0)
		for d in [700.0, 1200.0, 2000.0]:
			var p: Vector2 = sea.wrap_pos(pos + dir * d)
			if sea.world.is_dry_land(p):
				continue
			if float(sea.nearest_shore(p)["distance_m"]) >= 600.0:
				return {"ok": true, "pos": p, "away": dir}
	return {"ok": false}


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
	# **不凭空造人**：船员侧用岸上队形里每个人真正站的位置，当地人侧直接把岛上
	# 那批 Unit 交过去（同一个对象，不是复制品）—— 所以画面上不会有"新刷出来的人"，
	# 打完少的人也是真的少了。`locals_count` 只在岛上那批人为空时兜底。
	# 岛上的那批人离得近才用他们（真实玩法里就是"他们围上来"那一下，最近的人已在 120 米内）；
	# 离得远（脚本或测试直接在这儿开一场仗）就退回老的兜底布置 —— 否则一仗要先走几十公里碰面。
	var use_locals: Array = []
	if not locals.units.is_empty() and locals.nearest_distance(captain_pos) <= 600.0:
		use_locals = locals.units
	battle.setup(squad, locals_count, w, captain_pos, _crew_positions(squad), use_locals)
	var load := Weapons.describe_loadout(Weapons.loadout_for(squad))
	_say("【遭遇】当地人围了上来（%d 人对 %d 人）。你们带着：%s。" % [
		locals_count, squad.size(), load], true)
	journal.record(t, "battle", "上岸遭遇：%d 名当地人对 %d 名船员。" % [locals_count, squad.size()])
	if culture.stance("green_cape") != Culture.HOSTILE:
		culture.shift("green_cape", -0.15, "冲突")
	return {"ok": true, "locals": locals_count, "crew": squad.size(), "loadout": load}


func battle_report() -> String:
	return battle.describe() if battle != null else ""


# ------------------------------------------------------------ 海战（M10）

func begin_naval_battle(foe_crew := 40, foe_weather := "", gap := 0.0) -> Dictionary:
	"""海上咬上了。玩家在自己那条船上指挥 —— 所以船长必须在船上。

	**受击方权威**：这一场里"我们挨的那几下"由本机结算（`NavalBattle._take_hits`），
	"对面挨的那几下"由对面那一侧的机器结算（单机就是同一个 `foe_apply`）。
	联机的双进程对账是 M10 剩下的活（docs/23 的 M10 卡片）。

	海盗船本身在 M11 才有真正的 NPC 船；这一期先用一个明确的入口把遭遇接进来
	（主场景按 `V`），M11 把"被截击"变成世界自己发生的事。
	"""
	if naval != null and not naval.over:
		return {"ok": false, "reason": "海上已经打起来了"}
	if ashore:
		return {"ok": false, "reason": "船长在岸上 —— 船上的事交给大副了"}
	var crew_now := _alive_crew_count()
	if crew_now <= 0:
		return {"ok": false, "reason": "船上没人了"}
	var w := foe_weather if foe_weather != "" else weather.state_id
	var g := gap if gap > 0.0 else float(Ballistics.naval().get("start_gap_m", 900.0))
	_naval_start_crew = crew_now
	naval = NavalBattle.new()
	naval.setup(crew_now, foe_crew, w, g)
	naval.own_id = fleet.local_id
	naval.guns_own.powder_wet = weather.misfire_weather() == "rain"
	# M13：弹药区还坏着的话，这一仗一开始就少几门炮能打（第七处损伤的"战斗力下降"）
	naval.guns_own.magazine_damage = ship.damage_of("magazine")
	# 联机：开火改成"把这一轮交给受击方的拥有者"（谁挨打谁判）
	if link != null and link.session != null and link.session.is_online():
		naval.fire_delegate = Callable(self, "naval_send_volley")
	_say("【海战】一条船从雾里冲出来（%d 人对 %d 人）。炮组就位。" % [crew_now, foe_crew], true)
	journal.record(t, "naval", "海上遭遇：%d 名船员对 %d 名敌人。" % [crew_now, foe_crew])
	return {"ok": true, "crew": crew_now, "foe": foe_crew, "gap_m": g, "weather": w}


func naval_report() -> String:
	if naval == null:
		return ""
	var st := naval.stats()
	return "距离 %d 米　我方 %d 人　对面 %d 人　船壳 %.0f%%" % [
		int(st["gap_m"]), int(st["own_crew"]), int(st["foe_crew"]),
		(1.0 - float(st["own_hull"])) * 100.0]


func naval_send_volley() -> Dictionary:
	"""联机：把这一轮舷侧**交给受击方的拥有者**去判。

	弹药是开火方自己的账（本机先付掉、炮位进入装填），命中和伤亡不在这里算 ——
	算完由受击方权威广播回来（`NetProtocol.NAVAL`），本机记到"对面挨了什么"那本账上。
	"""
	if naval == null or naval.over:
		return {}
	naval.own_id = fleet.local_id
	var req := naval.volley_request()
	var guns: Array = req.get("guns", [])
	if guns.is_empty():
		return {}
	for g in naval.guns_own.ready_guns():
		Weapons.pay_ammo(cargo, str(g["id"]))
		g["reload_t"] = 0.0
		g["loaded"] = false
	naval.guns_own.shots_fired = int(naval.guns_own.shots_fired) + guns.size()
	if link != null:
		link.send_fire(req)
	return req


func naval_start_vs(foe_ship_id: String, foe_crew := 40, gap := 300.0) -> Dictionary:
	"""起一场**对着某条具体船**的海战（联机对账用：对手是另一个玩家那条船）。"""
	var r := begin_naval_battle(foe_crew, "", gap)
	if bool(r.get("ok", false)) and naval != null:
		naval.foe_id = foe_ship_id
		r["foe_id"] = foe_ship_id
	return r


func _alive_crew_count() -> int:
	"""还能干活的人：**活着 + 在船上**（岸上的不算 —— 他们不在船上操帆）。

	海战/点人数用它；"生还人数"（结算那本账）另算（`Settlement` 数的是 `not dead`）。
	"""
	var n := 0
	for m in roster.members:
		if not m.dead and not m.ashore:
			n += 1
	return n


func _living_members() -> Array:
	var out := []
	for m in roster.members:
		if not m.dead:
			out.append(m)
	return out


func _resolve_naval() -> void:
	"""打完收账：伤员与阵亡写回名册（和陆战同一条链），损伤已经落在船上。"""
	var st := naval.stats()
	var losses := maxi(0, _naval_start_crew - int(st["own_crew"]))
	# M13：货舱被打漏 → 一部分货当场泡掉（第七处损伤的"货物损失"）。
	# 之后只要 `damage.hold` 还挂着，`_hazard_tick`/`_consume_supplies` 会继续泡。
	if naval.hold_damage > 0.02:
		var spoiled := cargo.spoil(naval.hold_damage * 0.4)
		if spoiled > 0:
			_say("货舱灌了水 —— %d 件货泡烂了。" % spoiled, true)
	var living := _living_members()
	var surgeon := false
	for m in roster.key_crew():
		if m.post == "外科医生" and not m.dead:
			surgeon = true
	var meds := cargo.qty("medicine")
	var saved := 0
	var lost := 0
	var idx := living.size() - 1
	for i in losses:
		if idx < 0:
			break
		var m2: CrewMember = living[idx]
		idx -= 1
		if surgeon and meds > 0 and i % 2 == 0:
			meds -= 1
			cargo.remove("medicine", 1)
			m2.health = minf(m2.health, 0.45)
			saved += 1
		else:
			m2.dead = true
			m2.health = 0.0
			m2.job = "dead"
			ending_score["crew"] = int(ending_score.get("crew", 0)) - 1
			_say("【讣告】%s 在海上阵亡。" % m2.label(), true)
			journal.record(t, "death", "讣告：%s 在海上阵亡。" % m2.label())
			fired["lost_" + m2.id] = true
			lost += 1
	var head := "海战结束：%s。" % str(st["outcome"])
	if saved > 0:
		head += "外科医生救回了 %d 个人。" % saved
	if lost > 0:
		head += "有 %d 个人没救回来。" % lost
	_say(head, true)
	journal.decide("海上打了一仗：倒 %d、阵亡 %d、对面剩下 %d 人（结果 %s）。" % [
		losses, lost, int(st["foe_crew"]), str(st["outcome"])])
	memory["naval"] = int(memory.get("naval", 0)) + 1
	if str(st["outcome"]) == "won":
		ending_score["history"] = int(ending_score.get("history", 0)) + 1
		memory["prize"] = int(memory.get("prize", 0)) + 1
	elif str(st["outcome"]) == "lost":
		ending_score["history"] = int(ending_score.get("history", 0)) - 1
	naval = null


func _crew_positions(squad: Array) -> Array:
	"""岸上这些人**现在站在哪儿** —— 战斗就用这些站位起手，不许凭空排队。

	队伍（`party.entries`）里关键船员带着 `crew` 引用，普通水手是匿名的（`crew == null`），
	所以先按引用配，配不上的（水手）按顺序认领一个还没用过的匿名位。
	"""
	var out := []
	var claimed := {}
	_battle_entry_of.clear()
	for m in squad:
		var at := Vector2.ZERO
		var found := false
		var idx := -1
		for i in party.entries.size():
			if party.entries[i].get("crew") == m:
				at = party.entries[i]["pos"]
				idx = i
				found = true
				break
		if not found:
			for i in party.entries.size():
				if party.entries[i].get("crew") != null or claimed.has(i):
					continue
				claimed[i] = true
				at = party.entries[i]["pos"]
				idx = i
				found = true
				break
		out.append(at if found else captain_pos)
		_battle_entry_of[out.size() - 1] = idx
	return out


func _sync_party_casualties() -> void:
	"""把战斗结果写回岸上的队形：倒下/阵亡的人那几个点也要跟着变灰、不再站着。

	不然会出现"名字已经在讣告里、人却还站在队列里"的怪画面（队伍的点是玩家一直看着的那批）。
	**站位也要写回**：战斗结束之后画面从"战场"切回"队形"，位置接着战斗结束那一刻，
	不会跳回开打前站的地方（那样又是一次瞬移）。
	"""
	var crew := battle.crew_units()
	for i in crew.size():
		var u = crew[i]
		var idx: int = int(_battle_entry_of.get(i, -1))
		if idx >= 0 and idx < party.entries.size():
			party.entries[idx]["pos"] = u.pos
			if u.state == "down" or u.state == "dead":
				party.entries[idx]["state"] = str(u.state)


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
	# 岸上那几个点跟着伤亡变（谁倒下了、谁没回来）
	_sync_party_casualties()
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
	# M13：靠港就能弄到新鲜东西（水果、活的家禽、岸上的菜）—— 坏血病的计时在这里清零
	days_since_fresh = 0.0
	# M13：港里有水泵与救火的人手 —— 一进港，火与水都了结（不然可以在港里看着船烧掉）
	if ship.hazard_any():
		_say("靠港之后，码头上的人帮着把火扑灭、把水抽干。", true)
		journal.decide("港里的人搭了把手：火与水都了结了。")
		ship.hazard["fire"] = 0.0
		ship.hazard["flood"] = 0.0
		hazard_crew = 0
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

	M14：**客户端也能交易了** —— 走两段式（申请 → 房主执行库存 → 回执 →
	申请方落到自己的货舱）。港口库存仍然只有房主能写，`docs/17` 第 8 节那条限制到此解除。
	"""
	# M7：因果链里那一环 —— 坏名声会让港口不做你的生意（`ports_refuse`）
	return docked_port != "" and not fired.has("ports_refuse")


func host_execute_trade(req: Dictionary) -> Dictionary:
	"""两段式交易的第一段（**房主**）：只动港口库存那一半，并回一份价格清单。

	船上的货与钱不在这里动 —— 那是拥有者权威（`client_apply_trade`）。
	申请里带的钱 / 舱位 / 存货是**船主自报**的数（铁律 11：船的账由船主报），
	房主的职责是守住港口那一本（校验与报价都走 `Ports.check_*`，只有这一份口径）。
	"""
	var port := str(req.get("port", docked_port))
	var item := str(req.get("item", ""))
	var n := int(req.get("n", 0))
	var side := str(req.get("side", "buy"))
	if n <= 0 or item == "":
		return {"ok": false, "reason": "数量或货不对"}
	if not ports.has_port(port):
		return {"ok": false, "reason": "没有这个港口"}
	var r := {}
	if side == "buy":
		r = ports.check_buy(port, item, n, int(req.get("money", 0)), float(req.get("free_kg", 0.0)))
		if bool(r.get("ok", false)):
			ports.apply_buy(port, item, n)
			r["total"] = int(r["cost"])
			journal.decide("有人从%s买走 %d %s。" % [port, n, ports.item_name(item)])
	else:
		r = ports.check_sell(port, item, n, int(req.get("have", 0)))
		if bool(r.get("ok", false)):
			ports.apply_sell(port, item, n)
			r["total"] = int(r["gain"])
			journal.decide("有人往%s卖了 %d %s。" % [port, n, ports.item_name(item)])
	r["side"] = side
	r["port"] = port
	return r


func client_apply_trade(payload: Dictionary) -> Dictionary:
	"""两段式交易的第二段（**申请方**）：把货与钱落到自己的货舱。

	钱与货是拥有者权威，所以只有这一侧能写它 —— 房主只碰库存。
	"""
	var res: Dictionary = payload.get("result", {})
	if not bool(res.get("ok", false)):
		_say("这笔买卖没成：%s" % str(res.get("reason", "")), true)
		return res
	var item := str(res.get("item", ""))
	var n := int(res.get("qty", 0))
	var total := int(res.get("total", 0))
	if str(res.get("side", "buy")) == "buy":
		if cargo.money < total:
			return {"ok": false, "reason": "钱不够（要 %d，有 %d）" % [total, cargo.money]}
		if not cargo.fits(item, n):
			return {"ok": false, "reason": "装不下了"}
		cargo.money -= total
		cargo.add(item, n)
		_say("在%s买下 %d %s（%d 杜卡特）。" % [docked_port, n, cargo.item_name(item), total], true)
	else:
		if not cargo.has(item, n):
			return {"ok": false, "reason": "船上只有 %d" % cargo.qty(item)}
		cargo.remove(item, n)
		cargo.money += total
		_say("把 %d %s卖给了%s（+%d 杜卡特）。" % [n, cargo.item_name(item), docked_port, total], true)
	return res


func port_buy(item: String, n: int) -> Dictionary:
	if not can_trade_here():
		return {"ok": false, "reason": "只能在靠港时交易"}
	if is_client():
		# M14 两段式：本机先自检（钱与舱位是拥有者权威），再请房主动库存
		var unit := ports.buy_price(docked_port, item)
		if cargo.money < unit * n:
			return {"ok": false, "reason": "钱不够（要 %d，有 %d）" % [unit * n, cargo.money]}
		if not cargo.fits(item, n):
			return {"ok": false, "reason": "装不下了"}
		if link != null:
			link.send_trade_request({"ship_id": fleet.local_id, "port": docked_port,
				"item": item, "n": n, "side": "buy",
				"money": cargo.money, "free_kg": cargo.free_kg()})
		return {"ok": true, "pending": true, "qty": n, "unit": unit}
	var r := ports.buy(docked_port, item, n, cargo)
	if bool(r.get("ok", false)):
		_say("买了 %d %s %s，花了 %d 金币。" % [
			int(r["qty"]), cargo.item_name(item), cargo.item_unit(item), int(r["cost"])], true)
	return r


func port_sell(item: String, n: int) -> Dictionary:
	if not can_trade_here():
		return {"ok": false, "reason": "只能在靠港时交易"}
	if is_client():
		if not cargo.has(item, n):
			return {"ok": false, "reason": "船上只有 %d" % cargo.qty(item)}
		if link != null:
			link.send_trade_request({"ship_id": fleet.local_id, "port": docked_port,
				"item": item, "n": n, "side": "sell", "have": cargo.qty(item)})
		return {"ok": true, "pending": true, "qty": n}
	var r := ports.sell(docked_port, item, n, cargo)
	if bool(r.get("ok", false)):
		_say("卖了 %d %s %s，得到 %d 金币。" % [
			int(r["qty"]), cargo.item_name(item), cargo.item_unit(item), int(r["gain"])], true)
	return r


func port_supply_bundle(margin := 1.15) -> Dictionary:
	"""一键补给：按"开到下一个港要多少"买齐，留一点余量。"""
	if not can_trade_here():
		return {"ok": false, "reason": "先靠港"}
	var need := supply_need_for(sea.dist(next_port_position(), ship.position_m()))
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
		var names := {
			"hull": "船体", "mast": "桅杆", "rudder": "舵", "sail": "风帆",
			"hold": "货舱", "magazine": "弹药区",
		}
		_say("修好了 %s 的 %.0f%%。" % [
			names.get(part, part),
			do_amount * 100.0], true)
		journal.decide("在%s修船：%s %.0f%%。" % [port_name(),
			names.get(part, part), do_amount * 100.0])
	return r


func port_sell_knowledge(category: String, id: String) -> Dictionary:
	"""卖一条海图 / 情报（M14）：换钱、记进世界记忆，**买方态度真的变**。

	同一条只能卖一次（`Knowledge.sold`）—— 不然能在同一个港反复换钱。
	价格按类别给（`resources.json` 的 `knowledge_price`），数值只有一个真源。
	"""
	if not can_trade_here():
		return {"ok": false, "reason": "先靠港"}
	if not knowledge.has(category, id):
		return {"ok": false, "reason": "船上没有这条知识"}
	if knowledge.is_sold(category, id):
		return {"ok": false, "reason": "这条已经卖过了"}
	var table: Dictionary = Cargo.defs_data().get("knowledge_price", {})
	var price := int(maxf(1.0, round(float(table.get(category, 60)))))
	cargo.money += price
	knowledge.mark_sold(category, id)
	memory["sold_charts"] = int(memory.get("sold_charts", 0)) + 1
	# 买方行为真的变：商人的反应表里 `trade` 是 +0.04 —— 卖情报给他们，他们记这份情
	factions.react("merchants", "trade", 1)
	_say("把这条情报卖给了%s，换回 %d 枚杜卡特。" % [port_name(), price], true)
	journal.decide("卖了一条知识（%s）：%d 杜卡特。" % [knowledge.category_name(category), price])
	return {"ok": true, "price": price, "category": category, "id": id}


func port_recruit(n := 1, cost_each := 40) -> Dictionary:
	"""在港口招人（M14）：花钱、上人 —— 来源地决定技能的中心值。

	招来的人是**真的名册成员**：有岗位、有技能、进存档、进结算的生还人数。
	"""
	if not can_trade_here():
		return {"ok": false, "reason": "先靠港"}
	if n <= 0:
		return {"ok": false, "reason": "招几个？"}
	var cost := n * cost_each
	if cargo.money < cost:
		return {"ok": false, "reason": "钱不够（要 %d，有 %d）" % [cost, cargo.money]}
	var port := sea.port_at(ship.position_m())
	var origin := str(port.get("faction", ""))
	var center := 0.42
	if origin == "西班牙" or origin == "葡萄牙":
		center = 0.52
	elif origin == "当地":
		center = 0.46
	cargo.money -= cost
	var people := roster.recruit(n, center, origin)
	var ids := []
	for m in people:
		ids.append(m.id)
	_say("在%s招了 %d 个人上船。" % [port_name(), n], true)
	journal.decide("在%s补了 %d 名水手（每人 %d 杜卡特）。" % [port_name(), n, cost_each])
	return {"ok": true, "count": n, "cost": cost, "ids": ids}


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
			# ⚠️ M15：**终点那一个航点不加偏移**。偏移只是为了让三条 AI 船别叠在一起，
			# 可它一旦加到终点上，船就停在锚地圈（`Fleet.ARRIVE_RADIUS_M` = 900 米）外面 ——
			# 那条船永远不算"抵达"，全队结算也就永远签不了（环球一圈回来时尤其明显）。
			if a.waypoints.size() > 0:
				a.waypoints[a.waypoints.size() - 1] = target
			a.target = target
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
	M15 起：全球图的航线**首尾相接**（最后一段回到塞维利亚），这时终点就是**归乡港** ——
	环球一圈回到出发港才算走完（`home_port_id()`）。
	"""
	var home := home_port_id()
	if home != "":
		for p in sea.ports():
			if str(p.get("id", "")) == home:
				return Geom2D.centroid(p["shape"])
	var ports := sea.ports()
	if ports.size() > 0:
		return Geom2D.centroid(ports[ports.size() - 1]["shape"])
	var isl := sea.island()
	if not isl.is_empty():
		var c: Array = isl.get("center", [0, 0])
		return Vector2(float(c[0]), float(c[1]))
	return Vector2.ZERO


func home_port_id() -> String:
	"""这一片海的**归乡港**（M15）：航线首尾相接时，它就是出发港。

	判据只看数据：`routes.json` 最后一段的 `to` == 第一段的 `from`，而且那个 id 真是港口。
	大西洋（v0.5）与迷你海是**单程**航线（塞维利亚 → 巴西），返回空 ——
	那两片海仍然按"最后一个港"走，v0.5 的验收一条都不动。
	"""
	var routes := sea.routes()
	if routes.size() < 2:
		return ""
	var first := str((routes[0] as Dictionary).get("from", ""))
	var last := str((routes[routes.size() - 1] as Dictionary).get("to", ""))
	if first == "" or last != first:
		return ""
	for p in sea.ports():
		if str(p.get("id", "")) == last:
			return last
	return ""


func goal_port_name() -> String:
	"""终点港的名字（结算页与消息条上要写它）。"""
	var home := home_port_id()
	if home == "":
		return "圣阿莱克索"          # v0.5 那趟（大西洋）的终点
	for p in sea.ports():
		if str(p.get("id", "")) == home:
			return str(p.get("name", home))
	return home


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
		if culture.will_fight("green_cape"):
			# 已经翻脸了（这一次登录不再伏击），那就各站各的
			journal.decide("靠近部落的村子：他们拿着矛远远地瞪着你。")
		else:
			# 第一次接触：他们比划着要交换 —— "不打扰" +0.05（docs/19 第 4 节的表）
			culture.react("green_cape", "leave_alone", "初次接触没有动手")
			journal.decide("和部落接触：他们没有动手，你们也没有。")
			report("和部落接触了：他们用手势比划着要交换，没有动手。")
	if id == "stream":
		journal.decide("在岛上的淡水溪流补了水：够装二十桶。")
		report("找到淡水溪流，桶匠说够装二十桶。")


func shoot_warning() -> String:
	"""岸上的玩家动作：**向天开枪示警**（docs/19 第 4 节里"开火 −0.60"那个行为）。

	为什么需要它：不翻脸就没有仗可打，而翻脸的所有入口（开火 / 抓人 / 越界）之前
	**一个都没接进游戏** —— 当地人永远停在"中立"，陆战那一整层就成了摆设。
	两枪就是"敌对"（−0.60 ×2 ≤ −0.35），之后踏进村子他们就会先动手。
	"""
	if not ashore:
		return "船长不在岸上（先按 L 带人登陆）"
	culture.react("green_cape", "fire", "船员向天开枪示警")
	var line := "枪声在林子回荡。%s的态度：%s。" % [
		str(culture.ensure("green_cape").get("name", "当地人")),
		culture.stance_name("green_cape")]
	if culture.will_fight("green_cape"):
		line += " 再往前走，他们就要动手了。"
	journal.decide("船员朝天上放了一枪。")
	log_event(line)
	return line


func _locals_tick(delta: float) -> void:
	"""岛上那伙人怎么动、什么时候动手。

	他们是**常驻实体**（`LocalGroup`）：平时在村子周围溜达，翻了脸就朝你走过来；
	走到临战距离（`LandBattle.START_GAP_M`）才开打 —— 所以画面上不会"凭空刷出一批人"，
	你甚至能看着他们一路走过来。
	"""
	if locals.units.is_empty():
		return
	var hostile := culture.will_fight("green_cape")
	locals.advance(delta, captain_pos, hostile)
	if not hostile or battle != null or fired.has("village_ambush"):
		return
	if locals.alive() > 0 and locals.nearest_distance(captain_pos) <= LandBattle.START_GAP_M:
		_village_ambush()


func _village_ambush() -> void:
	"""他们围上来了：用**双方现在真正站的位置**开打（一次登陆只打一场）。"""
	fired["village_ambush"] = true
	_say("几个人抄起矛围上来 —— %s（%d 人）。他们记得你。" % [
		culture.describe("green_cape"), locals.alive()], true)
	journal.decide("上岸被部落围住：他们先动手。")
	var r := begin_land_battle(locals.alive(), weather.misfire_weather())
	if bool(r.get("ok", false)):
		report("在村子外被当地人围住，打起来了。")


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
	# M13：岛上能弄到新鲜东西（椰子、鱼、溪水）—— 太平洋的岛链就是靠这个救命的。
	# 所以**每上一次岸**就把坏血病的计时清零（有港的地方能整船补给，见 `dock()`）。
	if days_since_fresh > 1.0:
		_say("岸上的椰子和溪水让船上的人缓了一口气。", true)
		journal.decide("上岛补水补食：坏血病重新从零算起。")
	days_since_fresh = 0.0
	fired["landed"] = true
	fired.erase("village_ambush")      # 新的一次登陆：伏击重新武装（上来就打，见 _village_ambush）
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
		# M11：势力态度与王室命令、葡萄牙追捕（房主权威，docs/22 第 4.2 节）
		"factions": factions.capture_state(),
		"pursuit": pursuit.capture_state(),
		"npcs": npcs.capture_state(),
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
	factions.apply_state(d.get("factions", {}))
	pursuit.apply_state(d.get("pursuit", {}))
	npcs.apply_state(d.get("npcs", {}))
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
		# M6 收尾：岛上那伙人是常驻实体（站位、谁倒下了），读档回来不能又满血站回村里
		"locals": locals.capture_state(),
		# M8 收尾：按 `N` 沿航线走的状态。它是"这条船现在怎么开"，算本船状态；
		# 不存的话，存档时正在跟航线、读档回来就跟丢了（航点没了，船开到下一段就停）。
		"following_route": following_route,
		"route_waypoints": StateIO.v2_list(route_waypoints),
		# M13：坏血病与断粮的计时（都是"这条船上的日子"）
		"days_since_fresh": days_since_fresh,
		"days_short": days_short,
		# M13：派去救火抢险的人数（火/水本身的强度在 `ship.hazard` 里，跟着船走）
		"hazard_crew": hazard_crew,
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
	locals.apply_state(d.get("locals", {}))
	following_route = bool(d.get("following_route", false))
	route_waypoints = StateIO.to_v2_list(d.get("route_waypoints", []))
	days_since_fresh = float(d.get("days_since_fresh", 0.0))
	days_short = float(d.get("days_short", 0.0))
	hazard_crew = int(d.get("hazard_crew", 0))
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
