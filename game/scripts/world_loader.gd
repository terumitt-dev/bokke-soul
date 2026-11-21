class_name WorldLoader
extends RefCounted
# 点群や標高グリッドから作った世界 (GLB) を、実行時に読み込む。
# データはリポジトリに入れないので、取り込みは通さず、起動時に場所を渡す:
#   godot --path game -- --world=/path/to/world.glb
# 何も指定しなければ、リポジトリに入っている人工のサンプルを使う

const ARG_PREFIX := "--world="
const SAMPLE_PATH := "res://assets/sample_world.glb"
# いまは色のないデータだけを扱うので、くすんだ砂の色を付ける (色つきの点群を扱う時に見直す)
const TERRAIN_COLOR := Color(0.42, 0.38, 0.33)


# タイトル画面で選んだ世界の場所。ゲーム本体へ引き継ぐ (起動時の引数がない時に使う)
static var selected_path := ""


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
	var material := StandardMaterial3D.new()
	material.albedo_color = TERRAIN_COLOR
	material.roughness = 1.0
	for mesh: MeshInstance3D in world.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = material
	return {"node": world, "error": ""}


# 世界のデータの隣にある .json (変換ツールが書く) から、出典を読む。
# {"credit": 出典の文, "license_url": ライセンスの URL}。なければ空の文字列
static func credit_for(path: String) -> Dictionary:
	var result := {"credit": "", "license_url": ""}
	var sidecar := path.get_basename() + ".json"
	if not FileAccess.file_exists(sidecar):
		return result
	# JSON.parse_string は壊れた入力でエラーを出すので、結果だけを受け取る。出典がなくても、ゲームは動く
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(sidecar)) != OK:
		return result
	if json.data is Dictionary:
		for key: String in result:
			if json.data.get(key) is String:
				result[key] = json.data[key]
	return result


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
