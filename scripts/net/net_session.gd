class_name NetSession
extends Node

# 会话层（M3）：**星型**。一台房主，2–4 个客户端都只跟房主说话（docs/13 M3 卡片）。
# 它只管三件事：连上/断开、收发消息、心跳超时。**不含任何玩法逻辑** ——
# 谁写世界、谁写船，是 `NetLink` 与 Fleet 的事。
#
# 用 ENet：可靠 + 有序 + 多通道，正好是"房间"需要的；20Hz 的船位摘要走
# **不可靠**通道（丢一包不过晚 50ms 画一次，不用重传堵住后面的包）。
#
# 协议版本不符**直接拒绝**：和存档一个口径（docs/14 第 4.2 节），
# 不写迁移代码 —— v0.5 内不承诺兼容。

signal message(peer: int, kind: String, payload: Dictionary)
signal peer_joined(peer: int)
signal peer_left(peer: int)
signal connection_lost()          # 客户端：房主不见了
signal connected_to_host()        # 客户端：连上了

enum Role { OFFLINE, HOST, CLIENT }

const PORT := 47777
const MAX_PLAYERS := 4
const CHANNELS := 4               # ⚠️ 必须显式给通道数：ENet 默认 0 通道 ->
                                  #    "Unable to send packet on channel 0, max channels: 0"，
                                  #    表现就是"刚连上时收得到，之后一个包都收不到"
const HEARTBEAT := 0.5
const TIMEOUT := 3.0              # 3 秒没心跳 = 掉线（房主把那条船转 AI）

var role: Role = Role.OFFLINE
var player_name := ""
var my_peer := 0                  # 自己的 peer id（房主恒为 1）
var peers: Dictionary = {}        # peer -> {name, last_seen}
var _heartbeat_t := 0.0
var _timeout_t := 0.0


func host_game(port := PORT, name := "麦哲伦") -> Dictionary:
	leave()
	var p := ENetMultiplayerPeer.new()
	var err := p.create_server(port, MAX_PLAYERS - 1, CHANNELS)
	if err != OK:
		return {"ok": false, "reason": "开不了房间（端口 %d 被占用？错误码 %d）" % [port, err]}
	multiplayer.multiplayer_peer = p
	role = Role.HOST
	player_name = name
	my_peer = 1
	peers = {1: {"name": name, "last_seen": 0.0}}
	return {"ok": true, "port": port, "peer": 1}


func join_game(ip := "127.0.0.1", port := PORT, name := "水手") -> Dictionary:
	leave()
	var p := ENetMultiplayerPeer.new()
	var err := p.create_client(ip, port, CHANNELS)
	if err != OK:
		return {"ok": false, "reason": "连不上 %s:%d（错误码 %d）" % [ip, port, err]}
	multiplayer.multiplayer_peer = p
	role = Role.CLIENT
	player_name = name
	my_peer = 0                    # 连上之后由 ENet 分配
	peers = {}
	return {"ok": true, "ip": ip, "port": port}


func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	role = Role.OFFLINE
	my_peer = 0
	peers = {}


func is_online() -> bool:
	return role != Role.OFFLINE


func is_host() -> bool:
	return role == Role.HOST


func is_client() -> bool:
	return role == Role.CLIENT


func player_count() -> int:
	return peers.size() if role == Role.HOST else 0


# ------------------------------------------------------------ 每帧

