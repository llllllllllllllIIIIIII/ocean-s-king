extends SceneTree

# M3 的验收测试：**两个无头进程**（房主 + 客户端，真 ENet，真回环地址）跑 10 分钟游戏时间，
# 然后逐项对账。这不是模拟"网络正常"，是真的开了两个进程、两条船、
# 2 条 AI，然后用摘要互相对。
#
# 验收清单（docs/13 M3 卡片）：
#   1. 4 条船（2 人 + 2 AI）跑 10 分钟游戏时间，两边的船位 / 船体 / 剧情旗标 / 时钟一致
#      —— "一致"的口径是**允许插值误差 ≤ 一个船身**（船约 20 米），不是位相等；
#   2. 中途加入：第三个人进来接手一条 AI 船，立刻就能开走，其他人看得见；
#   3. 掉线：客户端退出 → 房主把那条船转成 AI 继续走（**不消失**）；
#   4. 单机走同一条代码路径（那一条在 tests/test_fleet.gd 里）。
#
# 时间怎么压缩：游戏时间按 ×36 推进（M2 加的档位），所以 10 分钟游戏时间 ≈ 17 秒真实时间。
# 网络**不**快进：20Hz 是真实世界的 20Hz，插值的 100ms 也是真实世界的 100ms。

const SIM_DT := 0.05
const TIME_SCALE := 36.0
const GAME_SECONDS := 600.0
const MID_JOIN_AT := 300.0          # 第三个人在这时候进来
const ENDING_AT := 540.0            # 临写报告之前宣布结局（验它铺得过去）
const SHIP_LENGTH_M := 20.0         # 一个船身：插值误差的容忍上限
const PROBE := "res://tests/net_client_probe.gd"

var session: NetSession
var link: NetLink
var voyage: Voyage
var _acc := 0.0
var _real := 0.0
var _pids: Array[int] = []
var _report_path := "user://net_client_report.json"
var _report2_path := "user://net_client_report_b.json"
var _m11_pushed := false           # M11：房主只推一次势力/追捕，用来验它铺到了客户端
var _naval_started := false        # M10：双进程海战对账（房主朝客户端那条船开一轮）
var _naval_foe := ""               # 打的是哪条船（用来对上客户端的报告）
var _started_at := 0
var _snapshot := {}
var _phase := "run"
var _wait_client := 0.0
var _wait_client2 := 0.0
var _checks := 0
var _fails: PackedStringArray = []
var _notes: PackedStringArray = []
var _client_ships: Array = []
var _headless_path := ""
var _kinds_seen: Dictionary = {}      # 客户端还没走之前，房主这边的船位分布
var _peak_kinds: Dictionary = {}      # 同时在线的玩家最多那一刻的分布
var _peak_remote := 0


func _initialize() -> void:
	_started_at = Time.get_ticks_msec()
	print("=== test_net_loopback ===")


func _boot() -> void:
	"""网络只能在**第一帧之后**建：SceneTree 的 root 在 _initialize() 时还没进树，
	那时 `multiplayer` 是 null（踩过一次）。"""
	_headless_path = ProjectSettings.globalize_path("res://")
	_remove(_report_path)
	_remove(_report2_path)
	session = NetSession.new()
	session.name = "NetSession"
	root.add_child(session)
	link = NetLink.new()
	link.name = "NetLink"
	root.add_child(link)
	voyage = Voyage.new()
	voyage.setup(Sea.ATLANTIC_PATH)
	# 房主那条船先动起来：给玩家船一个目标，让它真的在跑
	voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	voyage.orders.set_target_point(voyage.default_destination())
	var r := session.host_game(NetSession.PORT, "房主")
	_check(bool(r.get("ok", false)), "开房间成功（%s）" % str(r))
	link.attach(voyage, session)
	_spawn_client(_report_path, 0.0, "水手甲", true)
	_booted = true


var _booted := false


func _spawn_client(report: String, late: float, pname: String, naval := false) -> void:
	# 参数位置固定：ip / port / 名字 / 报告 / 延迟秒 / naval 标记
	# （位置固定是有意的：探针按位置读，别让"有没有延迟"把后面的参数挤位）
	var args := ["--headless", "--path", _headless_path, "--script", PROBE, "--",
		"127.0.0.1", str(NetSession.PORT), pname, report, str(late),
		("naval" if naval else "")]
	var pid := OS.create_process(OS.get_executable_path(), args)
	_pids.append(pid)
	print("[host] 拉起客户端进程 pid=%d（%s）" % [pid, pname])


