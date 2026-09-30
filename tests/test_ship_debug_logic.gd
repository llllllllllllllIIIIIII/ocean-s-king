# 无头驱动游戏逻辑：不需要截图，直接给场景喂输入事件，再断言状态。
#
# 这条通道证明两件事：
#   1. 场景逻辑可以完全脱离渲染来验证（快、稳、能进 CI）
#   2. 我可以**程序化模拟输入**去驱动游戏，而不只是截图围观
#
# 用法：
#   Godot_..._console.exe --headless --path . --script res://tests/test_ship_debug_logic.gd
#
# 退出码 0 = 全部通过；1 = 有断言失败。
extends SceneTree

const SCENE := "res://scenes/ship_debug.tscn"

var _errors: PackedStringArray = []
var _checks := 0
var _trace: Array = []
var _scene
var _frame := 0


func _initialize() -> void:
	print("=== test_ship_debug_logic ===")
	_scene = load(SCENE).instantiate()
	root.add_child(_scene)
	# 注意：不能在这里直接断言。节点刚 add_child 时 _ready() 还没跑，
	# 场景内部状态（_layers 等）都是空的。必须等引擎推过一帧再测。


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false
	_run_assertions()
	return true


func _run_assertions() -> void:
	var scene = _scene
	var state := _snapshot(scene)
	_record("初始", state)

	_check(state["mode"] == "ZOOM", "初始应为缩放模式，实际 %s" % state["mode"])
	_check(state["layer"] == 2, "初始应停在主甲板 L2，实际 L%d" % state["layer"])

	# --- 在甲板上滚轮向下：先只是拉近 ---
	_wheel(scene, MOUSE_BUTTON_WHEEL_DOWN, 3)
	state = _snapshot(scene)
	_record("甲板拉近 x3", state)
	_check(state["mode"] == "ZOOM", "只拉近时不应进入分层模式")
	_check(state["zoom"] > 0.55, "拉近后 zoom 应变大，实际 %.2f" % state["zoom"])

	# --- 继续向下滚，数一数拉到最近后第几下会沉入船舱 ---
	var extra := 0
	while scene._mode == 0 and extra < 30:
		_wheel(scene, MOUSE_BUTTON_WHEEL_DOWN, 1)
		extra += 1
	state = _snapshot(scene)
	_record("再滚 %d 下 -> 沉入" % extra, state)
	_check(state["mode"] == "LAYER", "继续向下应进入分层模式，实际 %s" % state["mode"])
	_check(state["layer"] == 1, "应沉到下层甲板 L1，实际 L%d" % state["layer"])

	# --- 向下沉一层，再向下应停在货舱 ---
	_wheel(scene, MOUSE_BUTTON_WHEEL_DOWN, 1)
	state = _snapshot(scene)
	_record("再向下", state)
	_check(state["layer"] == 0, "继续向下应到货舱 L0，实际 L%d" % state["layer"])

	_wheel(scene, MOUSE_BUTTON_WHEEL_DOWN, 5)
	state = _snapshot(scene)
	_record("到底后再向下", state)
	_check(state["layer"] == 0, "在货舱继续向下应停在 L0，实际 L%d" % state["layer"])

	# --- 向上：先逐层上浮，到最上层后回到缩放模式 ---
	_wheel(scene, MOUSE_BUTTON_WHEEL_UP, 1)
	state = _snapshot(scene)
	_record("向上 x1", state)
	_check(state["layer"] == 1, "向上应回到 L1，实际 L%d" % state["layer"])

	_wheel(scene, MOUSE_BUTTON_WHEEL_UP, 4)
	state = _snapshot(scene)
	_record("回到甲板", state)
	_check(state["mode"] == "ZOOM", "在最上层继续向上应回到缩放模式，实际 %s" % state["mode"])
	_check(state["layer"] == 2, "回到甲板应为 L2，实际 L%d" % state["layer"])

	# --- 相机必须始终对准船中心 ---
	var ship: Dictionary = scene.get("_ship")
	var expect_center := Vector2(
		float(ship["hull"]["cells_x"]) * 40.0 * 0.5,
		float(ship["hull"]["cells_y"]) * 40.0 * 0.5)
	var cam_pos: Vector2 = scene.get_node("Camera2D").position
	_check(cam_pos.is_equal_approx(expect_center),
		"相机未对准船中心：实际 %s，应为 %s" % [str(cam_pos), str(expect_center)])

	print("--- 状态轨迹 ---")
	for row in _trace:
		print("  %-16s %s" % [row["step"], JSON.stringify(row["state"])])

	scene.queue_free()
	_finish()


# ------------------------------------------------------------------ 工具

func _wheel(scene, button: int, times: int) -> void:
	# 直接构造真实输入事件喂给场景，走完整的 _unhandled_input 路径，
	# 而不是绕过输入系统去改内部变量。
	for i in times:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = true
		scene._unhandled_input(ev)


func _snapshot(scene) -> Dictionary:
	var layer_def: Dictionary = scene._layers[scene._layer]
	return {
		"mode": "LAYER" if scene._mode == 1 else "ZOOM",
		"layer": scene._layer,
		"layer_name": layer_def["name"],
		"zoom": snappedf(scene._zoom, 0.001),
	}


func _record(step: String, state: Dictionary) -> void:
	_trace.append({"step": step, "state": state})


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_errors.append(msg)


func _finish() -> void:
	if _errors.is_empty():
		print("=== OK：%d 项断言全部通过 ===" % _checks)
		quit(0)
	else:
		print("=== 失败：%d 项断言中 %d 个不通过 ===" % [_checks, _errors.size()])
		for e in _errors:
			print("  x  " + e)
		quit(1)
