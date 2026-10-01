class_name StateIO
extends RefCounted

# 存档与（将来的）网络共用的小工具：把值变成能进 JSON 的东西，以及字段名自省。
#
# 它不持有任何状态，只做两件事：
#   1. Godot 的 Vector2 / Vector3i 不能直接进 JSON（会被写成 "(1, 2)" 这种字符串），
#      统一转成数组；
#   2. `script_vars()` 取一个对象的**脚本变量名**，给 tests/test_save.gd 做
#      "有没有字段忘了存"的覆盖断言用（docs/14 第 7 节）。


static func v2(v) -> Array:
	# 容忍"已经是数组"的输入：同一份状态被 apply 两次时不会炸。
	if typeof(v) == TYPE_ARRAY:
		return [float(v[0]), float(v[1])]
	return [v.x, v.y]


static func to_v2(a) -> Vector2:
	if typeof(a) != TYPE_ARRAY or a.size() < 2:
		return Vector2.ZERO
	return Vector2(float(a[0]), float(a[1]))


static func v2_list(arr: Array) -> Array:
	"""一串 Vector2 → 一串 [x, y]。落盘一律走这里。"""
	var out := []
	for p in arr:
		if typeof(p) == TYPE_VECTOR2 or typeof(p) == TYPE_ARRAY:
			out.append(v2(p))
	return out


static func to_v2_list(raw) -> Array:
	"""读档：三种形态都要认 ——
	① `Vector2`（内存里）；② `[x, y]`（**现存档的写法**）；
	③ `"(x, y)"`（早期把 Vector2 直接 stringify 出来的，得救回来 —— 见 docs/14 第 7 节）。"""
	var out := []
	if typeof(raw) == TYPE_PACKED_VECTOR2_ARRAY:
		for p in (raw as PackedVector2Array):
			out.append(p)
		return out
	if typeof(raw) != TYPE_ARRAY:
		return out
	for p in raw:
		if typeof(p) == TYPE_VECTOR2:
			out.append(p)
		elif typeof(p) == TYPE_ARRAY:
			out.append(to_v2(p))
		elif typeof(p) == TYPE_STRING:
			var bits := str(p).strip_edges().trim_prefix("(").trim_suffix(")").split(",")
			if bits.size() >= 2:
				out.append(Vector2(String(bits[0]).strip_edges().to_float(),
					String(bits[1]).strip_edges().to_float()))
	return out


static func v3i(v) -> Array:
	if typeof(v) == TYPE_ARRAY:
		return [int(v[0]), int(v[1]), int(v[2])]
	return [v.x, v.y, v.z]


static func to_v3i(a) -> Vector3i:
	if typeof(a) != TYPE_ARRAY or a.size() < 3:
		return Vector3i.ZERO
	return Vector3i(int(a[0]), int(a[1]), int(a[2]))


static func path3(arr: Array) -> Array:
	var out := []
	for p in arr:
		out.append(v3i(p))
	return out


static func to_path3(a) -> Array:
	var out := []
	if typeof(a) != TYPE_ARRAY:
		return out
	for p in a:
		out.append(to_v3i(p))
	return out


static func script_vars(obj) -> PackedStringArray:
	"""只取脚本自己声明的变量（不含 Object 内置属性、不含方法）。"""
	var out := PackedStringArray()
	if obj == null:
		return out
	for p in obj.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out.append(String(p["name"]))
	return out