func _process(delta: float) -> bool:
	if not _booted:
		_boot()
		return false
	session.poll(delta)
	_real += delta
	_acc += delta * TIME_SCALE
	var steps := 0
	while _acc >= SIM_DT and steps < 240:
		voyage.tick(SIM_DT)
		_acc -= SIM_DT
		steps += 1
	voyage.tick_real(delta)
	if _phase == "run" or _phase == "mid":
		_kinds_seen = {}
		for id in voyage.fleet.ids():
			var k := voyage.fleet.kind_of(id)
			_kinds_seen[k] = int(_kinds_seen.get(k, 0)) + 1
		if int(_kinds_seen.get(Fleet.KIND_REMOTE, 0)) > _peak_remote:
			_peak_remote = int(_kinds_seen.get(Fleet.KIND_REMOTE, 0))
			_peak_kinds = _kinds_seen.duplicate()

	# 中途加入：第三个人
	if _phase == "run" and voyage.t >= MID_JOIN_AT:
		_phase = "mid"
		_spawn_client(_report2_path, 0.0, "水手乙", true)

	# M8 收尾：在客户端写报告**之前**，房主这边把结局立起来。
	# 验的是"**拿到船队级结算页**这句话对每个玩家都成立"：`ending_ready` 在 WorldState 的
	# `story` 块里，房主广播、客户端覆盖 —— 这一条就是盯它真的铺过去了。
	if _phase == "mid" and voyage.t >= ENDING_AT and not voyage.story.ending_ready:
		voyage.story.ending_ready = true
		print("[host] t=%.1f 房主这边宣布结局（等价于全队抵达）" % voyage.t)
	# M11：**势力态度与追捕环由房主推进** —— 房主这边改一次，
	# 客户端手里的世界状态必须跟着变（它们都在 WorldState 里，docs/22 第 4.2 节）。
	if _phase == "mid" and voyage.t >= MID_JOIN_AT + 60.0 and not _m11_pushed:
		_m11_pushed = true
		voyage.factions.react_all("trade", 1)
		voyage.pursuit.tick(2.5, true)
		print("[host] t=%.1f 房主推进势力与追捕（态度/环 = %.2f / %d）"
			% [voyage.t, voyage.factions.value("castile"), voyage.pursuit.ring])
	# M10：**双进程海战对账** —— 房主朝客户端那条船开一轮；
	# 命中与伤亡由**挨打那一方的机器**判（受击方权威），再把结果广播回来。
	if _phase == "mid" and voyage.t >= MID_JOIN_AT + 120.0 and not _naval_started \
			and _first_remote_id() != "":
		_naval_started = true
		_naval_foe = _first_remote_id()
		voyage.encounters_enabled = false      # 这一节验的是权威归属，不是随机遭遇
		# 距离放进霰弹的杀伤区间（80–200 米）、弹种选霰弹 ——
		# 这样这一轮**真的会倒人**，对账才是"比一个非零的数"，
		# 而不是"两个 0 相等"（那样的断言什么都证明不了）。
		var r := voyage.naval_start_vs(_naval_foe, 40, 150.0)
		if bool(r.get("ok", false)) and voyage.naval != null:
			voyage.naval.intent = "fire"
			voyage.naval.ammo_want = "scatter"
			print("[host] 对 %s 开了一轮舷侧（受击方权威会算并广播回来）" % _naval_foe)
		else:
			print("[host] 海战没起得来：%s" % str(r))
	# 到了 10 分钟：给两边各拍一张快照，然后等客户端的报告
	if _phase == "mid" and voyage.t >= GAME_SECONDS:
		_phase = "wait"
		_snapshot = _snapshot_of(voyage)
		print("[host] t=%.1f 对账快照：%s" % [voyage.t, _brief(_snapshot)])
	if _phase == "wait":
		_wait_client += delta
		if _wait_client > 60.0:
			_check(false, "客户端在 60 秒内没有交出报告")
			return _finish()
		if FileAccess.file_exists(_report_path) and FileAccess.file_exists(_report2_path):
			_compare()
			if _fails.is_empty():
				_phase = "drop"
			else:
				return _finish()
	# 掉线：客户端已经退出（它走之前发了 BYE），那条船必须转 AI 继续走
	if _phase == "drop":
		_phase = "drop_check"
		_wait_client = 0.0
		for id in voyage.fleet.others():
			_notes.append("%s=%s" % [id, voyage.fleet.kind_of(id)])
	if _phase == "drop_check":
		_wait_client += delta
		if _wait_client > 3.0:
			_drop_checks()
			return _finish()
	return false


