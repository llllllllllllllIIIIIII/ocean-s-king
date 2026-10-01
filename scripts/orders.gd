class_name ShipOrders
extends RefCounted

# 玩家的指令层（docs/01 支柱 3 的那张表）。它只描述**想要什么**，
# 不描述"怎么操船" —— 怎么操船是航海官的事，怎么收放帆是船员的事。
#
#   设定目标点 / 帆档（全帆·缩帆·收帆）/ 抛锚·起锚 / 调人员
#
# 这张表就是玩家在整局游戏里能下的**全部**命令（docs/01 支柱 3）。
# 玩家永远不能直接下舵、不能直接调帆 —— 这是本作最重要的设计取舍：
# 船开得好不好 = 船员好不好。

enum SailLevel { FULL, REEF, FURLED }

var target_point := Vector2.ZERO
var has_target_point := false
var sail_level: SailLevel = SailLevel.FULL
var anchored := false
var hands_on_sails := 6          # 派去操帆的人手（Day 5 会接上真实编制）
var hands_total := 12            # 船上还能用的人手


func set_target_point(p: Vector2) -> void:
	target_point = p
	has_target_point = true


func clear_target_point() -> void:
	has_target_point = false


func set_sail_level(level: SailLevel) -> void:
	sail_level = level


func cycle_sail_level() -> void:
	sail_level = ((int(sail_level) + 1) % 3) as SailLevel


func sail_level_name() -> String:
	match sail_level:
		SailLevel.FULL: return "全帆"
		SailLevel.REEF: return "缩帆"
		SailLevel.FURLED: return "收帆"
	return "?"


func sail_area_scale() -> float:
	"""帆档 -> 有效帆面积的比例。缩帆不是"小一号的帆"，是真的少了一大块。"""
	match sail_level:
		SailLevel.FULL: return 1.0
		SailLevel.REEF: return 0.55
		SailLevel.FURLED: return 0.0
	return 1.0


func allow_sailing() -> bool:
	# 抛锚或收帆 = 船不该再被帆推着走
	return not anchored and sail_level != SailLevel.FURLED


func set_hands(n: int) -> void:
	hands_on_sails = clampi(n, 0, hands_total)


func describe() -> String:
	var tgt := "(%d, %d) m" % [int(target_point.x), int(target_point.y)] \
		if has_target_point else "（无）"
	return "目标点 %s　帆档 %s　%s　操帆 %d/%d 人" % [
		tgt, sail_level_name(), "抛锚中" if anchored else "航行中",
		hands_on_sails, hands_total]


func clone() -> ShipOrders:
	var o := ShipOrders.new()
	o.target_point = target_point
	o.has_target_point = has_target_point
	o.sail_level = sail_level
	o.anchored = anchored
	o.hands_on_sails = hands_on_sails
	o.hands_total = hands_total
	return o
