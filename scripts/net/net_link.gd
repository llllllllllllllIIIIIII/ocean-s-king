class_name NetLink
extends Node

# 把 Voyage / Fleet 和 NetSession 接起来（M3）。**它是唯一知道"谁该发什么"的地方。**
#
# 权威归属（docs/13 第 5.1 节）在这一个文件里就能读完：
#
#   房主：① 每 0.5 秒广播一次 WorldState（时钟/风/剧情/日志/已发现的图）；
#         ② 每个客户端的船位摘要，转发给其他客户端；
#         ③ 有人掉线 → 把那条船转成 AI（**不消失**）；
#         ④ 客户端报上来的"世界的改动"（记一条决定）由它落到真源里。
#
#   客户端：① 每 0.05 秒（20Hz）把自己那条船的摘要发给房主；
#           ② 收到 WorldState 就**只读覆盖** —— 客户端自己不许写世界。
#
# 节奏按**真实秒**算：游戏里的 ×36 是快进，网络不该跟着快进 36 倍。
# 远端船用的 100ms 插值延迟也是真实秒（docs/13 M3 卡片）。

signal welcome(ship_id: String, summary: Dictionary, world: Dictionary)
signal rejected(reason: String)

const WORLD_PERIOD := 0.5
const SHIP_PERIOD := 0.05

var voyage: Voyage
var session: NetSession
var _ship_acc := 999.0
var _world_acc := 999.0


func attach(v: Voyage, s: NetSession) -> void:
	voyage = v
	session = s
	if v != null:
		# 双向接上：Voyage.tick_real 要靠 voyage.link 才会每帧推进网络
		# （只设一头的话，房主那一侧永远不会发包 —— 踩过一次）
		v.attach_link(self)
	if not s.message.is_connected(_on_message):
		s.message.connect(_on_message)
	if not s.peer_left.is_connected(_on_peer_left):
		s.peer_left.connect(_on_peer_left)
	if not s.connected_to_host.is_connected(_on_connected):
		s.connected_to_host.connect(_on_connected)
	# 客户端一连上就自报家门；房主把这一条也当成"有人来了"
	if session.is_client():
		_on_connected()


func step(real_delta: float) -> void:
	if voyage == null or session == null or not session.is_online():
		return
	if session.is_client() and session.my_peer == 0:
		return                      # 还没连上，先别发
	_ship_acc += real_delta
	_world_acc += real_delta
	if _ship_acc >= SHIP_PERIOD:
		_ship_acc = 0.0
		var summary := NetProtocol.ship_summary(voyage.local_summary())
		if session.is_host():
			session.broadcast(NetProtocol.SHIP, summary, false)
			# AI 船的动态**只从房主发出**（docs/13 第 5.1 节）：和玩家船一样 20Hz，
			# 远端船靠这串摘要插值 —— 0.5 秒一次的话，快进时 AI 船每包要跳 40 米。
			for id in voyage.fleet.ids_of_kind(Fleet.KIND_AI):
				session.broadcast(NetProtocol.SHIP,
					NetProtocol.ship_summary(voyage.fleet.summary_of(id)), false)
		else:
			session.send_to_host(NetProtocol.SHIP, summary, false)
	if session.is_host() and _world_acc >= WORLD_PERIOD:
		_world_acc = 0.0
		session.broadcast(NetProtocol.WORLD, NetProtocol.world_projection(voyage), true)


func record_decision(text: String) -> void:
	"""客户端的"影响世界"的动作：本地先记一笔（看得见），同时报给房主（真源）。"""
	if voyage == null:
		return
	voyage.journal.decide(text)
	if session != null and session.is_client():
		session.send_to_host(NetProtocol.INPUT, {"kind": "decision", "text": text}, true)


# ------------------------------------------------------------ 收

func _on_connected() -> void:
	if session == null or not session.is_client():
		return
	session.send_to_host(NetProtocol.HELLO, {
		"version": NetProtocol.VERSION,
		"name": session.player_name,
	}, true)


func _on_message(peer: int, kind: String, payload: Dictionary) -> void:
	match kind:
		NetProtocol.HELLO:
			if session.is_host():
				_host_accept(peer, payload)
		NetProtocol.WELCOME:
			if session.is_client():
				emit_signal("welcome", str(payload.get("ship_id", "")),
					payload.get("summary", {}), payload.get("world", {}))
		NetProtocol.FULL:
			if session.is_client():
				emit_signal("rejected", "船位满了（v0.5 最多 4 个人）")
		NetProtocol.SHIP:
			voyage.fleet.receive_summary(payload)
			if session.is_host():
				session.relay(peer, kind, payload, false)   # 星型：由房主转发给别人
		NetProtocol.WORLD:
			if session.is_client():
				NetProtocol.apply_world_projection(voyage, payload)
		NetProtocol.INPUT:
			if session.is_host():
				_apply_input(payload)
		NetProtocol.FIRE:
			# 谁向谁开火。房主：如果被打的是**我这条船**，我就是受击方权威 —— 自己算，
			# 再把结果广播出去；否则转给那条船的拥有者（他才是权威）。
			var target := str(payload.get("target", ""))
			if session.is_host():
				if target == voyage.fleet.local_id:
					_host_resolve_fire(payload)
				else:
					var p := voyage.fleet.peer_of(target)
					if p > 0:
						session.send_to(p, NetProtocol.FIRE, payload, true)
			elif target == voyage.fleet.local_id:
				_client_resolve_fire(payload)
		NetProtocol.NAVAL:
			# 受击方权威的结果：房主广播给所有人；客户端把它记到"对面挨了什么"的账上。
			if session.is_host():
				session.relay(peer, kind, payload, true)
				_apply_naval(payload)
			else:
				_apply_naval(payload)
		NetProtocol.BYE:
			if session.is_host():
				var id := str(payload.get("ship_id", ""))
				if id != "":
					voyage.fleet.detach_player(id, voyage.default_destination())
		NetProtocol.TRADE_REQUEST:
			# M14：交易的第一段。港口库存是**房主权威** —— 申请方不自己动它。
			if session.is_host():
				var result: Dictionary = voyage.host_execute_trade(payload)
				session.send_to(peer, NetProtocol.TRADE_ACK,
					{"req": payload, "result": result}, true)
		NetProtocol.TRADE_ACK:
			# 第二段：回执到手，申请方把**自己的**货与钱落账（拥有者权威）。
			if session.is_client():
				voyage.client_apply_trade(payload)