# ------------------------------------------------------------ 对账

func _first_remote_id() -> String:
	"""房主眼里"某个人在开"的那条船（用来选一个海战对手）。"""
	for id in voyage.fleet.ids():
		if voyage.fleet.kind_of(id) == Fleet.KIND_REMOTE:
			return str(id)
	return ""


func _snapshot_of(v: Voyage) -> Dictionary:
	var fleet := {}
	var kinds := {}
	for id in v.fleet.ids():
		fleet[id] = v.fleet.summary_of(id)
		var k := v.fleet.kind_of(id)
		kinds[k] = int(kinds.get(k, 0)) + 1
	return {
		"t": v.t,
		"fleet": fleet,
		"kinds": kinds,
		"fired": v.fired.keys(),
		"story_head": v.story.head,
		"ending_ready": v.story.ending_ready,
		"local_id": v.fleet.local_id,
		# M11：势力态度与追捕环（房主权威）—— 客户端手里的值必须与房主一致
		"factions": v.factions.attitude.duplicate(),
		"pursuit_ring": v.pursuit.ring,
		# M10：海战的双进程对账（开火方这一侧看到的"对面伤亡"）
		"naval_started": _naval_started,
		"naval_foe_id": _naval_foe,
		"naval_foe_losses": int(v.naval.last_outgoing.get("personnel_losses", -1)) \
			if v.naval != null else -1,
		"naval_foe_crew": int(v.naval.foe_crew) if v.naval != null else -1,
		"mine": {"pos": [v.ship.position_m().x, v.ship.position_m().y],
			"hull_pct": 1.0 - v.ship.damage_of("hull")},
	}


