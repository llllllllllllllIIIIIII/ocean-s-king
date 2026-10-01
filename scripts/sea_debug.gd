# 海域视图（Day 6 起，M2 扩成大西洋）：把海、岛、礁、洋流画出来，让船开出去。
#
# 相机状态（docs/01 支柱 5）：
#   A 甲板/海面 —— 跟着船
#   C 离船      —— 船长带人上岛，相机跟着船长，船留在海面上自己走（大副接管）
#
# 操作（Day 7 定稿）：
#   开场先是一页标题与背景（陌生人必须知道自己在哪儿、要干什么），按任意键开始
#   左键 = 设目标点（船长在岸上时 = 带队伍走过去）—— 拉到海图尺度也是同一个操作
#   X 抛锚 / 起锚　1/2/3 帆档　+/− 操帆人数
#   L 登陆 / 返船　空格 登陆名单里勾人　Tab 帆态面板　C 船员面板
#   . 快进 ×1/×4/×12/×36（48km 的海不开快进就走不完）　滚轮 缩放
#   走完第三幕 → 一页文本结算（R 重开）
#
# M2 的两件事：
#   ① 地形不再是"一座岛"，而是 `Sea`（= WorldMap）里的全部特征：海岸、群岛、暗礁、洋流；
#   ② 滚轮一路拉远，地形会**淡出**、海图符号**淡入**（同一台相机、同一套世界坐标，
#      所以海图和地形永远对得上）——实现见 `scripts/chart_view.gd`。

extends Node2D

const PPM := 0.5                  # 每米多少像素（zoom=0.25 时整片海 2000px 宽）
const SIM_DT := 0.05
# 海图淡入的窗口：zoom 0.45 还是纯地形，0.16 以下全是海图符号（中间是交叉淡入）
const CHART_FADE_HI := 0.45
const CHART_FADE_LO := 0.16
# 别人的船：拉到这个倍率以下就只画标记与摘要（海图尺度上没人想看四条船的帆）
const FLEET_DETAIL_ZOOM := 0.7
# 一路滚到底的"船内视图"倍率：0.5 × 80 = 40 像素/米，正好等于船内调试视图的比例。
# 也就是说这个场景的相机是**连续的**：整片海 → 海图 → 船 → 船舱，同一套东西。
const SHIP_ZOOM := 80.0
const LAYER_STEP_ZOOM := 1.6

enum Mode { SEA, LAYER }

var voyage: Voyage
var _hud: VoyageHud
var _title: TitleCard
var _ending: EndingPanel
var _hud_layer: CanvasLayer
var _panel_layer: CanvasLayer
var _font: Font
var _cam: Camera2D
var _zoom := 1.0
var _mode: Mode = Mode.SEA
var _layer := 2
var _layer_order: Array[int] = []
var _started := false              # 标题卡关掉之前，一帧模拟都不跑
# ×36 是 M2 加的：海从 8km 变成 48km，只有 ×12 的话横渡一次要二十多分钟真实时间。
# 物理步长不变（快进永远是多跑几步，不是把 dt 乘大），所以气动不会被快进弄飘。
var _time_scales: Array[float] = [1.0, 4.0, 12.0, 36.0]
var _time_scale_idx := 0
var _last_head := -1               # 上一次看到的"演到第几幕"，用来放剧情卡
var _act_card_timer := 0.0         # 剧情卡的剩余播放时间（真实秒）
var _act_card_seconds := 9.0       # 剧情卡放多久（截图模式下压到 2 秒，免得挡住一组图）
var _picker: LandingPicker
var _shot_mode := false
var _frame := 0
var _shot_dir := "res://.shots"
var _wind_gizmo: WindGizmo
var _ship_view: ShipRenderer       # 海图上用**真正的 SVG 船**，不是占位三角块
var _chart: ChartView              # M2：拉远之后淡入的海图层
var _fleet_views := {}             # M3：别人的船（id -> ShipRenderer）——只看外观，没有逐人细节
var _session: NetSession           # M3：联机会话（单机时也在，只是没开）
var _net: NetLink                  # M3：把船队与世界接上网络的胶水
var _room: RoomPanel               # M3：房间界面（开房间 / 加入 / 单机）
var _port_panel: PortPanel         # M4：港口面板（补给 / 修船 / 买卖）
var _dilemma_card: DilemmaCard     # M5：抉择卡（缺粮 / 重伤病 / 部落冲突）
var _panel: SailPanel
var _show_panel := false
var _crew_panel: CrewPanel
var _show_crew_panel := false


func _ready() -> void:
	_shot_mode = OS.get_cmdline_user_args().has("shots")
	voyage = Voyage.new()
	voyage.setup(Sea.ATLANTIC_PATH)
	# 海图层要先于船加进来：Node2D 的子节点按加入顺序画，
	# 所以顺序是"地形（本节点的 _draw）→ 海图 → 船"。
	_chart = ChartView.new()
	_chart.world = voyage.sea.world
	_chart.voyage = voyage
	_chart.px_per_m = PPM
	add_child(_chart)
	# 别人的船：一艘一个渲染器，只画外观。它们**没有**船员点 —— 别人船上
	# 没有逐人模拟，这是 docs/14 那条 UI 规矩的画面形态。
	for rid in voyage.fleet.others():
		var rv := ShipRenderer.new()
		rv.px_per_m = PPM
		rv.draw_sea = false
		rv.show_ghost = false
		add_child(rv)
		rv.setup()
		_fleet_views[rid] = rv
	_ship_view = ShipRenderer.new()
	_ship_view.px_per_m = PPM
	_ship_view.draw_sea = false        # 海面由这个场景自己画
	_ship_view.show_ghost = false
	add_child(_ship_view)
	_ship_view.setup()
	_ship_view.apply_pose(voyage.ship.position_m(), voyage.ship.heading_deg())
	_layer_order.assign(_ship_view.layers.keys())
	_layer_order.sort()
	_layer_order.reverse()              # [3, 2, 1, 0]，下标越大层越低
	_cam = Camera2D.new()
	add_child(_cam)
	_font = _pick_font()
	_chart.font = _font
	_build_hud()
	_build_overlays()
	_build_net()
	_zoom = 0.8                         # 开局在港里：看得见自己的船、锚地和这段海岸
	_update_camera()
	_update_hud()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_shot_dir))
	# 截图模式不等人：直接开演（标题卡由时间线自己在第 2 帧截一张）
	_started = _shot_mode
	if not _shot_mode:
		_act_card_seconds = 9.0
		# 先摆房间界面：单机 / 开房间 / 加入。选完才开始一局。
		_show_overlay(_title, false)
		_hud_layer.visible = false
		_panel_layer.visible = false
		_room.open()
	else:
		_act_card_seconds = 2.0


