class_name SaveGame
extends RefCounted

# 存档（docs/14 第 4 节）。
#
# 三条规矩：
#   1. 版本不符**直接拒绝**，不改内存、不写迁移代码（v0.5 内不承诺向后兼容）；
#   2. 只存"会变的值" —— 海域 / 剧本 / 物理参数的静态数据读档时由 setup() 重新加载；
#   3. 失败要能被用户看见 —— 所有接口都返回 {ok, reason}，不许静默失败。
#
# 浮点精度：Godot 的 JSON 存 double 会掉到 15 位有效数字（实测，见 docs/14 §4.3），
# 所以读档后**离散状态要求精确相等、连续状态允许极小误差**。

const SAVE_VERSION := 1
const DIR := "user://saves"


static func slot_path(slot: String) -> String:
	return "%s/%s.json" % [DIR, slot]


static func ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)


static func save_game(v: Voyage, slot := "auto") -> Dictionary:
	# 陆战打到一半不许存：战斗本身（`LandBattle`）不在存档契约里，存下去会把这一仗
	# **静默丢掉**（读档回来人还在岸上，但没有这场遭遇）。规矩是"失败要让人看见"，
	# 所以这里明说，不许静默。（M8 收尾做阶段扫描时发现：四个阶段里只有战斗中会丢东西。）
	if v.battle != null and not v.battle.over:
		return {"ok": false, "reason": "打起来了 —— 这一场还没打完，打完再存（存档不保存进行中的陆战）"}
	ensure_dir()
	var path := slot_path(slot)
	var payload := {
		"version": SAVE_VERSION,
		"saved_at": Time.get_datetime_string_from_system(false, true),
		"slot": slot,
		"world": v.capture_world_state(),
		# ships[]：本机那条是 detailed，其余是 abstract（docs/14 第 4.1 节）
		"ships": v.capture_fleet(),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "reason": "写不进存档文件（%s，错误码 %d）" % [
			path, FileAccess.get_open_error()]}
	f.store_string(JSON.stringify(payload, "  ", false))
	f.close()
	return {"ok": true, "path": path, "slot": slot, "bytes": _file_size(path)}


static func has_slot(slot: String) -> bool:
	return FileAccess.file_exists(slot_path(slot))


static func load_into(v: Voyage, slot := "auto") -> Dictionary:
	"""把存档读进一个**已经 setup() 过**的 Voyage。

	必须先 setup()：静态数据（海域、剧本、船体、配平表）都来自仓库里的 JSON，
	存档里没有这些；setup() 之后用存档覆盖"会变的值"。
	"""
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {"ok": false, "reason": "找不到存档（%s）" % slot}
	# 用 JSON 实例而不是 JSON.parse_string：后者在解析失败时会往引擎日志里
	# 推一条 ERROR，而"存档被改坏了"是我们预期内的一种失败，不该看起来像崩溃。
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK:
		return {"ok": false, "reason": "存档不是合法的 JSON（第 %d 行：%s）" % [
			parser.get_error_line(), parser.get_error_message()]}
	var d = parser.data
	if typeof(d) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "存档的顶层不是一个对象（%s）" % path}
	var ver := int(d.get("version", -1))
	if ver != SAVE_VERSION:
		return {"ok": false, "reason": "这个存档是 v%d，当前版本只认 v%d" % [ver, SAVE_VERSION]}
	var ships: Array = d.get("ships", [])
	if ships.is_empty():
		return {"ok": false, "reason": "存档里没有任何船（%s）" % path}
	v.apply_world_state(d.get("world", {}))
	v.apply_fleet(ships)
	return {"ok": true, "path": path, "slot": slot}


static func list_slots() -> Array:
	ensure_dir()
	var out := []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".json"):
			out.append(name.trim_suffix(".json"))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)