func send_trade_request(req: Dictionary) -> void:
	"""客户端：把这一笔交易交给房主（"申请"那一段）。"""
	if session == null or not session.is_online():
		return
	if session.is_host():
		var result: Dictionary = voyage.host_execute_trade(req)
		voyage.client_apply_trade({"req": req, "result": result})
		return
	session.send_to_host(NetProtocol.TRADE_REQUEST, req, true)


func send_fire(req: Dictionary) -> void:
	"""开火方：把这一轮舷侧的输入发给**受击方的拥有者**（自己不判命中）。"""
	if session == null or not session.is_online():
		return
	var target := str(req.get("target", ""))
	if session.is_host():
		if target == voyage.fleet.local_id:
			_host_resolve_fire(req)          # 打的是我 —— 我就是受击方权威
		else:
			var p := voyage.fleet.peer_of(target)
			if p > 0:
				session.send_to(p, NetProtocol.FIRE, req, true)
	else:
		session.send_to_host(NetProtocol.FIRE, req, true)


func _host_resolve_fire(req: Dictionary) -> void:
	"""受击方权威：算这一轮 → 落到自己身上 → 把结果广播给所有人。"""
	var res := NavalBattle.resolve(req)
	if voyage.naval != null:
		voyage.naval.apply_incoming(res, voyage.ship)
	session.broadcast(NetProtocol.NAVAL, {"result": res}, true)
	_apply_naval({"result": res})            # broadcast 只发给别人，房主自己也要记账


func _apply_naval(payload: Dictionary) -> void:
	var res: Dictionary = payload.get("result", {})
	if res.is_empty():
		return
	# 只有"我开的炮"才记到"对面挨了什么"那本账上；被打的那一方已经在自己身上算过了
	if str(res.get("shooter", "")) == voyage.fleet.local_id and voyage.naval != null:
		voyage.naval.apply_outgoing(res)


func _client_resolve_fire(req: Dictionary) -> void:
	"""客户端当受击方权威的那一半：算完这一轮 → 落到自己身上 → 发回房主。"""
	var res := NavalBattle.resolve(req)
	if voyage.naval != null:
		voyage.naval.apply_incoming(res, voyage.ship)
	session.send_to_host(NetProtocol.NAVAL, {"result": res}, true)


func _host_accept(peer: int, payload: Dictionary) -> void:
	"""房主分船位：协议版本不符或船位满了，好好说一声。"""
	if int(payload.get("version", -1)) != NetProtocol.VERSION:
		session.send_to(peer, NetProtocol.FULL,
			{"reason": "协议版本不同（对面 v%d，房主 v%d）" % [
				int(payload.get("version", -1)), NetProtocol.VERSION]}, true)
		return
	var name := str(payload.get("name", "水手"))
	var free := voyage.fleet.free_ids()
	if free.is_empty():
		session.send_to(peer, NetProtocol.FULL, {"reason": "船位满了"}, true)
		return
	var id: String = free[0]
	var summary := voyage.fleet.attach_player(id, peer, name)
	var world := NetProtocol.world_projection(voyage)
	world["region"] = voyage.region_path      # 客户端要按同一片海把世界生出来
	world["fleet"] = _fleet_summaries()       # 进来时的船队快照（之后交给 20Hz 的摘要流）
	session.send_to(peer, NetProtocol.WELCOME, {
		"ship_id": id,
		"summary": summary,
		"world": world,
		"fleet": _fleet_summaries(),
	}, true)
	voyage.log_event("（船队）%s 接手了 %s。" % [name, voyage.fleet.name_of(id)])


func _fleet_summaries() -> Array:
	var out := []
	for id in voyage.fleet.ids():
		if id == voyage.fleet.local_id:
			continue
		out.append(NetProtocol.ship_summary(voyage.fleet.summary_of(id)))
	return out


func _apply_input(payload: Dictionary) -> void:
	match str(payload.get("kind", "")):
		"decision":
			voyage.journal.decide(str(payload.get("text", "")))
		_:
			pass


func _on_peer_left(peer: int) -> void:
	"""掉线：这条船**不消失**，就地转 AI 继续走（房主的活）。"""
	if session == null or not session.is_host():
		return
	var slot := voyage.fleet.slot_of_peer(peer)
	if slot.is_empty():
		return
	var id := str(slot["id"])
	voyage.fleet.detach_player(id, voyage.default_destination())
	voyage.log_event("（船队）%s 的人掉线了，船交给大副，继续走。"
		% voyage.fleet.name_of(id))
