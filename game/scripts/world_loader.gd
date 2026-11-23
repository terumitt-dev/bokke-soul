class_name WorldLoader
extends RefCounted
# 点群や標高グリッドから作った世界 (GLB) を、実行時に読み込む。
# データはリポジトリに入れないので、取り込みは通さず、起動時に場所を渡す:
#   godot --path game -- --world=/path/to/world.glb
# 何も指定しなければ、リポジトリに入っている人工のサンプルを使う

const ARG_PREFIX := "--world="
const SAMPLE_PATH := "res://assets/sample_world.glb"
# いまは色のないデータだけを扱うので、くすんだ砂の色を付ける (色つきの点群を扱う時に見直す)
const TERRAIN_COLOR := Color(0.40, 0.38, 0.35)


# タイトル画面で選んだ世界の場所。ゲーム本体へ引き継ぐ (起動時の引数がない時に使う)
static var selected_path := ""
# 世界の名前に使える文字 (セーブのファイル名になる。先頭に . は使えない)。tools/pointcloud_to_mesh.py と同じ決まり
static var WORLD_ID_PATTERN := RegEx.create_from_string("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}\\z")


# 読み込む世界の場所。explicit、起動時の引数、タイトル画面で選んだもの、サンプル、の順に探す
static func resolve_path(explicit: String = "") -> String:
	if not explicit.is_empty():
		return explicit
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_PREFIX):
			return arg.trim_prefix(ARG_PREFIX)
	if not selected_path.is_empty():
		return selected_path
	return SAMPLE_PATH


# 世界を読み込む。成功すれば {"node": Node3D, "error": ""}、失敗すれば {"node": null, "error": 理由}。
# node はまだ木に入っていない。メッシュには MeshInstance3D と、砂の色の素材を付けてある
static func load_world(path: String) -> Dictionary:
	var state := GLTFState.new()
	var error := GLTFDocument.new().append_from_file(path, state)
	if error != OK:
		return {"node": null, "error": "読み込めませんでした: %s (エラー %d)" % [path, error]}
	var world := GLTFDocument.new().generate_scene(state)
	if world == null:
		return {"node": null, "error": "シーンを作れませんでした: " + path}

	_convert_importer_meshes(world)
	_ensure_normals(world)
	var material := StandardMaterial3D.new()
	material.albedo_color = TERRAIN_COLOR
	material.roughness = 1.0
	for mesh: MeshInstance3D in world.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = material
	return {"node": world, "error": ""}


# 世界のデータの隣にある .json (変換ツールが書く) を読む。なければ、壊れていれば、辞書でなければ、空の辞書。
# JSON.parse_string は壊れた入力でエラーを出すので、結果だけを受け取る。.json がなくても、ゲームは動く
static func read_sidecar(path: String) -> Dictionary:
	var sidecar := path.get_basename() + ".json"
	if not FileAccess.file_exists(sidecar):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(sidecar)) != OK or not (json.data is Dictionary):
		return {}
	return json.data


# .json から、出典を読む。{"credit": 出典の文, "license_url": ライセンスの URL}。なければ空の文字列
static func credit_for(path: String) -> Dictionary:
	var result := {"credit": "", "license_url": ""}
	var data := read_sidecar(path)
	for key: String in result:
		if data.get(key) is String:
			result[key] = data[key]
	return result


# 世界の測量座標での原点 (.json の origin)。ない、または不正な時は null
static func origin_for(path: String) -> Variant:
	return SaveGame.decode_vector(read_sidecar(path).get("origin"))


# マップの名前 (.json の name。例: 寒天林道)。ない、文字でない、空白だけの時は空
static func name_for(path: String) -> String:
	var value: Variant = read_sidecar(path).get("name")
	return (value as String).strip_edges() if value is String else ""


# 篝火を置く場所を、ゲームの座標 (x, 高さ, z) で返す。.json の bonfire (測量座標 [東, 北, 標高]) を、
# origin を引いて、軸を直す。測量座標で持っているので、世界を作り直して原点が動いても、同じ場所を指す。
# bonfire か origin がない、または、不正なら null
static func bonfire_for(path: String) -> Variant:
	var data := read_sidecar(path)
	var survey: Variant = SaveGame.decode_vector(data.get("bonfire"))
	var origin: Variant = SaveGame.decode_vector(data.get("origin"))
	if survey == null or origin == null:
		return null
	var moved: Vector3 = survey - origin  # 測量座標 (東, 北, 標高) での、原点からの距離
	return Vector3(moved.x, moved.z, -moved.y)


# 世界の名前 (.json の world_id)。ない、または、ファイル名に使えない文字を含む時は空
static func world_id_for(path: String) -> String:
	var value: Variant = read_sidecar(path).get("world_id")
	if value is String and WORLD_ID_PATTERN.search(value) != null:
		return value
	return ""


