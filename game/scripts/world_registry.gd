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


# 置き場にある、遊べるマップの一覧。世界の名前 (world_id) と、原点と大きさがある世界だけ。ファイルの場所 (パス) の順。
# 同じ world_id の世界が 2 つあれば、パスの順で先のものだけを入れて、警告する
static func scan(directory: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var files := Array(DirAccess.get_files_at(directory))
	files.sort()
	var seen := {}
	for file: String in files:
		if file.get_extension() != "glb":
			continue
		var entry := entry_for("%s/%s" % [directory, file])
		if entry.is_empty():
			continue
		if seen.has(entry.world_id):
			push_warning("同じ世界の名前 (%s) が、2 つあります。後のものは使いません: %s" % [entry.world_id, entry.path])
			continue
		seen[entry.world_id] = true
		entries.append(entry)
	return entries


# 1 つの世界の情報。.json は 1 回だけ読む。使えない時 (.json がない、原点や大きさや名前が不正) は、空。
# size の高さ (size.y) は、いまは使わない (隣は、東西と南北だけで決める)
static func entry_for(path: String) -> Dictionary:
	var data := WorldLoader.read_sidecar(path)
	var world_id := WorldLoader.world_id_of(data)
	var origin: Variant = SaveGame.decode_vector(data.get("origin"))
	var size: Variant = SaveGame.decode_vector(data.get("size"))
	if world_id.is_empty() or origin == null or size == null or (size as Vector3).x <= 0.0 or (size as Vector3).z <= 0.0:
		return {}
	return {
		"path": path,
		"world_id": world_id,
		"name": WorldLoader.name_of(data),
		"origin": origin,
		"size": size,
		"region": WorldLoader.world_id_of({"world_id": data.get("region")}),  # 地域の名前 (同じ地域のマップは、まとめて読み込む)。なければ空
	}


# 隣のマップ。{"east": 情報, "west": ..., "north": ..., "south": ...} (いない方角は、入らない)。
# 同じ方角に候補が 2 つ以上ある時は、辺の重なりがいちばん大きいもの (同じなら、一覧の先のもの)。一覧の順では決まらない
static func neighbors(entries: Array[Dictionary], entry: Dictionary) -> Dictionary:
	var result := {}
	var overlaps := {}
	for other in entries:
		if other.world_id == entry.world_id:
			continue
		var found := _direction_to(entry, other)
		if found.is_empty():
			continue
		if not result.has(found.direction) or found.overlap > overlaps[found.direction]:
			result[found.direction] = other
			overlaps[found.direction] = found.overlap
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
	var best_distance := INF
	for direction: String in DIRECTIONS:  # 同じ距離なら、DIRECTIONS の先の方角 (east、west、north、south の順)
		if near.has(direction) and distances[direction] <= margin and distances[direction] < best_distance:
			best = direction
			best_distance = distances[direction]
	return best


# 隣のマップの端から inset だけ内側へ、position を寄せる (範囲の中へ)。出口で隣へ移った時、隙間 (EDGE_GAP まで) のせいで
# 範囲の外に出ないよう、convert_position のあとで使う
static func clamp_inside(entry: Dictionary, position: Vector3, inset: float) -> Vector3:
	var size: Vector3 = entry.size
	return Vector3(clampf(position.x, inset, size.x - inset), position.y, clampf(position.z, -size.z + inset, -inset))


# from の position (ゲームの座標) を、to のゲームの座標に直す。同じ測量座標の場所 (東西南北と標高が連続する)。
# 隙間 (EDGE_GAP まで) があるので、結果は、to の範囲の外 (x が負、など) になりうる。置く前に、clamp_inside で中へ寄せる
static func convert_position(from: Dictionary, to: Dictionary, position: Vector3) -> Vector3:
	var origin_from: Vector3 = from.origin
	var origin_to: Vector3 = to.origin
	var survey := Vector3(position.x + origin_from.x, -position.z + origin_from.y, position.y + origin_from.z)
	var moved := survey - origin_to
	return Vector3(moved.x, moved.z, -moved.y)


# from から見て、other がどの方角に、隣り合っているか。{"direction": 方角, "overlap": 辺の重なり (m)}。隣り合っていなければ、空
static func _direction_to(from: Dictionary, other: Dictionary) -> Dictionary:
	var a_origin: Vector3 = from.origin
	var a_size: Vector3 = from.size
	var b_origin: Vector3 = other.origin
	var b_size: Vector3 = other.size
	var east_overlap := _overlap(a_origin.x, a_origin.x + a_size.x, b_origin.x, b_origin.x + b_size.x)
	var north_overlap := _overlap(a_origin.y, a_origin.y + a_size.z, b_origin.y, b_origin.y + b_size.z)
	if north_overlap >= MIN_OVERLAP:
		if absf(b_origin.x - (a_origin.x + a_size.x)) <= EDGE_GAP:
			return {"direction": "east", "overlap": north_overlap}
		if absf((b_origin.x + b_size.x) - a_origin.x) <= EDGE_GAP:
			return {"direction": "west", "overlap": north_overlap}
	if east_overlap >= MIN_OVERLAP:
		if absf(b_origin.y - (a_origin.y + a_size.z)) <= EDGE_GAP:
			return {"direction": "north", "overlap": east_overlap}
		if absf((b_origin.y + b_size.z) - a_origin.y) <= EDGE_GAP:
			return {"direction": "south", "overlap": east_overlap}
	return {}


static func _overlap(a0: float, a1: float, b0: float, b1: float) -> float:
	return minf(a1, b1) - maxf(a0, b0)
