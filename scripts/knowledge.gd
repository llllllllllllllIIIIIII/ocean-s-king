class_name Knowledge
extends RefCounted

# 知识（M7）：**发现即记录**。
#
# 这一层很薄，但它把前面六期散落的东西收成了一本账：
#   海图（走过哪里）/ 陆地与港口 / 风向洋流 / 物种 / 文化 / 语言 / 贸易情报 / 战争情报。
#
# 它是 `WorldState` 的一部分（同一片海对所有人是同一片），所以进世界状态的存档。
#
# 一条规矩：**记的是 id，不是文本**。同一件事发现两次不会记两遍 ——
# 所以"跨洋航程结束后知识页被填满"这件事可以被断言（`count()`）。

const CATEGORIES := [
	{ "id": "chart", "name": "海图" },
	{ "id": "current", "name": "风向与洋流" },
	{ "id": "species", "name": "物种" },
	{ "id": "culture", "name": "文化" },
	{ "id": "language", "name": "语言" },
	{ "id": "trade", "name": "贸易情报" },
	{ "id": "war", "name": "战争情报" },
	# M14：坏血病（M13 的太平洋事件）与热病都用这一类 —— 加上它，知识页里才显示得出来
	{ "id": "medicine", "name": "医术与药" },
]

var entries: Array = []              # [{category, id, title, text, t}]
# M14：**卖出去过的**知识（"类别:id" -> true）。卖过一次就不能再卖第二遍 ——
# 不然同一条海图可以在同一个港反复换钱。它进存档（WorldState 那本账要守恒）。
var sold: Dictionary = {}


func key_of(category: String, id: String) -> String:
	return "%s:%s" % [category, id]


func is_sold(category: String, id: String) -> bool:
	return sold.has(key_of(category, id))


func mark_sold(category: String, id: String) -> void:
	sold[key_of(category, id)] = true


func category_name(id: String) -> String:
	for c in CATEGORIES:
		if str(c["id"]) == id:
			return str(c["name"])
	return id


func has(category: String, id: String) -> bool:
	for e in entries:
		if str(e["category"]) == category and str(e["id"]) == id:
			return true
	return false


func note(category: String, id: String, title: String, text := "", t := 0.0) -> bool:
	"""记一条发现。已经记过就什么都不做（返回 false）。"""
	if id == "" or has(category, id):
		return false
	entries.append({
		"category": category, "id": id, "title": title, "text": text, "t": t,
	})
	return true


func count() -> int:
	return entries.size()


func count_of(category: String) -> int:
	var n := 0
	for e in entries:
		if str(e["category"]) == category:
			n += 1
	return n


func by_category(category: String) -> Array:
	var out := []
	for e in entries:
		if str(e["category"]) == category:
			out.append(e)
	return out


func lines(limit := 24) -> Array:
	var out := []
	for c in CATEGORIES:
		var items := by_category(str(c["id"]))
		if items.is_empty():
			continue
		out.append("【%s】%d 条" % [str(c["name"]), items.size()])
		for e in items:
			out.append("　· %s" % str(e["title"]))
			if out.size() >= limit:
				return out
	return out


func describe() -> String:
	var parts := PackedStringArray()
	for c in CATEGORIES:
		var n := count_of(str(c["id"]))
		if n > 0:
			parts.append("%s %d" % [str(c["name"]), n])
	if parts.is_empty():
		return "还什么都没记下来"
	return "知识 %d 条（%s）" % [count(), "　".join(parts)]


# ------------------------------------------------------------ 存档（WorldState，docs/14 第 2 节）

func capture_state() -> Dictionary:
	return { "entries": entries.duplicate(true), "sold": sold.duplicate() }


func apply_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	entries = (d.get("entries", []) as Array).duplicate(true)
	sold = (d.get("sold", {}) as Dictionary).duplicate()