func _compare() -> void:
	var c1 := _read(_report_path)
	var c2 := _read(_report2_path)
	_check(not c1.is_empty() and str(c1.get("status", "")) == "ok",
		"客户端甲交出了报告（t=%.1f，开的是 %s）" % [
			float(c1.get("t", -1.0)), str(c1.get("ship_id", ""))])
	_check(not c2.is_empty() and str(c2.get("status", "")) == "ok",
		"客户端乙交出了报告（t=%.1f，开的是 %s）" % [
			float(c2.get("t", -1.0)), str(c2.get("ship_id", ""))])
	if c1.is_empty() or c2.is_empty():
		return
	_client_ships = [str(c1.get("ship_id", "")), str(c2.get("ship_id", ""))]

	# ① 时钟
	_check(absf(float(c1["t"]) - float(_snapshot["t"])) < 3.0,
		"房主与客户端甲的时钟一致（%.1f vs %.1f）" % [
			float(_snapshot["t"]), float(c1["t"])])
	_check(absf(float(c2["t"]) - float(_snapshot["t"])) < 3.0,
		"房主与客户端乙的时钟一致（%.1f vs %.1f）" % [
			float(_snapshot["t"]), float(c2["t"])])

	# ①.5 结局旗标：房主宣布之后，**每个玩家**手里都得有（结算页才有得弹）
	_check(bool(_snapshot.get("ending_ready", false)),
		"房主这边已经宣布结局（%.0f 游戏秒时）" % float(_snapshot["t"]))
	for c in [c1, c2]:
		_check(bool(c.get("ending_ready", false)),
			"%s 手里也拿到了结局旗标（结算页弹得出来）" % str(c.get("role", "客户端")))

	# ② 四条船：两边各自看到的位姿差 ≤ 一个船身
	var worst_remote := 0.0
	var worst_name := ""
	for id in (_snapshot["fleet"] as Dictionary).keys():
		var mine: Dictionary = _snapshot["fleet"][id]
		for c in [c1, c2]:
			var theirs: Dictionary = (c.get("fleet", {}) as Dictionary).get(id, {})
			if theirs.is_empty():
				continue
			var d := _dist(mine.get("pos", [0, 0]), theirs.get("pos", [0, 0]))
			if d > worst_remote:
				worst_remote = d
				worst_name = "%s（对 %s）" % [id, str(c.get("role", "?"))]
	_check(worst_remote <= SHIP_LENGTH_M,
		"四条船的位姿两边一致：最大差 %.1f 米（≤ 一个船身 %.0f 米，最差是 %s）" % [
			worst_remote, SHIP_LENGTH_M, worst_name])

	# ③ 客户端自己那条船：房主看到的 vs 它自己算的
	var c1_local: Dictionary = c1.get("local", {})
	var host_view: Dictionary = (_snapshot["fleet"] as Dictionary).get(str(c1["ship_id"]), {})
	var d_own := _dist(host_view.get("pos", [0, 0]), c1_local.get("pos", [0, 0]))
	_check(d_own <= SHIP_LENGTH_M,
		"房主看到的客户端甲那条船，和它自己算的差 %.1f 米（≤ 一个船身）" % d_own)
	# 反向：客户端看到的房主那条船 vs 房主自己算的
	var c_view: Dictionary = (c1.get("fleet", {}) as Dictionary).get(str(_snapshot["local_id"]), {})
	var d_mine := _dist((_snapshot["mine"] as Dictionary).get("pos", [0, 0]), c_view.get("pos", [0, 0]))
	_check(d_mine <= SHIP_LENGTH_M,
		"客户端看到的房主那条船，和房主自己算的差 %.1f 米（≤ 一个船身）" % d_mine)

	# ④ 船体与剧情旗标
	var hull_worst := 0.0
	for id in (_snapshot["fleet"] as Dictionary).keys():
		var mine: Dictionary = _snapshot["fleet"][id]
		var theirs: Dictionary = (c1.get("fleet", {}) as Dictionary).get(id, {})
		if theirs.is_empty():
			continue
		hull_worst = maxf(hull_worst, absf(float(mine.get("hull_pct", 1.0)) - float(theirs.get("hull_pct", 1.0))))
	_check(hull_worst < 0.02, "四条船的船体%%两边一致（最大差 %.3f）" % hull_worst)
	_check(Array(c1.get("fired", [])) == Array(_snapshot["fired"]),
		"剧情旗标一致（客户端 %d 个 / 房主 %d 个）" % [
			Array(c1.get("fired", [])).size(), Array(_snapshot["fired"]).size()])
	_check(int(c1.get("story_head", -1)) == int(_snapshot["story_head"]),
		"演到同一幕（第 %d 幕）" % (int(_snapshot["story_head"]) + 1))
	# M11：势力态度与追捕环由房主推进 —— 两个客户端手里的值必须与房主一致
	_check(str(c1.get("factions", {})) == str(_snapshot["factions"]),
		"客户端拿到同一份势力态度（%d 家）" % (c1.get("factions", {}) as Dictionary).size())
	_check(int(c1.get("pursuit_ring", -1)) == int(_snapshot["pursuit_ring"]),
		"客户端拿到同一个追捕环（第 %d 环）" % int(_snapshot["pursuit_ring"]))
	_check(str(c2.get("factions", {})) == str(_snapshot["factions"]),
		"第二个客户端也是同一份势力态度")
	# M10：**海战的双进程对账** —— 受击方权威（客户端）算出来的伤亡，
	# 与开火方（房主）账上"对面挨了什么"必须一致。
	var foe_losses := int(_snapshot.get("naval_foe_losses", -1))
	var foe_crew := int(_snapshot.get("naval_foe_crew", -1))
	if bool(_snapshot.get("naval_started", false)):
		# 挨打的那个客户端可能是甲也可能是乙：按船 id 找它
		var defender := c1
		if str(c1.get("ship_id", "")) != str(_snapshot.get("naval_foe_id", "")):
			defender = c2
		_check(int(defender.get("naval_incoming_losses", -2)) == foe_losses,
			"海战伤亡两边一致（受击方权威算出 %d，开火方账上 %d）"
			% [int(defender.get("naval_incoming_losses", -2)), foe_losses])
		_check(int(defender.get("naval_own_crew", -1)) == foe_crew,
			"对面剩下的人数也对得上（客户机 %d / 房主 %d）"
			% [int(defender.get("naval_own_crew", -1)), foe_crew])
		_check(int(defender.get("naval_foe_rounds", 0)) >= 1,
			"客户端确实以受击方权威的身份处理了这一轮（%d）"
			% int(defender.get("naval_foe_rounds", 0)))
		# 这一轮打的是霰弹、距离在杀伤区间里：伤亡必须是**真的数**，
		# 不然"两边一致"只是因为两边都是 0（那条断言什么都证明不了）
		_check(foe_losses > 0, "这一轮真的打倒了人（%d 个）—— 对账比的是非零的数" % foe_losses)
	else:
		_check(false, "海战没起得来（没有可对账的东西）")

	# ⑤ 对账那一刻的四条船：2 个人在开（房主 + 客户端），2 条是 AI
	#    （用"客户端还没走之前"的分布：它们到点就退出，晚一帧看就只剩 AI 了）
	var kinds: Dictionary = _peak_kinds
	_check(int(kinds.get(Fleet.KIND_LOCAL, 0)) == 1
			and int(kinds.get(Fleet.KIND_REMOTE, 0)) == 2
			and int(kinds.get(Fleet.KIND_AI, 0)) == 1,
		"对账那一刻：1 条本机 + 2 条玩家船 + 1 条 AI（%s）" % str(kinds))
	_check(_client_ships.size() == 2 and _client_ships[0] != _client_ships[1],
		"两个客户端各开了一条不同的船（%s）" % ", ".join(_client_ships))
	_notes.append("船位分布 %s" % str(kinds))
	print("[host] 对账完成：%s" % _brief(_snapshot))


