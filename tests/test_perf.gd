extends SceneTree

# M8 的验收测试（中）：性能基准。
#
# 验收第 2 条是"帧率 ≥60（下限 30）"。真正决定帧率的是**逻辑步**的耗时：
# 渲染是引擎的事，而我们每帧最多跑 12 个逻辑步（×36 快进）。所以这里量的是
# `voyage.tick(SIM_DT)` 在**最重的那种局面**下的平均耗时：
#   4 条船 + 天气 + 40 人名册 + 一场 10 对 10 的陆战 + 事件池
#
# 判据（`docs/13` M8）：一个逻辑步 < 16.6 ms（60 帧）算舒服，< 33 ms（30 帧）算合格。

const GEO := "res://data/world/atlantic/geography.json"
const SIM_DT := 0.05
const STEP_BUDGET_60 := 16.6
const STEP_BUDGET_30 := 33.0

var _checks := 0
var _fails: PackedStringArray = []
var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("=== test_perf ===")
	_test_idle_ship()
	_test_full_load()
	_test_step_budget_for_timescale()
	_finish()


func _v() -> Voyage:
	var v := Voyage.new()
	v.setup(GEO)
	return v


func _measure(v: Voyage, steps: int) -> Dictionary:
	"""跑 steps 个逻辑步，返回平均/最坏耗时（毫秒）。"""
	# 先热身几步（第一帧要建缓存、分配对象）
	for _i in 10:
		v.tick(SIM_DT)
	var worst := 0.0
	var sum := 0.0
	var t_start := Time.get_ticks_usec()
	for _i in steps:
		var a := Time.get_ticks_usec()
		v.tick(SIM_DT)
		var us := Time.get_ticks_usec() - a
		worst = maxf(worst, float(us) / 1000.0)
		sum += float(us) / 1000.0
	var total := float(Time.get_ticks_usec() - t_start) / 1000.0
	return { "steps": steps, "avg_ms": sum / float(steps), "worst_ms": worst,
		"total_ms": total, "steps_per_s": float(steps) / maxf(total / 1000.0, 1e-6) }


func _test_idle_ship() -> void:
	var v := _v()
	v.orders.anchored = true
	var r := _measure(v, 400)
	print("  停船时：平均 %.3f ms/步，最坏 %.3f，%.0f 步/秒" % [
		float(r["avg_ms"]), float(r["worst_ms"]), float(r["steps_per_s"])])
	_check(float(r["avg_ms"]) < STEP_BUDGET_60 / 3.0,
		"停船时的逻辑步很快（平均 %.3f ms）" % float(r["avg_ms"]))


func _test_full_load() -> void:
	"""最重的局面：船在跑、满帆、有天气、船队四条、还打着仗。"""
	var v := _v()
	v.ship.set_pose(Vector2(30000, 22000), 200.0)
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(Vector2(22000, 26000))
	v.weather.force("storm", 999.0)
	v.society.tension = 0.6
	# 一场 10 对 10 的陆战：把队伍放上岸再开打
	v.ship.set_pose(v.sea.poi_pos("beach") + Vector2(-200.0, 0.0), 0.0)
	var ids := []
	for m in v.roster.key_crew():
		ids.append(m.id)
	v.fired.erase("landed")
	v.land(ids, 6)
	v.begin_land_battle(10, "rain")
	var r := _measure(v, 400)
	print("  最重的局面（4 船 + 风暴 + 40 人 + 10 对 10 陆战）：平均 %.3f ms/步，最坏 %.3f，%.0f 步/秒" % [
		float(r["avg_ms"]), float(r["worst_ms"]), float(r["steps_per_s"])])
	_check(float(r["avg_ms"]) < STEP_BUDGET_30,
		"最重局面的逻辑步在 30 帧预算内（平均 %.3f ms < %.1f）" % [
			float(r["avg_ms"]), STEP_BUDGET_30])
	var budget60 := float(r["avg_ms"]) < STEP_BUDGET_60
	print("  60 帧预算（每步 <%.1f ms）：%s" % [STEP_BUDGET_60, "够" if budget60 else "不够"])
	_check(float(r["steps_per_s"]) > 60.0,
		"逻辑步的吞吐 >60 步/秒（%.0f）" % float(r["steps_per_s"]))


func _test_step_budget_for_timescale() -> void:
	"""×36 快进时每帧要跑 12 个逻辑步 —— 那一帧的逻辑预算就是 12 × 平均耗时。"""
	var v := _v()
	v.orders.set_sail_level(ShipOrders.SailLevel.FULL)
	v.orders.set_target_point(Vector2(22000, 26000))
	var r := _measure(v, 400)
	var frame_ms := float(r["avg_ms"]) * 12.0
	print("  ×36 快进的一帧（12 个逻辑步）：约 %.1f ms" % frame_ms)
	_check(frame_ms < STEP_BUDGET_30,
		"×36 快进时一帧的逻辑预算仍在 30 帧线上（%.1f ms）" % frame_ms)


# ---------------------------------------------------------------- 断言框架

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] " + msg)
	else:
		_fails.append(msg)
		print("  [FAIL] " + msg)


func _finish() -> void:
	var ms := Time.get_ticks_msec() - _t0
	if _fails.is_empty():
		print("全部通过：%d 项断言，耗时 %.0f ms" % [_checks, ms])
		quit(0)
	else:
		print("失败 %d / %d 项：" % [_fails.size(), _checks])
		for f in _fails:
			print("  - " + f)
		quit(1)