func poll(delta: float) -> void:
	if not is_online():
		return
	if is_client() and my_peer == 0 and multiplayer.has_multiplayer_peer():
		my_peer = multiplayer.get_unique_id()
		if my_peer > 1:
			emit_signal("connected_to_host")
	_heartbeat_t += delta
	if is_host() and _heartbeat_t >= HEARTBEAT:
		_heartbeat_t = 0.0
		for peer in peers.keys():
			if int(peer) == 1:
				continue
			send_to(int(peer), NetProtocol.PING, {"t": Time.get_ticks_msec()}, false)
		# 超时：房主把这条船交回 AI（真正的"转 AI"由 NetLink 做）
		_timeout_t += HEARTBEAT
		for peer in peers.keys().duplicate():
			if int(peer) == 1:
				continue
			if _timeout_t - float((peers[peer] as Dictionary).get("last_seen", 0.0)) > TIMEOUT:
				var gone := int(peer)
				peers.erase(peer)
				emit_signal("peer_left", gone)
	elif is_client():
		# 客户端每秒给房主一次心跳（房主靠它判断"你还活着"）
		if _heartbeat_t >= HEARTBEAT:
			_heartbeat_t = 0.0
			send_to_host(NetProtocol.PING, {"t": Time.get_ticks_msec()}, false)


# ------------------------------------------------------------ 收发

func send_to(peer: int, kind: String, payload: Dictionary, reliable := true) -> void:
	if not is_online():
		return
	if reliable:
		_net_reliable.rpc_id(peer, kind, payload)
	else:
		_net_fast.rpc_id(peer, kind, payload)


func send_to_host(kind: String, payload: Dictionary, reliable := true) -> void:
	if not is_client():
		return
	var target := 1                 # ENet 里房主的 peer id 恒为 1
	if reliable:
		_net_reliable.rpc_id(target, kind, payload)
	else:
		_net_fast.rpc_id(target, kind, payload)


func broadcast(kind: String, payload: Dictionary, reliable := true) -> void:
	if not is_online():
		return
	if reliable:
		_net_reliable.rpc(kind, payload)
	else:
		_net_fast.rpc(kind, payload)


func relay(from_peer: int, kind: String, payload: Dictionary, reliable := true) -> void:
	"""房主转发：客户端发来的东西只发给**别人**，不回给发的人。"""
	for peer in peers.keys():
		var p := int(peer)
		if p == 1 or p == from_peer:
			continue
		send_to(p, kind, payload, reliable)


@rpc("any_peer", "call_remote", "reliable")
func _net_reliable(kind: String, payload: Dictionary) -> void:
	_handle(multiplayer.get_remote_sender_id(), kind, payload)


@rpc("any_peer", "call_remote", "unreliable")
func _net_fast(kind: String, payload: Dictionary) -> void:
	_handle(multiplayer.get_remote_sender_id(), kind, payload)


func _handle(peer: int, kind: String, payload: Dictionary) -> void:
	if peers.has(peer):
		(peers[peer] as Dictionary)["last_seen"] = _timeout_t
	match kind:
		NetProtocol.PING:
			# 收到心跳就回一个 PONG（客户端据此知道房主还在）
			if is_host() and peers.has(peer):
				send_to(peer, NetProtocol.PONG, {"t": Time.get_ticks_msec()}, false)
			elif is_client():
				pass
		NetProtocol.PONG:
			pass
	if not peers.has(peer):
		# 第一次见到这个人：先记名字（HELLO 里带），再往上抛
		peers[peer] = {"name": str(payload.get("name", "水手")), "last_seen": _timeout_t}
		emit_signal("peer_joined", peer)
	emit_signal("message", peer, kind, payload)


# ------------------------------------------------------------ 连接事件（ENet 的回调）

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _on_peer_connected(peer: int) -> void:
	# 名字要等对方的 HELLO；先占个位，"最后一个船位"就是靠这个数判断的
	peers[peer] = {"name": "…", "last_seen": _timeout_t}


func _on_peer_disconnected(peer: int) -> void:
	if peers.has(peer):
		peers.erase(peer)
	emit_signal("peer_left", peer)


func _on_connected() -> void:
	my_peer = multiplayer.get_unique_id()
	emit_signal("connected_to_host")


func _on_connect_failed() -> void:
	emit_signal("connection_lost")


func _on_server_disconnected() -> void:
	my_peer = 0
	emit_signal("connection_lost")