func _drop_checks() -> void:
	"""拆线：kill 掉一个客户端，房主应该把它那条船转 AI（船不消失）。"""
	"""客户端走了之后：那条船必须还在走（转 AI），不是从世界里消失。"""
	_check(_client_ships.size() == 2, "两个客户端各自接手过一条船（%s）" % ", ".join(_client_ships))
	for id in _client_ships:
		if id == "":
			continue
		_check(voyage.fleet.kind_of(id) == Fleet.KIND_AI,
			"%s 掉线之后回到 AI 手上（不是从世界里消失）" % id)
		var moved := voyage.fleet.pose_of(id).distance_to(_snapshot_pos(id))
		_check(moved > 5.0, "%s 掉线之后自己接着走（走了 %.0f 米）" % [id, moved])
	var ai_ids := voyage.fleet.ids_of_kind(Fleet.KIND_AI)
	var still := PackedStringArray()
	for id in ai_ids:
		if voyage.fleet.pose_of(id).distance_to(_snapshot_pos(id)) <= 5.0:
			still.append(id)
	_check(ai_ids.size() >= 3 and still.is_empty(),
		"四条船里的 AI 都在继续走（%d 条，原地不动的：%s）" % [
			ai_ids.size(), "无" if still.is_empty() else ", ".join(still)])
	# 掉线之后，房主的存档照样能存能读（docs/13 M3 卡片第 3 条的后半句）
	var r := SaveGame.save_game(voyage, "net_test")
	_check(bool(r.get("ok", false)), "掉线之后房主还能存档（%d 字节）" % int(r.get("bytes", 0)))
	var back := Voyage.new()
	back.setup(Sea.ATLANTIC_PATH)
	var r2 := SaveGame.load_into(back, "net_test")
	_check(bool(r2.get("ok", false)), "掉线之后房主还能读档")
	_check(back.fleet.ids_of_kind(Fleet.KIND_AI).size() == 3,
		"读回来的世界里三条船还是 AI 在开（%d 条）" % back.fleet.ids_of_kind(Fleet.KIND_AI).size())
	var p := ProjectSettings.globalize_path(SaveGame.slot_path("net_test"))
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _snapshot_pos(id: String) -> Vector2:
	var s: Dictionary = (_snapshot["fleet"] as Dictionary).get(id, {})
	var p: Array = s.get("pos", [0.0, 0.0])
	return Vector2(float(p[0]), float(p[1]))


# ------------------------------------------------------------ 小工具

func _dist(a, b) -> float:
	return Vector2(float(a[0]), float(a[1])).distance_to(Vector2(float(b[0]), float(b[1])))


func _read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if typeof(d) == TYPE_DICTIONARY else {}


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _brief(s: Dictionary) -> String:
	return "t=%.1f　船队 %d 条" % [float(s.get("t", -1.0)), (s.get("fleet", {}) as Dictionary).size()]


func _check(ok: bool, msg: String) -> void:
	if msg == "":
		return
	_checks += 1
	if ok:
		print("  [PASS] " + msg)
	else:
		_fails.append(msg)
		print("  [FAIL] " + msg)


func _finish() -> bool:
	var ms := Time.get_ticks_msec() - _started_at
	for note in _notes:
		print("  · " + note)
	if _fails.is_empty():
		print("全部通过：%d 项断言，耗时 %.1f 秒（真实时间）" % [_checks, ms / 1000.0])
		quit(0)
	else:
		print("失败 %d / %d 项：" % [_fails.size(), _checks])
		for f in _fails:
			print("  - " + f)
		quit(1)
	return true
