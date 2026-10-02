extends SceneTree

# 一次性探针（**不是常驻通道**）：模拟"客户端加入房间"那条路，把镜头停在
# 客户端该看到的样子，存一张 PNG 出来看。
#   & $g --path . --script res://tests/_probe_client_view.gd
#
# 目的：房主那台是"单机出海"的正常路径，客户端走的是 `_on_welcome()` ——
# 那条路以前少两步（打开 HUD/面板层、重排"别人的船"渲染器），
# 所以客户端"没 UI、看不见房主"。这个探针就是盯它的。

const GEO := "res://data/world/atlantic/geography.json"
const OUT := "user://client_view.png"

var _scene
var _frame := 0


func _initialize() -> void:
	_scene = load("res://scenes/sea_debug.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 3:
		# 造一份"房主会发过来的东西"（用的就是房主那几条公开入口）
		var host := Voyage.new()
		host.setup(GEO)
		host.orders.set_target_point(Vector2(36000, 20000))
		for _i in 600:
			host.tick(0.5)
		var world := NetProtocol.world_projection(host)
		world["region"] = host.region_path
		world["fleet"] = host.fleet.remote_summaries()
		# 房主把这条船分给我（**不是**本机默认的特立尼达 —— 正是要验这个）
		var id := "san_antonio"
		_scene._on_welcome(id, host.fleet.summary_of(id), world)
	if _frame >= 20:
		var tex: ViewportTexture = _scene.get_viewport().get_texture()
		var img: Image = tex.get_image()
		img.save_png(ProjectSettings.globalize_path(OUT))
		print("[probe] 存到 ", ProjectSettings.globalize_path(OUT),
			"　HUD=", _scene._hud_layer.visible,
			"　面板层=", _scene._panel_layer.visible,
			"　我开=", _scene.voyage.fleet.local_id,
			"　别人的船渲染器=", _scene._fleet_views.keys())
		quit(0)
	return false
