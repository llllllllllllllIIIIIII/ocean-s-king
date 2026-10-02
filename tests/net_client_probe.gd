extends SceneTree

# M3 的**客户端探针**：无头跑一条船，最后把状态写成 JSON 给房主对账。
#
# 用法（由 tests/test_net_loopback.gd 用 OS.create_process 拉起来）：
#   godot --headless --path . --script res://tests/net_client_probe.gd \
#         -- <ip> <port> <名字> <报告文件> [延迟加入的真实秒数]
#
# 它就是"另一个人在自己机器上开游戏"的最小版本：连上房主 → 接手一条船 →
# 用和单机完全一样的那条链路（Voyage.tick + tick_real）往下跑。

const SIM_DT := 0.05
const TIME_SCALE := 36.0            # 快进：10 分钟游戏时间 ≈ 17 秒真实时间
const GAME_SECONDS := 600.0
const MAX_REAL := 120.0

var session: NetSession
var link: NetLink
var voyage: Voyage
var _acc := 0.0
var _real := 0.0
var _started := false
var _out := "user://net_client_report.json"
var _late_real := 0.0
var _idle := 0.0
var _recv: Dictionary = {}          # 收到过哪些消息（诊断用，进报告）
var _naval_mode := false            # M10 的双进程对账：这个客户端"当受击方权威"
var _naval_started := false


func _initialize() -> void:
	pass


var _booted := false


func _boot() -> void:
	"""网络只能在**第一帧之后**建：SceneTree 的 root 在 _initialize() 时还没进树。"""
	var a := OS.get_cmdline_user_args()
	var ip := str(a[0]) if a.size() > 0 else "127.0.0.1"
	var port := int(a[1]) if a.size() > 1 else NetSession.PORT
	var pname := str(a[2]) if a.size() > 2 else "客户端"
	if a.size() > 3:
		_out = str(a[3])
	if a.size() > 4:
		_late_real = float(a[4])
	if a.size() > 5:
		_naval_mode = str(a[5]) == "naval"
	session = NetSession.new()
	session.name = "NetSession"
	root.add_child(session)
	link = NetLink.new()
	link.name = "NetLink"
	root.add_child(link)
	link.attach(null, session)
	link.welcome.connect(_on_welcome)
	link.rejected.connect(_on_rejected)
	session.message.connect(_count_recv)
	if _late_real <= 0.0:
		var r := session.join_game(ip, port, pname)
		print("[client] 加入 %s:%d -> %s" % [ip, port, str(r)])
	_booted = true


func _count_recv(peer: int, kind: String, _payload: Dictionary) -> void:
	_recv[kind] = int(_recv.get(kind, 0)) + 1


func _on_rejected(reason: String) -> void:
	print("[client] 被拒绝：", reason)
	_write_report("rejected")
	quit(1)


func _on_welcome(ship_id: String, summary: Dictionary, world: Dictionary) -> void:
	if _started:
		return
	_started = true
	var region := str(world.get("region", Sea.ATLANTIC_PATH))
	voyage = Voyage.new()
	voyage.setup(region, ship_id, summary)
	NetProtocol.apply_world_projection(voyage, world)
	voyage.attach_link(link)
	print("[client] 接手 %s（船体 %.0f%%，t=%.1f）" % [
		ship_id, float(summary.get("hull_pct", 1.0)) * 100.0, voyage.t])