func _build_net() -> void:
	"""联机的接线（M3）。**单机也走这一套对象**，只是没有开网络：
	这样"1 个人 + 3 条 AI"和"4 个人"共用同一条代码路径（docs/13 M3 卡片第 4 条）。"""
	_session = NetSession.new()
	_session.name = "NetSession"        # RPC 按节点路径找方法：两端必须同名同路径
	add_child(_session)
	_net = NetLink.new()
	_net.name = "NetLink"
	add_child(_net)
	_net.welcome.connect(_on_welcome)
	_net.rejected.connect(_on_rejected)

	var cl := CanvasLayer.new()
	cl.layer = 10                        # 比标题卡还高一层
	add_child(cl)
	_room = RoomPanel.new()
	_room.font = _font
	_room.session = _session
	_room.voyage = voyage
	_room.size = get_viewport_rect().size
	_room.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_room.visible = false
	_room.choose.connect(_on_room_choose)
	cl.add_child(_room)

	# M5：抉择卡比标题卡低一层、比航行界面高一层（它不遮住整屏，只是把桌上摊开）
	var cl_d := CanvasLayer.new()
	cl_d.layer = 7
	add_child(cl_d)
	_dilemma_card = DilemmaCard.new()
	_dilemma_card.font = _font
	_dilemma_card.voyage = voyage
	_dilemma_card.size = get_viewport_rect().size
	_dilemma_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dilemma_card.visible = false
	cl_d.add_child(_dilemma_card)


func _on_room_choose(mode: String, ip: String) -> void:
	match mode:
		RoomPanel.MODE_SOLO:
			_room.visible = false
			_begin_voyage(true)
		RoomPanel.MODE_HOST:
			var r := _session.host_game(NetSession.PORT, "房主")
			if not bool(r.get("ok", false)):
				_room.hint = str(r.get("reason", "开不了房间"))
				_room.queue_redraw()
				return
			_net.attach(voyage, _session)
			_room.visible = false
			voyage.say("（船队）房间开在 %d 端口。别人用你的 IP 连进来。" % NetSession.PORT, true)
			_begin_voyage(true)
		RoomPanel.MODE_JOIN:
			var ip2 := ip.strip_edges()
			var port := NetSession.PORT
			if ip2.contains(":"):
				var parts := ip2.split(":")
				ip2 = parts[0]
				port = int(parts[1])
			var r2 := _session.join_game(ip2, port, "水手")
			if not bool(r2.get("ok", false)):
				_room.hint = str(r2.get("reason", "连不上"))
				_room.queue_redraw()
				return
			# 连上之后**等 WELCOME**：房主会告诉我们开哪条船、世界现在什么样
			_net.attach(voyage, _session)
			_room.hint = "连上了，等房主分配船位…"
			_room.queue_redraw()


func _on_welcome(ship_id: String, summary: Dictionary, world: Dictionary) -> void:
	"""客户端拿到船位：按房主的分配把这一局重新生出来（同一个 Voyage 对象，引用不失效）。"""
	var region := str(world.get("region", Sea.ATLANTIC_PATH))
	voyage.setup(region, ship_id, summary)
	NetProtocol.apply_world_projection(voyage, world)
	_ship_view.apply_pose(voyage.ship.position_m(), voyage.ship.heading_deg())
	_chart.world = voyage.sea.world
	_zoom = 0.8
	_room.visible = false
	_started = true
	voyage.say("（船队）你接手了 %s。海上的风与时间跟着房主走。" % voyage.fleet.name_of(ship_id), true)
	_update_camera()


func _on_rejected(reason: String) -> void:
	_room.hint = reason
	_room.queue_redraw()
	_room.visible = true
	_session.leave()


func _begin_voyage(show_title: bool) -> void:
	_room.visible = false
	_started = not show_title
	if show_title:
		_show_overlay(_title, true)
	else:
		_hud_layer.visible = true
		_panel_layer.visible = true


func _process(delta: float) -> void:
	if _shot_mode:
		_run_shot_timeline()
		return
	if _session != null:
		_session.poll(delta)
	if _started:
		_tick_sim(delta)
		voyage.tick_real(delta)        # 网络与远端船插值走**真实时间**（不跟快进）
		voyage.tick_ui(delta)          # 消息条按真实时间消失，不跟着快进闪过去
	if _act_card_timer > 0.0:
		_act_card_timer = maxf(0.0, _act_card_timer - delta)
	_update_camera()
	_update_hud()
	queue_redraw()


func _tick_sim(delta: float) -> void:
	"""推进模拟。快进不是"把 dt 乘大" —— 那样物理步会变粗、气动跟着飘。
	这里永远是固定步长 SIM_DT，快进只是每帧多跑几步。"""
	var scale := _time_scales[_time_scale_idx]
	var real_dt := minf(delta, 0.1)
	if scale <= 1.0:
		voyage.tick(real_dt)
	else:
		var steps := int(real_dt * scale / SIM_DT)
		for _i in steps:
			voyage.tick(SIM_DT)


func _update_camera() -> void:
	_zoom = clampf(_zoom, _min_zoom(), SHIP_ZOOM)
	if _mode == Mode.LAYER:
		# 沉进船舱了：相机锁在船体中心（和船内调试视图一样）
		_cam.position = _ship_view.hull_center_world_px()
		_cam.zoom = Vector2(_zoom, _zoom)
	elif voyage.ashore:
		# 状态 C：相机跟着船长，船离屏
		_cam.position = _clamp_camera(voyage.captain_pos * PPM)
		# 只放近一点点：放太多的话船会跑出画面，"人在哪下船"就看不清了
		_cam.zoom = Vector2(_zoom * 2.0, _zoom * 2.0)
	else:
		_cam.position = _clamp_camera(voyage.ship.position_m() * PPM)
		_cam.zoom = Vector2(_zoom, _zoom)
	_sync_chart()


