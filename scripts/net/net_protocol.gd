class_name NetProtocol
extends RefCounted

# 上网络的消息清单（docs/14 第 5 节）。**这里是唯一的真源**：
# 谁想加一条消息，就在这儿加一个常量，别的文件只许引用名字。
#
# 里面**没有**的东西同样重要：
#   · 40 个人的逐人状态、帆的实时攻角、舵的积分项 —— 永不过网（docs/14 第 1 节）
#   · 相机、消息条、面板开关 —— 界面状态是每个人自己的

const VERSION := 1

# --- 连接 ---
const HELLO := "hello"        # 客户端 → 房主：我是谁、协议版本
const WELCOME := "welcome"    # 房主 → 客户端：你开哪条船 + 世界的当前快照
const BYE := "bye"            # 谁 → 房主：我走了（房主把船转 AI）
const FULL := "full"          # 房主 → 客户端：船位满了（v0.5 最多 4 个人）

# --- 每帧 ---
const SHIP := "ship"          # 拥有者 → 房主 → 其他人：20Hz 的 ShipState 摘要
const WORLD := "world"        # 房主 → 全部：世界状态（时钟/风/剧情/日志/已发现的图）
const INPUT := "input"        # 客户端 → 房主：一件会影响"世界"的事（比如记一条决定）

# --- 心跳 ---
const PING := "ping"
const PONG := "pong"


static func ship_summary(d: Dictionary) -> Dictionary:
	"""把一条船压成上网的那一份。**只留摘要，逐人细节一个字节都不带。**

	（它同时是"别人只能看外观与汇总数值"这条规矩的实现点 —— 想给别人的船
	多发一点东西的人，会先撞到这张白名单上。）
	"""
	return {
		"id": str(d.get("id", "")),
		"name": str(d.get("name", "")),
		"pos": d.get("pos", [0.0, 0.0]),
		"heading": float(d.get("heading", 0.0)),
		"sail_level": int(d.get("sail_level", 0)),
		"anchored": bool(d.get("anchored", false)),
		"hull_pct": float(d.get("hull_pct", 1.0)),
		"crew_count": int(d.get("crew_count", 0)),
		"action": str(d.get("action", "")),
		# M4：货舱里装了多少、手上有多少钱（别人的船看得到的就这两样）
		"hold_kg": float(d.get("hold_kg", 0.0)),
		"money": int(d.get("money", 0)),
	}


static func world_projection(v: Voyage) -> Dictionary:
	"""房主广播的世界：**只广播会变的值**，而且只广播别人真的需要的那几块。

	风广播的是"风场基准 + 当前值"：客户端拿它把风速风向对齐，然后自己按同一套
	确定性公式往下走 —— 0.5 秒一包的间隔里，两边不会吹出两种风。
	"""
	return {
		"t": v.t,
		"wind": v.wind.capture_state(),
		"fired": v.fired.duplicate(),
		"island_known": v.island_known,
		"visited": v.visited.duplicate(),
		"discovered": v.discovered.duplicate(),
		"known_places": v.known_places.duplicate(),
		"reef_hit": v.reef_hit,
		"story": v.story.capture_state(),
		"journal": v.journal.capture_state(),
		# M11：势力态度与王室命令、葡萄牙追捕的环、别的船 —— 都是"世界对我们做了什么"，
		# 只由房主推进（docs/22 第 4.2 节），客户端只读覆盖。
		"factions": v.factions.capture_state(),
		"pursuit": v.pursuit.capture_state(),
		"npcs": v.npcs.capture_state(),
	}


static func apply_world_projection(v: Voyage, d: Dictionary) -> void:
	"""客户端：把房主的世界覆盖过来（**只读覆盖**，客户端自己不许写这几块）。"""
	if d.is_empty():
		return
	v.t = float(d.get("t", v.t))
	v.day = VoyageJournal.day_index(v.t)
	v.wind.apply_state(d.get("wind", {}))
	v.fired = (d.get("fired", {}) as Dictionary).duplicate()
	v.island_known = bool(d.get("island_known", false))
	v.visited = (d.get("visited", {}) as Dictionary).duplicate()
	v.discovered = (d.get("discovered", {}) as Dictionary).duplicate()
	v.known_places = (d.get("known_places", {}) as Dictionary).duplicate()
	v.reef_hit = bool(d.get("reef_hit", false))
	v.story.apply_state(d.get("story", {}))
	v.journal.apply_state(d.get("journal", {}))
	v.factions.apply_state(d.get("factions", {}))
	v.pursuit.apply_state(d.get("pursuit", {}))
	v.npcs.apply_state(d.get("npcs", {}))
	for raw in d.get("fleet", []):
		v.fleet.receive_summary(raw)
