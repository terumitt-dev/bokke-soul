class_name WorldRegistry
extends RefCounted
# 遊べるマップ (世界) の一覧。1 つの置き場 (フォルダ) にある、世界のデータ (.glb) と、隣の .json から作る。
# 隣り合うマップは、測量座標の原点と大きさから、自動で見つける (隣の一覧を、手で持たない)。
#
# マップの範囲は、測量座標で、東が [origin.東, origin.東 + size.幅]、北が [origin.北, origin.北 + size.奥行き]。
# (GLB の幅 = 東西、奥行き = 南北。ゲームの座標は、x が東、z が南: 北の端が z = -奥行き、南の端が z = 0)

const DIRECTIONS := ["east", "west", "north", "south"]
const EDGE_GAP := 3.0  # 隣のマップとの隙間として許す距離 (m)。標高グリッドを間引くと、端が 1 m ほど欠ける
const MIN_OVERLAP := 10.0  # 隣と見なすのに必要な、辺の重なり (m)


# 置き場にある、遊べるマップの一覧。世界の名前 (world_id) と、原点と大きさがある世界だけ。名前の順
static func scan(directory: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for file in DirAccess.get_files_at(directory):
		if file.get_extension() != "glb":
			continue
		var entry := entry_for("%s/%s" % [directory, file])
		if not entry.is_empty():
			entries.append(entry)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.path < b.path)
	return entries


# 1 つの世界の情報。使えない時 (.json がない、原点や大きさや名前が不正) は、空
static func entry_for(path: String) -> Dictionary:
	var world_id := WorldLoader.world_id_for(path)
	var origin: Variant = WorldLoader.origin_for(path)
	var size: Variant = _size_for(path)
	if world_id.is_empty() or origin == null or size == null:
		return {}
	return {
		"path": path,
		"world_id": world_id,
		"name": WorldLoader.name_for(path),
		"origin": origin,
		"size": size,
	}


# 隣のマップ。{"east": 情報, "west": ..., "north": ..., "south": ...} (いない方角は、入らない)
static func neighbors(entries: Array[Dictionary], entry: Dictionary) -> Dictionary:
	var result := {}
	for other in entries:
		if other.world_id == entry.world_id:
			continue
		var direction := _direction_to(entry, other)
		if not direction.is_empty() and not result.has(direction):
			result[direction] = other
	return result


# position (from の、ゲームの座標) が、端から margin 以内で、その方角に隣があれば、その方角を返す。なければ空。
# ゲームの座標は、x が東 (0〜幅)、z が南 (0 が南の端、-奥行き が北の端)。複数の端に近い時は、いちばん近い端
static func edge_toward(from: Dictionary, position: Vector3, margin: float, near: Dictionary) -> String:
	var size: Vector3 = from.size
	var distances := {
		"east": size.x - position.x,
		"west": position.x,
		"north": size.z + position.z,
		"south": -position.z,
	}
	var best := ""
	var best_distance := margin
	for direction: String in DIRECTIONS:
		if near.has(direction) and distances[direction] <= best_distance:
			best = direction
			best_distance = distances[direction]
	return best


# from の position (ゲームの座標) を、to のゲームの座標に直す。同じ測量座標の場所 (東西南北と標高が連続する)
static func convert_position(from: Dictionary, to: Dictionary, position: Vector3) -> Vector3:
	var origin_from: Vector3 = from.origin
	var origin_to: Vector3 = to.origin
	var survey := Vector3(position.x + origin_from.x, -position.z + origin_from.y, position.y + origin_from.z)
	var moved := survey - origin_to
	return Vector3(moved.x, moved.z, -moved.y)


# .json の size (GLB の幅・高さ・奥行き)。不正なら null
static func _size_for(path: String) -> Variant:
	var size: Variant = SaveGame.decode_vector(WorldLoader.read_sidecar(path).get("size"))
	if size == null or (size as Vector3).x <= 0.0 or (size as Vector3).z <= 0.0:
		return null
	return size


# from から見て、other がどの方角に、隣り合っているか。隣り合っていなければ、空
static func _direction_to(from: Dictionary, other: Dictionary) -> String:
	var a_origin: Vector3 = from.origin
	var a_size: Vector3 = from.size
	var b_origin: Vector3 = other.origin
	var b_size: Vector3 = other.size
	var east_overlap := _overlap(a_origin.x, a_origin.x + a_size.x, b_origin.x, b_origin.x + b_size.x)
	var north_overlap := _overlap(a_origin.y, a_origin.y + a_size.z, b_origin.y, b_origin.y + b_size.z)
	if north_overlap >= MIN_OVERLAP:
		if absf(b_origin.x - (a_origin.x + a_size.x)) <= EDGE_GAP:
			return "east"
		if absf((b_origin.x + b_size.x) - a_origin.x) <= EDGE_GAP:
			return "west"
	if east_overlap >= MIN_OVERLAP:
		if absf(b_origin.y - (a_origin.y + a_size.z)) <= EDGE_GAP:
			return "north"
		if absf((b_origin.y + b_size.z) - a_origin.y) <= EDGE_GAP:
			return "south"
	return ""


static func _overlap(a0: float, a1: float, b0: float, b1: float) -> float:
	return minf(a1, b1) - maxf(a0, b0)