func _clamp_camera(pos: Vector2) -> Vector2:
	"""相机不许把世界推出画面：看得见整片海时居中，看得见局部时贴着边。

	没有这一步，拉到最远时画面是"船在世界的一角、其余全是空" ——
	M2 的验收（拉到最远能看到整张海图）就废了。
	"""
	var view := get_viewport_rect().size / _zoom     # 屏幕换来世界像素
	var wpx := voyage.sea.size_m() * PPM
	if view.x >= wpx.x:
		pos.x = wpx.x * 0.5
	else:
		pos.x = clampf(pos.x, view.x * 0.5, wpx.x - view.x * 0.5)
	if view.y >= wpx.y:
		pos.y = wpx.y * 0.5
	else:
		pos.y = clampf(pos.y, view.y * 0.5, wpx.y - view.y * 0.5)
	return pos


func _min_zoom() -> float:
	"""最小缩放 = 整片海刚好铺满屏幕。

	v0.1 的海是 8km，随便一个倍率都装得下；M2 的海是 48km，
	所以"拉到最远"这件事必须由海的大小算出来，不能写死。
	**两轴都要看**：只看宽度的话，竖着的 48km 会被上下切掉两截。
	"""
	var vp := get_viewport_rect().size
	var world_px := voyage.sea.size_m() * PPM
	var fit := minf(vp.x / maxf(world_px.x, 1.0), vp.y / maxf(world_px.y, 1.0))
	return clampf(fit * 0.94, 0.01, 0.5)


func _chart_fade() -> float:
	"""海图符号的透明度：拉到最远是 1（纯海图），贴近了是 0（纯地形）。"""
	return clampf((CHART_FADE_HI - _zoom) / (CHART_FADE_HI - CHART_FADE_LO), 0.0, 1.0)


func _sync_chart() -> void:
	if _chart == null:
		return
	_chart.fade = _chart_fade()
	_chart.zoom = _zoom
	_chart.visible = _chart.fade > 0.01
	_chart.queue_redraw()


func _sync_ship_view() -> void:
	"""把船的状态交给真正的渲染器（和船内视图是同一个 ShipRenderer）。"""
	var snap := voyage.ship.snapshot()
	_ship_view.apply_pose(voyage.ship.position_m(), voyage.ship.heading_deg())
	_ship_view.sail_main_rad = deg_to_rad(180.0 - float(snap["sail_main_deg"]))
	_ship_view.sail_jib_rad = deg_to_rad(180.0 - float(snap["sail_jib_deg"]))
	_ship_view.sail_state = int(voyage.orders.sail_level)
	_ship_view.anchored = voyage.ship.is_anchored()
	_ship_view.layer = _layer
	_ship_view.show_ghost = _zoom > 20.0        # 拉到能看清船了才画上层虚影
	# 注意：这里**不能**打开渲染器自带的海面矩形 —— 它是一块画在世界坐标里的深色底，
	# 近距离时会把海图（岛、礁、洋流）整块盖住，玩家就看不到附近地形了。
	_ship_view.draw_sea = false
	_ship_view.zoom = _zoom
	_ship_view.crew_dots = _crew_dots()
	_ship_view.queue_redraw()


func _crew_dots() -> Array:
	"""只有在看得清船的距离上才画人（海图尺度下那只是几个亚像素的点）。"""
	var out := []
	if _zoom < 20.0 or voyage.roster == null:
		return out
	for m in voyage.roster.members:
		if m.at.z != _layer or m.ashore:
			continue
		out.append({"x": m.at.x, "y": m.at.y, "color": _job_color(m.job), "key": m.is_key})
	return out


func _job_color(job: String) -> Color:
	match job:
		"sail": return Color(0.45, 0.75, 1.0)
		"helm": return Color(1.0, 0.85, 0.4)
		"lookout": return Color(0.6, 1.0, 0.6)
		"cook": return Color(1.0, 0.6, 0.35)
		"repair": return Color(0.85, 0.85, 0.9)
		"chores": return Color(0.9, 0.9, 0.6)
		"eat": return Color(1.0, 0.95, 0.5)
		"sleep": return Color(0.7, 0.6, 1.0)
		_: return Color(0.72, 0.74, 0.78)


# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	if voyage == null:
		return
	var sea := voyage.sea
	var a := 1.0 - _chart_fade()        # 拉远时地形淡出，让位给海图
	# 世界之外也是海：不铺这一层的话，拉到最远时世界外面是引擎的默认灰底，
	# 看着像"地图被人剪下来了"。
	var pad := maxf(6000.0, sea.size_m().x * 0.3) * PPM
	draw_rect(Rect2(Vector2(-pad, -pad), sea.size_m() * PPM + Vector2(2.0 * pad, 2.0 * pad)),
		Color("#08141d"), true)
	if a > 0.01:
		_draw_terrain(a)
	_draw_tile_seams(a)
	# 船：交给真正的 ShipRenderer 画（海图和船内视图是同一个渲染器）
	_sync_ship_view()
	_draw_fleet_marks(a)
	# 拉远到看不清船的时候，给一个明显的光点，免得找不到自己的船
	if _zoom < 0.7:
		var sp := voyage.ship.position_m() * PPM
		draw_circle(sp, 10.0, Color(1.0, 0.92, 0.55, 0.20))
		draw_arc(sp, 10.0, 0.0, TAU, 20, Color(1.0, 0.95, 0.7, 0.85), 2.0)
	if voyage.ashore:
		# 登陆队：每人一个点（船上还没下来的画在船边，下来的在岸上排成队形）
		var k := _marker_scale()
		for e in voyage.party.entries:
			var st: String = e["state"]
			if st == "onboard":
				continue
			var at: Vector2 = (e["pos"] as Vector2) * PPM
			var is_key: bool = e["key"]
			var col := Color(0.98, 0.86, 0.45, 0.95) if is_key else Color(0.85, 0.88, 0.92, 0.95)
			if is_key:
				draw_circle(at, 7.0 * k, Color(0.08, 0.09, 0.12, 0.9))
				draw_circle(at, 5.0 * k, col)
			else:
				draw_circle(at, 4.0 * k, col)
		# 队长（船长本人）
		var c := voyage.party.captain * PPM
		draw_circle(c, 8.0 * k, Color(1.0, 0.85, 0.35))
		draw_arc(c, 13.0 * k, 0, TAU, 20, Color(1.0, 0.9, 0.5, 0.6), 2.0 * k * 2.0)
	# 航线：从船到目标点
	if voyage.orders.has_target_point:
		draw_dashed_line(voyage.ship.position_m() * PPM, voyage.orders.target_point * PPM,
			Color(0.5, 1.0, 0.7, 0.4), 2.0, 10.0)
	# 抉择做完了（上过岸，或者把岛甩在了身后）：把回港的方向标出来。
	# 没有它，第三幕的"返航"就只是一句话，玩家不知道往哪儿开。
	if voyage.story.fired("act2") and not voyage.story.fired("act3") \
			and not voyage.ashore and voyage.story.objective.begins_with("返航"):
		var port_pos := sea.port_pos()
		var home := voyage.ship.position_m().lerp(port_pos, 0.5)
		draw_dashed_line(voyage.ship.position_m() * PPM,
			port_pos * PPM, Color(1.0, 0.85, 0.45, 0.32), 2.0, 14.0)
		draw_arc(port_pos * PPM, 22.0 * _marker_scale(), 0.0, TAU, 32,
			Color(1.0, 0.86, 0.45, 0.8), 2.0)
		_label(home, "返航点：出发港", Color(1.0, 0.88, 0.5))


