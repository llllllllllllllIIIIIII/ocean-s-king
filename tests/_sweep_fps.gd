extends SceneTree

# 一次性扫描（**不是常驻通道**）：**真的开一个窗口**量帧率。
#
# 为什么只能这么量：`--headless` 根本不渲染（`docs/06` 第 3 节记过这个坑），
# 所以 `test_perf` 量的是**逻辑步耗时**，回答不了验收第 2 条那句"帧率 ≥60"。
# 这里补另一半：真窗口、真渲染、真 40 人 + 4 条船 + 天气 + 沿航线走 + ×36。
#
# 两个数都要看：`Engine.get_frames_per_second()` 是引擎自己报的（平滑过），
# 自己数的那个是"我这几帧 / 真实毫秒"——**两个对不上就说明有别的东西在骗人**。
#
# 用法（**不要加 --headless**）：
#   & $g --path . --script res://tests/_sweep_fps.gd

const SCENE := "res://scenes/sea_debug.tscn"
const WARMUP := 2.0            # 前两秒不计（着色器编译、字体与 SVG 栅格化）
const MEASURE := 8.0           # 每一段量 8 秒

var _scene
var _t := 0.0
var _t0_ms := 0
var _measure_start_ms := 0
var _measure_frames := 0
var _fps := PackedFloat32Array()
var _proc := PackedFloat32Array()
var _phase := 0                # 0 = 海面视角（默认）／1 = 拉到最近（甲板 + 40 个圆点）
var _results: Array = []


func _initialize() -> void:
	_t0_ms = Time.get_ticks_msec()
	_scene = load(SCENE).instantiate()
	root.add_child(_scene)
	print("=== 真窗口帧率扫描（单机四条船 + 沿航线走 + ×36）===")


func _process(delta: float) -> bool:
	_t += delta
	# 开局：按 1 单机出海、按一下键收掉标题卡
	if _t < 0.2:
		_key(KEY_1)
		_key(KEY_F1)
	# 真正玩起来的样子：沿航线走 + 时间按到 ×36（四条船都在动，最重的正常状态）
	if _t > 0.5 and not _scene.voyage.following_route:
		_key(KEY_N)
		_key(KEY_PERIOD)
		_key(KEY_PERIOD)
		_key(KEY_PERIOD)
	if _t >= WARMUP and _t < WARMUP + MEASURE:
		if _measure_start_ms == 0:
			_measure_start_ms = Time.get_ticks_msec()
		_measure_frames += 1
		_fps.append(Engine.get_frames_per_second())
		_proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	if _t >= WARMUP + MEASURE:
		_results.append(_summary())
		if _phase == 0:
			_phase = 1
			_t = 0.0
			_measure_start_ms = 0
			_measure_frames = 0
			_fps = PackedFloat32Array()
			_proc = PackedFloat32Array()
			# 第二段：滚轮一路拉近到甲板（SVG 部件 + 40 个人，画面最重的那一档）
			for _i in 14:
				_wheel(-1)
			return false
		_report()
		quit(0)
	return false


func _key(code: int) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	_scene._unhandled_input(e)


func _wheel(dir: int) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_WHEEL_UP if dir < 0 else MOUSE_BUTTON_WHEEL_DOWN
	e.pressed = true
	e.position = Vector2(800, 450)
	_scene._unhandled_input(e)


func _summary() -> Dictionary:
	var lo := 9999.0
	var sum := 0.0
	var psum := 0.0
	for v in _fps:
		lo = minf(lo, float(v))
		sum += float(v)
	for v in _proc:
		psum += float(v)
	var wall := float(Time.get_ticks_msec() - _measure_start_ms) / 1000.0
	var mine := float(_measure_frames) / maxf(0.001, wall)
	return {
		"frames": _measure_frames, "wall": wall, "mine": mine,
		"engine_avg": sum / maxf(1.0, float(_fps.size())), "engine_lo": lo,
		"proc_ms": psum / maxf(1.0, float(_proc.size())),
	}


func _report() -> void:
	var names := ["① 海面视角（×36 沿航线走）", "② 拉到最近（甲板 + 40 人）"]
	var worst := INF
	for i in _results.size():
		var r: Dictionary = _results[i]
		print("%s：自己数 %.0f fps（引擎报 %.0f，最低 %.0f）　TIME_PROCESS 平均 %.2f ms　采样 %d 帧 / %.1f 秒" % [
			names[i] if i < names.size() else "?", float(r["mine"]),
			float(r["engine_avg"]), float(r["engine_lo"]), float(r["proc_ms"]),
			int(r["frames"]), float(r["wall"])])
		worst = minf(worst, float(r["mine"]))
	print("  整轮真实耗时 %.1f 秒　收尾：第 %.1f 个游戏小时 · 船队 %d 条 · 在船 %d 人" % [
		float(Time.get_ticks_msec() - _t0_ms) / 1000.0, _scene.voyage.t / 3600.0,
		_scene.voyage.fleet.count(), _scene.voyage.crew_on_board()])
	if worst >= 60.0:
		print("→ 验收第 2 条（≥60，下限 30）在这台机器上、**两种视角下都成立**")
	elif worst >= 30.0:
		print("→ 最重的那一档在 30–60 fps：下限够、60 不够")
	else:
		print("→ 最重的那一档掉到 30 以下 —— 这一条要修")
