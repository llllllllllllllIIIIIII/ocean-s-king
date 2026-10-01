class_name Voyage
extends RefCounted

# 一次航行（Day 6）：海域 + 风 + 洋流 + 船 + 船员 + 剧情事件 + 登陆。
#
# 它把前五天做的东西串成一条体验链：
#   出港（Day 1-2 的船）→ 靠风航行（Day 3）→ 指挥链路（Day 4）
#   → 船员在船上过日子（Day 5）→ 发现岛、挑人上岸、船上交给大副（Day 6）
#
# 唯一一条"单向"规矩不变：**只有 ShipDynamics 能写船的位置与速度**。
# Voyage 只是每帧把风、洋流、指令喂给它，再读它的状态去推进剧情。

const KNOT := 0.514444

var sea := Sea.new()
var wind := WindField.new()
var ship: ShipDynamics
var orders: ShipOrders
var nav: Navigator
var crew: Crew
var roster: CrewRoster

var t := 0.0
var log_lines: Array = []          # 航海日志（文书记的）
var fired := {}                    # 已触发的事件 id
var pending_reports: Array = []    # 船长不在船时攒下的报告，回船一次性给他
var island_known := false
var visited := {}                  # 到过的地标
var reef_hit := false

# --- 登陆 ---
var ashore := false
var captain_pos := Vector2.ZERO
var captain_target := Vector2.ZERO
var party_speed := 14.0            # 岸上走路（米/秒）：别让玩家在等
var ashore_count := 0              # 跟船长一起上岸的水手数（关键船员另算）
var landing_point := Vector2.ZERO  # 上岸点：船旁边最近的那段岸（不是固定航标）
var last_message := ""             # 最新一条重要消息（HUD 上显示十几秒）
var message_timer := 0.0
var _shore_cooldown := 0.0         # 蹭滩提示的冷却


func setup() -> void:
	sea.setup()
	var w: Dictionary = sea.data.get("wind", {})
	wind = WindField.new(float(w.get("base_tws_ms", 8.0)), float(w.get("base_from_deg", 20.0)))
	ship = ShipDynamics.new(ShipPhysics.load_default())
	var p: Dictionary = sea.port()
	var pos: Array = p.get("pos", [700, 4000])
	ship.set_pose(Vector2(float(pos[0]), float(pos[1])), 0.0)
	orders = ShipOrders.new()
	nav = Navigator.new(orders)
	crew = Crew.new(ship)
	roster = CrewRoster.new()
	roster.setup()
	crew.roster = roster
	# 陆地：船开不上干地（沙滩那一圈是浅水，可以靠上去登陆）
	var isl := sea.island()
	var c: Array = isl.get("center", [0, 0])
	ship.land_center = Vector2(float(c[0]), float(c[1]))
	ship.land_radius = float(isl.get("radius_m", 0.0)) - float(isl.get("beach_width_m", 0.0))
	ship.step(0.0, wind.velocity_world())
	crew.retrim()
	log_event(sea.data.get("voyage", {}).get("act1_text", ""))
	log_event("出发：%s。" % str(p.get("name", "出发港")))


func tick(delta: float) -> void:
	t += delta
	message_timer = maxf(0.0, message_timer - delta)
	wind.step(delta)
	var pos := ship.position_m()
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
	# 蹭上滩头：给一点损伤与提示（不该天天撞，所以有冷却）
	_shore_cooldown = maxf(0.0, _shore_cooldown - delta)
	if ship.last_blocked and _shore_cooldown <= 0.0:
		_shore_cooldown = 20.0
		ship.apply_damage("hull", 0.06)
		_say("船底蹭上滩头，木匠皱着眉头看了一眼。", true)
	_events(delta)
	if ashore:
		_walk_ashore(delta)


# ------------------------------------------------------------ 剧情事件