func _draw_terrain(a: float) -> void:
	"""地形：全部来自 `Sea` 里的特征，视图不再认识"岛/礁/流"这些具体名字。"""
	var sea := voyage.sea
	var w := sea.world
	# 洋流带（画在陆地下面：它本来就是水）
	for f in w.of_kind("current"):
		var shape: Dictionary = f["shape"]
		Geom2D.draw_shape(self, shape, Color(0.35, 0.75, 0.9, 0.16 * a), PPM)
		var pts: PackedVector2Array = shape["points"]
		for i in range(pts.size() - 1):
			_arrow(pts[i] * PPM, pts[i + 1] * PPM, Color(0.45, 0.85, 1.0, 0.5 * a), 2.0)
	# 陆地：先画沙滩（整个外形），再用干地形状盖出内陆
	var dry := sea.land_shapes(true)
	var lands := sea.lands()
	for i in lands.size():
		var f: Dictionary = lands[i]
		Geom2D.draw_shape(self, f["shape"], Color(0.78, 0.72, 0.5, 0.9 * a), PPM)
		if i < dry.size():
			Geom2D.draw_shape(self, dry[i], Color(0.32, 0.5, 0.28, 0.95 * a), PPM)
		Geom2D.draw_shape_outline(self, f["shape"], Color(0.9, 0.85, 0.65, 0.8 * a), 2.0, PPM)
		if voyage.known_places.has(str(f["id"])):
			_label(Geom2D.centroid(f["shape"]) * PPM, str(f.get("name", "")),
				Color(0.95, 0.95, 0.8, a))
	# 暗礁
	for f in w.of_kind("reef"):
		var c := Geom2D.centroid(f["shape"]) * PPM
		var r := Geom2D.extent(f["shape"]) * PPM
		draw_circle(c, r, Color(0.6, 0.35, 0.3, 0.35 * a))
		draw_arc(c, r, 0, TAU, 32, Color(0.9, 0.55, 0.45, 0.8 * a), 2.0)
		_label(c, str(f.get("name", "")), Color(1.0, 0.7, 0.6, a))
	# 港口
	for p in sea.ports():
		var pc := Geom2D.centroid(p["shape"]) * PPM
		var pr := Geom2D.extent(p["shape"]) * PPM
		draw_circle(pc, pr, Color(0.35, 0.5, 0.65, 0.20 * a))
		# 锚地用虚线圈：海图上"能下锚的地方"就是这么画的，实心圆盘太像 UI 了
		var seg := 48
		for i in seg:
			if i % 2 == 1:
				continue
			var a0 := TAU * float(i) / float(seg)
			var a1 := TAU * float(i + 1) / float(seg)
			draw_arc(pc, pr, a0, a1, 4, Color(0.6, 0.8, 1.0, 0.75 * a), 2.0)
		_label(pc, str(p.get("name", "")), Color(0.7, 0.85, 1.0, a))
	# 地标：只有认得名字的陆地才画（别提前把没去过的地方剧透了）
	for f in lands:
		if not voyage.known_places.has(str(f["id"])):
			continue
		for poi in f.get("pois", []):
			var pp: Array = poi["pos"]
			var v := Vector2(float(pp[0]), float(pp[1])) * PPM
			var seen := voyage.visited.has(str(poi["id"]))
			var col := Color(0.6, 1.0, 0.7, a) if seen else Color(0.95, 0.9, 0.5, a)
			draw_circle(v, 5.0 * _marker_scale(), col)
			draw_arc(v, float(poi.get("radius_m", 0.0)) * PPM, 0, TAU, 24,
				Color(col, 0.45 * a), 1.5)
			_label(v, str(poi["name"]), col)


func _sync_fleet_views() -> void:
	"""把船队摘要灌进"别人的船"的渲染器（位姿 / 帆档 / 锚 / 缩放）。

	别人船上没有逐人模拟，所以这里**没有**船员点可选 —— 那不是省事，是规矩。
	"""
	for id in _fleet_views.keys():
		var rv: ShipRenderer = _fleet_views[id]
		var sm := voyage.fleet.summary_of(id)
		if sm.is_empty():
			rv.visible = false
			continue
		var p: Array = sm["pos"]
		rv.apply_pose(Vector2(float(p[0]), float(p[1])), float(sm["heading"]))
		rv.sail_state = int(sm["sail_level"])
		rv.anchored = bool(sm["anchored"])
		rv.zoom = _zoom
		rv.draw_sea = false
		rv.show_ghost = false
		# 拉远到看不清船了：只留标记与摘要（海图尺度上没人想看四条船的帆）
		rv.visible = _zoom >= FLEET_DETAIL_ZOOM and not voyage.ashore
		rv.queue_redraw()