func _process(delta: float) -> bool:
	if not _booted:
		_boot()
		return false
	session.poll(delta)
	_real += delta
	# 延迟加入：先干等一会儿，再连上（模拟"第三个人中途进来"）
	if not _started and _late_real > 0.0:
		_idle += delta
		if _idle >= _late_real:
			_late_real = 0.0
			var a := OS.get_cmdline_user_args()
			var ip := str(a[0]) if a.size() > 0 else "127.0.0.1"
			var port := int(a[1]) if a.size() > 1 else NetSession.PORT
			var pname := str(a[2]) if a.size() > 2 else "客户端"
			print("[client] 中途加入 %s:%d -> %s" % [ip, port, str(session.join_game(ip, port, pname))])
	if _started and voyage != null:
		_acc += delta * TIME_SCALE
		# M10：起一场海战，**只挨打不还手** —— 这一条验的是"谁判命中、谁广播结果"
		if _naval_mode and not _naval_started and _real > 1.5:
			var r := voyage.begin_naval_battle(40, "", 300.0)
			if bool(r.get("ok", false)):
				voyage.naval.intent = "hold"
				_naval_started = true
				print("[client] 海战：等着挨打（本机是受击方权威）")
		var steps := 0
		while _acc >= SIM_DT and steps < 240:
			voyage.tick(SIM_DT)
			_acc -= SIM_DT
			steps += 1
		voyage.tick_real(delta)
		if voyage.t >= GAME_SECONDS or _real > MAX_REAL:
			# 走之前打个招呼：房主据此把这条船转 AI（"掉线不消失"）
			session.send_to_host(NetProtocol.BYE, {"ship_id": voyage.fleet.local_id}, true)
			_write_report("ok")
			# 再等几帧把 BYE 真的发出去，然后退出
			_idle = -1.0
	if _idle < 0.0:
		_idle -= delta
		if _idle < -0.5:
			quit(0)
	return false


func _write_report(status: String) -> void:
	var fleet := {}
	if voyage != null:
		for id in voyage.fleet.ids():
			fleet[id] = voyage.fleet.summary_of(id)
	var local := {}
	var fleet_owner := {}
	if voyage != null:
		local = {
			"id": voyage.fleet.local_id,
			"pos": [voyage.ship.position_m().x, voyage.ship.position_m().y],
			"heading": voyage.ship.heading_deg(),
			"hull_pct": 1.0 - voyage.ship.damage_of("hull"),
			"crew_count": voyage.roster.members.size(),
		}
		for id in voyage.fleet.ids():
			fleet_owner[id] = {
				"kind": voyage.fleet.kind_of(id),
				"peer": voyage.fleet.owner_peer_of(id),
				"name": voyage.fleet.owner_name_of(id),
			}
	var d := {
		"status": status,
		"role": "client",
		"t": voyage.t if voyage != null else -1.0,
		"ship_id": voyage.fleet.local_id if voyage != null else "",
		"local": local,
		"fleet_owner": fleet_owner,
		"fleet": fleet,
		"fired": voyage.fired.keys() if voyage != null else [],
		"story_head": voyage.story.head if voyage != null else -1,
		# M8 收尾：结局旗标也要对账 —— "拿到船队级结算页"这句话对**每个玩家**都该成立
		"ending_ready": voyage.story.ending_ready if voyage != null else false,
		"decisions": voyage.journal.decisions.duplicate() if voyage != null else [],
		# M11：势力态度与追捕环（房主权威）—— 客户端手里拿到的应该是房主推过来的那一份
		"factions": voyage.factions.attitude.duplicate() if voyage != null else {},
		"pursuit_ring": voyage.pursuit.ring if voyage != null else -1,
		# M10：海战的双进程对账 —— 我这个（受击方权威）算出来的伤亡
		"naval_started": _naval_started,
		"naval_own_crew": voyage.naval.own_crew if (voyage != null and voyage.naval != null) else -1,
		"naval_incoming_losses": int(voyage.naval.last_incoming.get("personnel_losses", -1)) \
			if (voyage != null and voyage.naval != null) else -1,
		"naval_foe_rounds": int(voyage.naval.foe_rounds) \
			if (voyage != null and voyage.naval != null) else -1,
		"recv": _recv,
	}
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", false))
	f.close()
	print("[client] 报告写到 ", _out, "（t=%.1f）" % (voyage.t if voyage != null else -1.0))