func _events(_delta: float) -> void:
	var pos := ship.position_m()
	# ① 瞭望员报告：离岛近了
	if not fired.has("lookout") and pos.distance_to(_island_center()) < 2600.0:
		fired["lookout"] = true
		island_known = true
		_say("瞭望员 佩德罗·卡斯科：右前方有陆地！", true)
		log_event(sea.data.get("voyage", {}).get("act2_text", ""))
	# ② 风向突变（Day 3 的风场只会缓变，这里是"意外"）
	if not fired.has("wind_shift") and t > 300.0:
		fired["wind_shift"] = true
		wind.base_from_dir += 55.0
		_say("风向变了：从东北转成东南，船头被压向下风。", true)
	# ③ 触礁：这是那条**可见的因果链**的中间一环 ——
	#    风转了 → 船被压向暗礁 → 撞上 → 船体受损 → 木匠去修
	if not reef_hit and sea.is_reef(pos) and not orders.anchored:
		reef_hit = true
		ship.apply_damage("hull", 0.28)
		ship.apply_damage("rudder", 0.10)
		_say("船底刮上礁石。木匠喊着要人下去看船缝。", true)
		report("触礁：船体损伤约三成，舵也蹭到了一点。")
		fired["reef_hit"] = true
	# ④ 船员伤病（触礁之后才可能发生 —— 因果链的第二环）
	if fired.has("reef_hit") and not fired.has("injury") and t > 60.0:
		fired["injury"] = true
		var hurt := _jury_target()
		if hurt != null:
			hurt.health = clampf(hurt.health - 0.35, 0.05, 1.0)
			_say("%s 在摇晃的甲板上滑倒，肩膀脱臼。外科医生把他扶了下去。" % hurt.label(), true)
			report("%s 受了伤，已经交给外科医生。" % hurt.label())


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
	_say("【%s】%s" % [str(poi["name"]), str(poi.get("text", ""))], true)
	if id == "ruins" and not fired.has("ruins"):
		fired["ruins"] = true
		report("文书把遗迹墙上的字抄了下来 —— 和《圣经》的字母不一样。")
	if id == "village" and not fired.has("village"):
		fired["village"] = true
		report("和部落接触了：他们用手势比划着要交换，没有动手。")
	if id == "stream":
		report("找到淡水溪流，桶匠说够装二十桶。")


# ------------------------------------------------------------ 登陆

func can_land() -> bool:
	if ashore:
		return false
	var beach := _beach_pos()
	return ship.position_m().distance_to(beach) < 420.0


func _beach_pos() -> Vector2:
	for poi in sea.pois():
		if str(poi["id"]) == "beach":
			var p: Array = poi["pos"]
			return Vector2(float(p[0]), float(p[1]))
	return _island_center()


func _shore_near(pos: Vector2) -> Vector2:
	"""船旁边最近的岸：把人放在**船所在的那段滩**上，而不是固定的登陆航标。

	（第一版把队伍直接放在航标上，于是"人在哪儿上岸"和船的位置没关系，看着很怪。）
	"""
	var c := _island_center()
	var r := float(sea.island().get("radius_m", 0.0)) \
		- float(sea.island().get("beach_width_m", 0.0)) * 0.5
	var d := pos - c
	if d.length() < 1.0:
		return c + Vector2(-r, 0.0)
	return c + d.normalized() * r


func _island_center() -> Vector2:
	var c: Array = sea.island().get("center", [0, 0])
	return Vector2(float(c[0]), float(c[1]))


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
	landing_point = _shore_near(ship.position_m())
	captain_pos = landing_point
	captain_target = captain_pos
	var msg := "带 %s 和 %d 名水手上岸。" % [
		"、".join(names) if names.size() > 0 else "（不带关键船员）", ashore_count]
	_say(msg, true)
	return msg


func return_to_ship() -> String:
	if not ashore:
		return "你还在船上"
	if captain_pos.distance_to(landing_point) > 420.0:
		return "得先走回下船的地方才能上船"
	ashore = false
	for m in roster.key_crew():
		m.ashore = false
	var msg := "回到船上。"
	if pending_reports.size() > 0:
		msg += "你不在的时候，船上发生了：\n" + "\n".join(pending_reports)
		pending_reports.clear()
	_say(msg, true)
	return msg


func move_party_to(pos: Vector2) -> void:
	# 队伍只能在岛上走：点远了就收到岛边
	var c := _island_center()
	var r := float(sea.island().get("radius_m", 0.0)) - 40.0
	var d := pos - c
	if d.length() > r:
		pos = c + d.normalized() * r
	captain_target = pos


func party_size() -> int:
	var n := 1
	for m in roster.members:
		if m.ashore:
			n += 1
	return n


# ------------------------------------------------------------ 日志与报告

func log_event(text: String) -> void:
	if text.strip_edges() == "":
		return
	log_lines.append(text)
	if log_lines.size() > 40:
		log_lines.pop_front()


func _say(text: String, important := false) -> void:
	log_event(text)
	if important:
		last_message = text
		message_timer = 12.0


func report(text: String) -> void:
	"""船上的事：船长在船上就直接告诉他，不在就先攒着（延迟消息）。"""
	if ashore:
		pending_reports.append(text)
	else:
		_say("（报告）" + text, true)


func describe() -> String:
	var dmg := ship.describe_damage()
	return "第 %.0f 分钟　船速 %.1f 节　%s　损伤：%s　%s" % [
		t / 60.0, ship.speed_kn(), nav.method_name(), dmg,
		"船长在岸上" if ashore else "船长在船上"]