# 水平位置 (x, z) の真上、または真下にある、メッシュの面の高さを、すべて返す (三角形の中にある所を、内挿する)。
# 頂点の間隔が広いメッシュでも、地面の高さが分かる。面がない所 (範囲の外、穴) は、空
static func surface_heights(meshes: Array, x: float, z: float) -> Array[float]:
	var heights: Array[float] = []
	for mesh: MeshInstance3D in meshes:
		var transform := mesh.global_transform if mesh.is_inside_tree() else mesh.transform
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := indices.size() if not indices.is_empty() else vertices.size()
			for i in range(0, count - 2, 3):
				var a := transform * vertices[indices[i] if not indices.is_empty() else i]
				var b := transform * vertices[indices[i + 1] if not indices.is_empty() else i + 1]
				var c := transform * vertices[indices[i + 2] if not indices.is_empty() else i + 2]
				if x < minf(a.x, minf(b.x, c.x)) or x > maxf(a.x, maxf(b.x, c.x)) or z < minf(a.z, minf(b.z, c.z)) or z > maxf(a.z, maxf(b.z, c.z)):
					continue
				var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
				if absf(denominator) < 1.0e-9:
					continue  # 真上から見て、面積がない三角形
				var wa := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / denominator
				var wb := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / denominator
				var wc := 1.0 - wa - wb
				if wa >= -1.0e-6 and wb >= -1.0e-6 and wc >= -1.0e-6:
					heights.append(wa * a.y + wb * b.y + wc * c.y)
	return heights


# target に水平方向で一番近い、メッシュの頂点を返す。頂点は面のあるところにしかない
static func pick_start(meshes: Array, target: Vector3) -> Vector3:
	var best := target
	var best_distance := INF
	for mesh: MeshInstance3D in meshes:
		for surface in mesh.mesh.get_surface_count():
			var vertices: PackedVector3Array = mesh.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var world_vertex := mesh.global_transform * vertex
				var distance := Vector2(world_vertex.x - target.x, world_vertex.z - target.z).length_squared()
				if distance < best_distance:
					best_distance = distance
					best = world_vertex
	return best


# 法線 (面の向き) のないメッシュに、法線を作る。
# 法線がないと、Godot は全ての面が同じ向きだと見なして、光 (太陽、月、篝火) が、起伏と関係なく、
# 半分の面にしか当たらない。変換ツールは法線を書き出すが、古い GLB や、ほかの GLB には、ないことがある。
# 法線のあるメッシュには、何もしない (読み込みが遅くならない)
static func _ensure_normals(world: Node) -> void:
	for instance: MeshInstance3D in world.find_children("*", "MeshInstance3D", true, false):
		var mesh := instance.mesh as ArrayMesh
		if mesh == null or not _lacks_normals(mesh):
			continue  # 法線がそろっているメッシュは、確かめるだけ。作り直さない (無駄な作成の時間とメモリを避ける)
		var rebuilt := ArrayMesh.new()
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var primitive := mesh.surface_get_primitive_type(surface)
			if _surface_lacks_normals(mesh, surface):
				arrays[Mesh.ARRAY_NORMAL] = _smooth_normals(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_INDEX])
			rebuilt.add_surface_from_arrays(primitive, arrays)
			rebuilt.surface_set_material(surface, mesh.surface_get_material(surface))
		instance.mesh = rebuilt


# 法線のないサーフェスがあるか。サーフェスの形式の情報だけを見る (頂点の配列を取り出さないので、速い)
static func _lacks_normals(mesh: ArrayMesh) -> bool:
	for surface in mesh.get_surface_count():
		if _surface_lacks_normals(mesh, surface):
			return true
	return false


# 三角形のサーフェスで、法線を持たないか (点や線のサーフェスには、法線は要らない)
static func _surface_lacks_normals(mesh: ArrayMesh, surface: int) -> bool:
	return (
		mesh.surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES
		and (mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_NORMAL) == 0
	)


# 頂点ごとの法線。頂点につながる三角形の法線を、面積に比例した重みで平均する (滑らかな陰影)
static func _smooth_normals(vertices: PackedVector3Array, indices: Variant) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	var triangle_indices: PackedInt32Array = indices if indices != null else PackedInt32Array()
	var count := triangle_indices.size() if not triangle_indices.is_empty() else vertices.size()
	for i in range(0, count - 2, 3):
		var ia := triangle_indices[i] if not triangle_indices.is_empty() else i
		var ib := triangle_indices[i + 1] if not triangle_indices.is_empty() else i + 1
		var ic := triangle_indices[i + 2] if not triangle_indices.is_empty() else i + 2
		# Godot の表は、時計回り。この順の外積が、表の向き (長さは面積に比例)
		var face := (vertices[ic] - vertices[ia]).cross(vertices[ib] - vertices[ia])
		normals[ia] += face
		normals[ib] += face
		normals[ic] += face
	for i in normals.size():
		normals[i] = normals[i].normalized() if normals[i].length_squared() > 0.0 else Vector3.UP
	return normals


# 実行時に GLB を読むと、メッシュは取り込み用の ImporterMeshInstance3D になる。
# 描画も当たり判定も MeshInstance3D が要るので、置き換える
static func _convert_importer_meshes(world: Node) -> void:
	for node: ImporterMeshInstance3D in world.find_children("*", "ImporterMeshInstance3D", true, false):
		var parent := node.get_parent()
		if node.mesh == null:
			parent.remove_child(node)
			node.queue_free()
			continue
		var instance := MeshInstance3D.new()
		instance.mesh = node.mesh.get_mesh()
		instance.transform = node.transform
		# 同じ名前のノードが残っていると名前に @ が付くので、先に外す
		var node_name := node.name
		parent.remove_child(node)
		node.queue_free()
		instance.name = node_name
		parent.add_child(instance)
