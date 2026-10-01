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
	fleet.setup()
	fleet.claim_local(ship_id)
	var w: Dictionary = sea.wind()
	wind = WindField.new(float(w.get("base_tws_ms", 8.0)), float(w.get("base_from_deg", 20.0)))
	ship = ShipDynamics.new(ShipPhysics.load_default())
	var port_d: Dictionary = sea.port()
	var pos: Array = port_d.get("pos", [700, 4000])
	ship.set_pose(Vector2(float(pos[0]), float(pos[1])), 0.0)
	orders = ShipOrders.new()
	nav = Navigator.new(orders)
	crew = Crew.new(ship)
	roster = CrewRoster.new()
	roster.setup()
	crew.roster = roster
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
	# 洋流与背风区：同一个风，在岛后面就是软的；同一片水，在洋流带上自己会动
	ship.current_world = sea.current_at(pos)
	var wind_vec := wind.velocity_world() * sea.lee_factor(pos)
	# 指挥链路（船长在不在船上都一样：不在就是大副在管）
	nav.decide(ship)
	crew.set_target_heading(nav.target_heading_deg)
	crew.hands_on_sails = orders.hands_on_sails
	ship.set_sail_area_scale(orders.sail_area_scale())
	ship.set_anchored(orders.anchored)
	roster.tick(delta, orders.hands_on_sails)
	crew.step(delta)
	ship.step(delta, wind_vec)
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
	_publish_local_summary()


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
			a.target = target
			a.has_target = true
		s["ship"] = a
		s["kind"] = Fleet.KIND_AI


func default_destination() -> Vector2:
	"""这一程要往哪儿去：优先第二个港（v0.5 的加那利），没有就奔那座岛。

	AI 船用它当目标；玩家掉线时房主也用它把那艘船接过去继续开。
	"""
	var ports := sea.ports()
	if ports.size() > 1:
		return Geom2D.centroid(ports[1]["shape"])
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
	var on_board := 0
	for m in roster.members:
		if not m.ashore:
			on_board += 1
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
		"reef_hit": reef_hit,
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
	reef_hit = bool(d.get("reef_hit", false))
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