func _draw_fleet_marks(_a: float) -> void:
	"""别人的船：近处看外观，远处看一个点 + 名字 + 它自己在干什么 + 船体%。"""
	_sync_fleet_views()
	var eff := _zoom * (2.0 if voyage.ashore else 1.0)
	for id in _fleet_views.keys():
		var sm := voyage.fleet.summary_of(id)
		if sm.is_empty():
			continue
		var p: Array = sm["pos"]
		var at := Vector2(float(p[0]), float(p[1])) * PPM
		var hull := float(sm.get("hull_pct", 1.0))
		var col := Color(0.88, 0.93, 1.0, 0.95) if hull > 0.6 \
			else Color(1.0, 0.72, 0.55, 0.95)
		if randf() < 2.0:                         # 便宜的点：远近都画一个亮点
			draw_circle(at, 5.0 / maxf(eff, 0.05), Color(0.06, 0.09, 0.13, 0.8))
			draw_circle(at, 3.0 / maxf(eff, 0.05), col)
		if eff > 8.0:
			continue
		# 摘要行：**只有**名字、在干什么、船体% —— 别人的船能看到的就这些
		var size := maxi(9, int(13.0 / maxf(eff, 0.05)))
		if _font != null:
			draw_string(_font, at + Vector2(9.0, -8.0) / maxf(eff, 0.05),
				"%s　%s　%.0f%%" % [str(sm["name"]), str(sm["action"]), hull * 100.0],
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_tile_seams(a: float) -> void:
	"""分块的缝：世界是 16km 一块拼起来的，拉远到能看见一整块以上时淡淡地标出来。

	它同时也是"跨块不跳变"的画面证据 —— 截图里能看到船压着缝走，而地形是连续的。
	"""
	var w := voyage.sea.world
	if w.tiles.x * w.tiles.y <= 1 or _zoom > 1.6:
		return
	var col := Color(0.55, 0.72, 0.85, 0.24 * a)
	var size := w.world_m
	for tx in range(1, w.tiles.x):
		var x := float(tx) * w.tile_m * PPM
		draw_dashed_line(Vector2(x, 0.0), Vector2(x, size.y * PPM), col, 1.5, 26.0)
	for ty in range(1, w.tiles.y):
		var y := float(ty) * w.tile_m * PPM
		draw_dashed_line(Vector2(0.0, y), Vector2(size.x * PPM, y), col, 1.5, 26.0)
	# 每条缝旁边标一下"块号"，截图里一眼能看出船是从哪一块开到哪一块的
	if _zoom < 0.6:
		for ty in w.tiles.y:
			for tx in w.tiles.x:
				var t := Vector2i(tx, ty)
				var c := (w.tile_rect(t).position + Vector2(700.0, 900.0)) * PPM
				_label(c, "%s%s" % [char(65 + tx), ty + 1],
					Color(0.55, 0.72, 0.85, 0.35 * a))


func _arrow(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	draw_line(a, b, col, width)
	var d := (b - a).normalized()
	var n := Vector2(-d.y, d.x)
	var mid := a.lerp(b, 0.5)
	draw_colored_polygon(PackedVector2Array([
		mid + d * 14.0, mid + n * 8.0, mid - n * 8.0]), col)


func _label(at: Vector2, text: String, col: Color) -> void:
	# 地名只在"看地图"的距离上画：字号按相机缩放反向补偿，屏幕上恒定 ~14px。
	# 拉得很近时干脆不画 —— 那会儿画面上全是沙滩，地名会变成糊在脸上的巨字。
	var eff := _zoom * (2.0 if voyage.ashore else 1.0)
	if eff > 3.0:
		return
	var size := maxi(8, int(14.0 / eff))
	draw_string(_font, at + Vector2(9, 5) / eff, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		size, col)


func _marker_scale() -> float:
	"""标记点（人、地标圆点）按屏幕尺寸画：不管拉多远拉多近，看上去都一样大。

	世界单位画点的话，一拉近就变成糊在屏幕上的大色块（队形会糊成一坨）。
	"""
	var eff := _zoom * (2.0 if voyage.ashore else 1.0)
	return 1.0 / maxf(eff, 0.05)


# ------------------------------------------------------------------ 输入

func _unhandled_input(event: InputEvent) -> void:
	if _shot_mode:
		return
	# 房间界面摊在桌上：它的键它自己吃（1/2/3、I 编辑 IP、回车连接）
	if _room != null and _room.visible and event is InputEventKey \
			and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if _room.handle_key(event as InputEventKey):
			return
	if _port_panel != null and _port_panel.visible and event is InputEventKey \
			and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if _port_panel.handle_key(event as InputEventKey):
			return
	# 抉择卡优先：桌上摊着一件要拿主意的事，别的键先让它
	if _dilemma_card != null and _dilemma_card.visible and event is InputEventKey \
			and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if _dilemma_card.handle_key(event as InputEventKey):
			return
	# 标题卡还摊在桌上：任何键、任何一次点击 = 开始（这是"陌生人 15 分钟"的第一道门）
	if _title.visible:
		var pressed := (event is InputEventKey and (event as InputEventKey).pressed) \
			or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
		if pressed:
			_show_overlay(_title, false)
			_started = true
		return
	# 结算页：R 再走一趟，Esc 收起来继续看海（别的键不管）
	if _ending.visible:
		if event is InputEventKey and (event as InputEventKey).pressed \
				and not (event as InputEventKey).echo:
			match (event as InputEventKey).keycode:
				KEY_R:
					get_tree().reload_current_scene()
				KEY_ESCAPE:
					_show_overlay(_ending, false)
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_wheel(-1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_wheel(1)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			var world := get_viewport().get_canvas_transform().affine_inverse() * mb.position
			var target := world / PPM
			if voyage.ashore:
				voyage.move_party_to(target)
			else:
				voyage.orders.set_target_point(target)
		_update_camera()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_key(event as InputEventKey)
		_update_camera()


func _wheel(dir: int) -> void:
	"""滚轮就是一根轴：整片海 → 海图 → 船 → 穿过甲板沉进船舱。

	这一条是刻意的：玩家不需要在"看船"和"看海"之间切场景 —— 同一套相机，
	同一艘船，只是拉远拉近。拉到最近还继续向下，就进入船内分层模式。
	"""
	if _mode == Mode.LAYER:
		var idx := _layer_order.find(_layer) + dir
		if idx < 0:                              # 在最上层继续向上 -> 回到缩放
			_mode = Mode.SEA
			_layer = 2
		else:
			_layer = _layer_order[clampi(idx, 0, _layer_order.size() - 1)]
	else:
		if dir > 0 and _zoom >= SHIP_ZOOM:
			_mode = Mode.LAYER                   # 拉到最近再向下 -> 沉入船舱
			_layer = _layer_order[_layer_order.find(_layer) + 1]
		else:
			_zoom = clampf(_zoom * (1.2 if dir > 0 else 1.0 / 1.2),
				_min_zoom(), SHIP_ZOOM)
	_update_camera()
	_update_hud()
	queue_redraw()


func _key(k: InputEventKey) -> void:
	match k.keycode:
		KEY_X:
			voyage.orders.anchored = not voyage.orders.anchored
			if voyage.orders.anchored:
				voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
			else:
				voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
		KEY_1:
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
		KEY_2:
			voyage.orders.set_sail_level(ShipOrders.SailLevel.REEF)
		KEY_3:
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
		KEY_EQUAL, KEY_KP_ADD:
			voyage.orders.set_hands(voyage.orders.hands_on_sails + 1)
		KEY_MINUS, KEY_KP_SUBTRACT:
			voyage.orders.set_hands(voyage.orders.hands_on_sails - 1)
		KEY_PERIOD:
			_time_scale_idx = (_time_scale_idx + 1) % _time_scales.size()
			voyage.say("时间 ×%d。" % int(_time_scales[_time_scale_idx]))
		KEY_L:
			if voyage.ashore:
				var msg := voyage.return_to_ship()
				voyage.say("（船长）" + msg, true)
			elif voyage.can_land():
				_picker.open(voyage.roster)
				_picker.visible = true
			else:
				voyage.say("还没到滩头：先把船开过去，抛锚（X），再按 L。", true)
		KEY_SPACE:
			if _picker.visible:
				_picker.toggle_current()
			elif _show_crew_panel:
				voyage.say("（船员）" + _crew_panel.cycle_priority(), false)
			else:
				voyage.orders.clear_target_point()
		KEY_UP, KEY_W:
			if _picker.visible:
				_picker.move(-1)
			elif _show_crew_panel:
				_crew_panel.move_selection(-1, 0)
		KEY_DOWN, KEY_S:
			if _picker.visible:
				_picker.move(1)
			elif _show_crew_panel:
				_crew_panel.move_selection(1, 0)
		KEY_LEFT, KEY_A:
			if _show_crew_panel:
				_crew_panel.move_selection(0, -1)
		KEY_RIGHT, KEY_D:
			if _show_crew_panel:
				_crew_panel.move_selection(0, 1)
		KEY_ENTER, KEY_KP_ENTER:
			if _picker.visible:
				_picker.visible = false
				voyage.land(_picker.selected_ids(), _picker.hands)
		KEY_TAB:
			if _show_crew_panel:
				# M5：船员面板里，Tab 在"名单"和"规矩"之间切换焦点
				voyage.say("（船员）" + _crew_panel.toggle_focus(), false)
				return
			_show_panel = not _show_panel
			_panel.visible = _show_panel
			if _show_panel:
				voyage.story.note("open_sail_panel")
		KEY_C:
			_show_crew_panel = not _show_crew_panel
			_crew_panel.visible = _show_crew_panel
		KEY_P:
			# M4：靠港与港口面板。没靠港就先抛锚靠上去 —— 面板不自己动船，
			# 它只是把"能不能靠港"这件事说清楚。
			if _port_panel.visible:
				_port_panel.visible = false
			elif voyage.docked_port != "":
				_port_panel.row = 0
				_port_panel.visible = true
			elif voyage.can_dock():
				var r := voyage.dock()
				if r == "":
					_port_panel.row = 0
					_port_panel.visible = true
				else:
					voyage.say("（港口）" + r, true)
			else:
				voyage.say("靠港要先抛锚（X），而且得停在港口的锚地圈里。", true)
		KEY_ESCAPE:
			_picker.visible = false
			_port_panel.visible = false
		KEY_F5:
			# 存档：M1 的界面先做到"两个键 + 一条消息"（docs/13 的砍单预案允许这样）
			var r := SaveGame.save_game(voyage, "auto")
			print("[save] ", r)
			voyage.say("（存档）" + ("已写入 %s" % str(r.get("path", ""))
				if bool(r.get("ok", false)) else "失败：" + str(r.get("reason", ""))), true)
		KEY_F9:
			var r := SaveGame.load_into(voyage, "auto")
			print("[load] ", r)
			voyage.say("（读档）" + ("已从 %s 读回来" % str(r.get("path", ""))
				if bool(r.get("ok", false)) else "失败：" + str(r.get("reason", ""))), true)


# ------------------------------------------------------------------ HUD 与面板

func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud_layer = cl
	_hud = VoyageHud.new()
	_hud.font = _font
	_hud.voyage = voyage
	_hud.size = get_viewport_rect().size
	# 界面不接鼠标：所有输入都走 _unhandled_input（点目标点、带队上岸）
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(_hud)

	_wind_gizmo = WindGizmo.new()
	_wind_gizmo.font = _font
	var side := 200.0
	_wind_gizmo.size = Vector2(side, side)
	_wind_gizmo.position = get_viewport_rect().size - Vector2(side + 18.0, side + 18.0)
	cl.add_child(_wind_gizmo)

	var cl2 := CanvasLayer.new()
	cl2.layer = 2
	add_child(cl2)
	_panel_layer = cl2
	_panel = SailPanel.new()
	_panel.font = _font
	_panel.size = SailPanel.PANEL
	_panel.position = (get_viewport_rect().size - SailPanel.PANEL) * 0.5
	_panel.visible = false
	cl2.add_child(_panel)
	_picker = LandingPicker.new()
	_picker.font = _font
	_picker.size = LandingPicker.PANEL
	_picker.position = (get_viewport_rect().size - LandingPicker.PANEL) * 0.5
	_picker.visible = false
	cl2.add_child(_picker)
	_crew_panel = CrewPanel.new()
	_crew_panel.font = _font
	_crew_panel.voyage = voyage
	_crew_panel.size = CrewPanel.PANEL
	_crew_panel.position = (get_viewport_rect().size - CrewPanel.PANEL) * 0.5
	_crew_panel.visible = false
	cl2.add_child(_crew_panel)
	# M4：港口面板 —— 和帆态/船员面板同一层，靠港时按 P 摊开
	_port_panel = PortPanel.new()
	_port_panel.font = _font
	_port_panel.voyage = voyage
	_port_panel.size = get_viewport_rect().size
	_port_panel.visible = false
	cl2.add_child(_port_panel)


func _build_overlays() -> void:
	"""标题卡与结算页：盖在整幅画面最上面，而且不接鼠标（点击要能漏到下面去）。"""
	var cl := CanvasLayer.new()
	cl.layer = 8
	add_child(cl)
	var vp := get_viewport_rect().size
	_ending = EndingPanel.new()
	_ending.font = _font
	_ending.size = vp
	_ending.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ending.visible = false
	cl.add_child(_ending)

	var cl2 := CanvasLayer.new()
	cl2.layer = 9
	add_child(cl2)
	_title = TitleCard.new()
	_title.font = _font
	_title.title = voyage.story.title
	_title.subtitle = voyage.story.subtitle
	_title.heading = voyage.story.opening_heading
	_title.body = voyage.story.opening_body
	_title.hint = voyage.story.opening_hint
	_title.size = vp
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.visible = false
	cl2.add_child(_title)


func _show_overlay(card: Control, on: bool) -> void:
	"""标题卡 / 结算页是"幕间"：铺开的时候把航行界面整层收起来。

	不收起的话半透明的底会把左上角的目标卡、右下角的风玫瑰透出来，
	画面看着像两个界面糊在一起（第一版截图就是这个样子）。
	"""
	card.visible = on
	var play_ui := not on and not (_ending != null and _ending.visible)
	_hud_layer.visible = play_ui
	_panel_layer.visible = play_ui


func _update_hud() -> void:
	if _hud == null:
		return
	_wind_gizmo.set_wind(voyage.wind.from_dir_deg, voyage.wind.tws_ms)
	# 新的一幕落下来了：把剧情卡摆出来。用**真实**秒计时，快进时才不会一闪而过。
	if voyage.story.head != _last_head:
		_last_head = voyage.story.head
		if _last_head >= 0:
			_act_card_timer = _act_card_seconds
	if _show_panel:
		_panel.update_from(voyage.ship, voyage.crew, voyage.nav, voyage.orders)
	if _show_crew_panel:
		_crew_panel.update_from(voyage.roster)
	if _port_panel.visible:
		_port_panel.queue_redraw()
	# M5：有抉择等着，就把卡摊开（卡片自己从 Voyage 读，不替玩家决定）
	_dilemma_card.refresh()
	_hud.time_scale = _time_scales[_time_scale_idx]
	_hud.act_card_timer = _act_card_timer
	_hud.mode_line = ("船舱 L%d %s　高程 %+.0f 米（向上滚回甲板）" % [
		_layer, _ship_view.layer_name(_layer), _ship_view.layer_elevation(_layer)]
		if _mode == Mode.LAYER else "")
	_hud.queue_redraw()


func _pick_font() -> Font:
	for p in ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]:
		if not FileAccess.file_exists(p):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(p) == OK:
			return f
	push_warning("没找到中文字体，标签可能显示为方块")
	return ThemeDB.fallback_font


# ------------------------------------------------------------------ 截图

func _run_shot_timeline() -> void:
	_frame += 1
	# 截图模式里没有真实时间流逝（一帧就是一步），剧情卡按"一帧 = 0.4 秒"淡出
	if _act_card_timer > 0.0:
		_act_card_timer = maxf(0.0, _act_card_timer - 0.4)
	voyage.tick_ui(0.5)               # 消息条同理：一帧当半秒
	_update_camera()          # 截图模式下 _process 提前返回了，这里要自己同步相机
	_update_hud()
	queue_redraw()
	match _frame:
		1:
			# M3：开场先摆房间界面（单机 / 开房间 / 加入），这里先截一张
			_room.open()
			_hud_layer.visible = false
			_panel_layer.visible = false
		2:
			_capture("42_room")
		3:
			_room.visible = false
			_show_overlay(_title, true)       # 然后才是开场：先给陌生人一页交代
		4:
			_capture("19_title_card")
		5:
			_show_overlay(_title, false)
			_started = true
		6:
			# M2 的头号画面证据：拉到最远 = 整张大西洋海图，没去过的区域全是雾
			_zoom = _min_zoom()
			_warp(2.0)                        # 让第一幕落下来（目标卡要有内容）
		8:
			_capture("38_chart_fog")
		10:
			_zoom = 0.8
			_time_scale_idx = 2
			voyage.orders.set_target_point(Vector2(41000, 10400))
			_warp(240.0)
		12:
			_capture("20_sea_overview")       # 出港：看得见伊比利亚那段海岸
		13:
			# M4：靠港看一眼港口面板（补给 / 修船 / 买卖都在这一屏）
			voyage.ship.set_pose(voyage.sea.port_pos(), 180.0)
			voyage.orders.anchored = true
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
			_warp(2.0)
			voyage.dock()
			_port_panel.row = 0
			_port_panel.visible = true
		14:
			_capture("43_port_panel")
		15:
			_port_panel.visible = false
			voyage.undock()
			voyage.orders.anchored = false
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
			voyage.orders.set_target_point(Vector2(41000, 10400))
			_warp(30.0)
		16:
			_capture("20b_act1_card")         # 第一幕落下来的剧情卡
		17:
			_capture("21_under_way")
		18:
			_show_panel = true                # 教学第 2 步：帆态面板
			_panel.visible = true
			voyage.story.note("open_sail_panel")
		19:
			# 面板要等 _update_hud 把 ship/crew 灌进去、再等一帧才会画出来
			# （AGENTS.md 的坑：改完状态隔一帧再截）
			_capture("21a_sail_panel")
		20:
			_show_panel = false
			_panel.visible = false
			# 跨 tile 缝：船从 tile 2,0 一路开进 tile 1,0（缝在 x=32000）
			# 就贴着伊比利亚的南岸走：缝两边都看得见同一段海岸，地形不许有断口
			_zoom = 0.6
			voyage.ship.set_pose(Vector2(33200, 8700), 200.0)
			voyage.orders.set_target_point(Vector2(29000, 9300))
			_warp(60.0)
		22:
			_capture("39_seam_before")        # 还在这边：缝就在船前面，海岸横在缝上
		24:
			_warp(700.0)                      # 真的开过缝，不是摆过去
		25:
			_capture("40_seam_after")         # 缝的另一侧：地形没有任何跳变
		26:
			_zoom = 4.0                       # 拉近看船：这里画的是真正的 SVG 船
			voyage.ship.set_pose(Vector2(30000, 16000), 200.0)
			_warp(30.0)
		27:
			_capture("23_ship_close_up")
		28:
			_zoom = SHIP_ZOOM                 # 一路滚到底：就是船内调试视图那个比例
			_warp(5.0)
		29:
			_capture("24_deck_in_detail")
		30:
			_mode = Mode.LAYER                # 再继续向下：沉进船舱
			_layer = 1
			_warp(5.0)
		31:
			_capture("25_below_deck")
		32:
			_mode = Mode.SEA
			_layer = 2
			_zoom = 1.0
		34:
			# 这条航线正好穿过加那利暗礁 —— 触礁（因果链的中间一环）
			voyage.ship.set_pose(Vector2(30200, 17500), 200.0)
			voyage.orders.set_target_point(Vector2(28500, 19000))
			_warp(400.0)
		38:
			_capture("26_reef_hit")
		42:
			# 靠到绿岬岛跟前：瞭望员报告陆地（第二幕）
			voyage.ship.set_pose(Vector2(25000, 25000), 200.0)
			voyage.orders.set_target_point(Vector2(21600, 26400))
			_warp(60.0)
		46:
			_zoom = 0.4                       # 连岛带船一起看：这就是"右前方有陆地"
			_capture("22_island_sighted")
		48:
			# 截图脚本：把船直接摆到滩头外（航行过程已经在前两格演示过了）
			voyage.ship.set_pose(Vector2(21490, 26500), 0.0)
			voyage.orders.anchored = true
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FURLED)
			_warp(120.0)
		50:
			_capture("27_anchored_off_beach")
		52:
			_zoom = 24.0                      # 锚泊时拉近：附近地形必须还在
			_warp(5.0)
		54:
			_capture("28_anchored_close_up")
		56:
			_zoom = 1.0
			# 登陆名单：这一版挂在 CanvasLayer 上（屏幕坐标），不再跟着相机跑
			_picker.open(voyage.roster)
			_picker.visible = true
			_picker.toggle_current()
			_picker.move(3)
			_picker.toggle_current()
		58:
			_capture("29_landing_picker")
		60:
			_picker.visible = false
			var ids := ["piloto", "carpintero", "cirujano", "escribano"]
			print("[shot] 登陆：%s" % voyage.land(ids, 6))
			_zoom = 1.0
			_warp(14.0)                       # 一个一个下船，这会儿有人还在船上
		62:
			_capture("30_disembarking_one_by_one")
		64:
			_zoom = 0.45                      # 上岸时相机会再放大一倍：这个倍率能看见整座岛
			_warp(60.0)                       # 都上岸了，站成队形
		66:
			_capture("31_ashore_in_formation")
		68:
			_zoom = 1.0
			voyage.move_party_to(Vector2(23500, 25700))     # 内陆遗迹
			_warp(240.0)
		72:
			_capture("32_ruins")
		76:
			voyage.move_party_to(Vector2(23900, 26800))     # 淡水溪流
			_warp(200.0)
		80:
			_capture("33_stream")
		84:
			voyage.move_party_to(Vector2(21800, 26500))     # 走回滩头
			_warp(260.0)
			_deliver_reports()
		88:
			_capture("34_back_with_reports")
		90:
			print("[shot] 报告：%s" % str(voyage.pending_reports))
			_zoom = _min_zoom()               # 拉到海图尺度：返航的航线一眼看完
			# 第三幕：起锚、满帆、真的往出发港开一段（不是摆回去）
			voyage.orders.anchored = false
			voyage.orders.set_sail_level(ShipOrders.SailLevel.FULL)
			voyage.orders.set_target_point(Vector2(44000, 12000))
			_warp(600.0)
		92:
			_zoom = _min_zoom()
			_capture("35_homeward")
		94:
			# 24km 的返航靠快进也要一个多小时真实时间，截图脚本直接摆到港外
			_zoom = 1.0
			voyage.ship.set_pose(Vector2(44700, 12000), 180.0)
			_warp(90.0)
		96:
			_capture("36_homeward_arrival")
		98:
			if not voyage.story.ending_ready:
				print("[shot] 还没进港（离港 %.0f 米），摆到港外把第三幕走完" % \
					voyage.ship.position_m().distance_to(Vector2(44000, 12000)))
				voyage.ship.set_pose(Vector2(44600, 12000), 180.0)
				_warp(60.0)
			print("[shot] 第三幕 = %s　结算就绪 = %s" % [
				voyage.story.act_name(), str(voyage.story.ending_ready)])
			_ending.text = voyage.journal.settlement(voyage, voyage.story)
			_show_overlay(_ending, true)
		100:
			_capture("37_settlement")
		102:
			# 收尾：把结算页收起来，拉回海图 —— 一路探明的分块与航段都留在这张图上
			_show_overlay(_ending, false)
			_zoom = _min_zoom()
			_warp(2.0)
		104:
			_capture("41_chart_explored")
		106:
			# M5：船员面板的右半边 —— 规矩、三伙人、以及"他为什么心情差"
			# （先把桌上已经摊着的抉择答掉，不然它会盖在面板上）
			while voyage.dilemmas.current() != "":
				var opts: Array = voyage.dilemmas.take_current().get("options", [])
				if opts.is_empty():
					break
				voyage.answer_dilemma(str((opts[0] as Dictionary).get("id", "")))
			_show_crew_panel = true
			_crew_panel.visible = true
			_crew_panel.focus = "rules"
			_crew_panel.selected_row = 3
			_warp(0.5)
		107:
			_capture("44_crew_and_rules")
		108:
			# M5：抉择卡（把"缺粮"这件事摆到桌上）
			_crew_panel.visible = false
			_show_crew_panel = false
			voyage.cargo.starving = true
			voyage.fired["village"] = true       # 走到过村落（截图脚本替玩家走了这一趟）
			voyage.dilemmas.check(voyage)
			_dilemma_card.refresh()
		109:
			_capture("45_dilemma")
		110:
			get_tree().quit(0)


func _deliver_reports() -> void:
	if not voyage.ashore:
		return
	var msg := voyage.return_to_ship()
	voyage.say("（船长）" + msg, true)
	_update_hud()


func _warp(seconds: float) -> void:
	var steps := int(seconds / SIM_DT)
	for _i in steps:
		voyage.tick(SIM_DT)
	_update_camera()
	_update_hud()
	queue_redraw()


func _capture(name: String) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[shot] 拿不到 viewport 纹理")
		return
	var img := tex.get_image()
	var err := img.save_png("%s/%s.png" % [_shot_dir, name])
	print("[shot] %-24s err=%d  zoom=%.4f fade=%.2f  第 %.0f 分钟  %s" % [
		name, err, _zoom, _chart.fade if _chart != null else -1.0,
		voyage.t / 60.0, voyage.describe()])
