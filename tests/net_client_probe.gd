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
	if voyage != null:
		local = {
			"id": voyage.fleet.local_id,
			"pos": [voyage.ship.position_m().x, voyage.ship.position_m().y],
			"heading": voyage.ship.heading_deg(),
			"hull_pct": 1.0 - voyage.ship.damage_of("hull"),
			"crew_count": voyage.roster.members.size(),
		}
	var d := {
		"status": status,
		"role": "client",
		"t": voyage.t if voyage != null else -1.0,
		"ship_id": voyage.fleet.local_id if voyage != null else "",
		"local": local,
		"fleet": fleet,
		"fired": voyage.fired.keys() if voyage != null else [],
		"story_head": voyage.story.head if voyage != null else -1,
		"decisions": voyage.journal.decisions.duplicate() if voyage != null else [],
		"recv": _recv,
	}
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", false))
	f.close()
	print("[client] 报告写到 ", _out, "（t=%.1f）" % (voyage.t if voyage != null else -1.0))
