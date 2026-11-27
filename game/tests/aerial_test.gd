extends SceneTree

# 実行: godot --headless --path game --script res://tests/aerial_test.gd
# 航空写真 (地形の隣の .jpg) を確かめる: 読み込み、なくても動く、壊れていても動く、地面の素材に、地形の範囲で貼る

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


# 平らな地面 (東西 40 m、南北 30 m。x は 0〜40、z は -30〜0) の GLB を作る
func _write_glb(path: String) -> void:
	var vertices := PackedVector3Array([Vector3(0, 0, -30), Vector3(40, 0, -30), Vector3(40, 0, 0), Vector3(0, 0, 0)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 3, 1, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var root_node := Node3D.new()
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	root_node.add_child(instance)
	var state := GLTFState.new()
	var document := GLTFDocument.new()
	document.append_from_scene(root_node, state)
	document.write_to_filesystem(state, path)
	root_node.free()


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("user://aerial_test")
	DirAccess.make_dir_recursive_absolute(directory)
	var plain := directory + "/plain.glb"
	var photo := directory + "/photo.glb"
	var broken := directory + "/broken.glb"
	for path in [plain, photo, broken]:
		_write_glb(path)
	var image := Image.create(8, 6, false, Image.FORMAT_RGB8)
	image.fill(Color(0.8, 0.2, 0.2))
	image.save_jpg(directory + "/photo.jpg", 0.95)
	var file := FileAccess.open(directory + "/broken.jpg", FileAccess.WRITE)
	file.store_string("これは画像ではありません")
	file.close()

	check(WorldLoader.aerial_for(plain) == null, "写真がない世界は、null (単色で動く)")
	var texture := WorldLoader.aerial_for(photo)
	check(texture != null and texture.get_width() == 8 and texture.get_height() == 6, "世界の隣の .jpg を、写真として読み込める")
	check(WorldLoader.aerial_for(broken) == null, "壊れた .jpg は、null (止まらず、単色で動く)")
	check(WorldLoader.aerial_for("res://assets/sample_world.glb") == null, "サンプルの世界には、写真がない")

	var loaded: Dictionary = WorldLoader.load_world(photo)
	check(loaded.node != null and loaded.node.has_meta(WorldLoader.AERIAL_META) and loaded.node.get_meta(WorldLoader.AERIAL_META) is Texture2D, "写真のある世界は、読み込むと、写真が付く")
	check(not WorldLoader.load_world(plain).node.has_meta(WorldLoader.AERIAL_META), "写真のない世界には、付かない")
	check(WorldLoader.load_world(broken).node != null, "写真が壊れていても、世界は読み込める")

	# 地面の素材: 写真は、地形の範囲 (西北の角と、東西、南北の長さ) に貼る。タイルの位置 (offset) が動いても、範囲が追う
	var player := Node3D.new()
	root.add_child(player)
	var world: Node3D = loaded.node
	world.position = Vector3(100.0, 5.0, -200.0)
	root.add_child(world)
	var points := PointWorld.new()
	root.add_child(points)
	await process_frame  # 木に入るまで待つ (座標変換には、木に入っている必要がある)
	points.setup(world, player)
	var material: ShaderMaterial = (points._meshes[0] as MeshInstance3D).material_override
	var rect: Vector4 = material.get_shader_parameter("aerial_rect")
	check(is_equal_approx(rect.x, 100.0) and is_equal_approx(rect.y, -230.0) and is_equal_approx(rect.z, 40.0) and is_equal_approx(rect.w, 30.0), "写真の範囲は、地形の範囲 (位置を動かしても追う): %s" % [rect])
	check(is_equal_approx(material.get_shader_parameter("aerial_mix"), 1.0) and material.get_shader_parameter("aerial_tex") == loaded.node.get_meta(WorldLoader.AERIAL_META), "地面の素材に、写真が貼られる")

	var plain_world: Node3D = WorldLoader.load_world(plain).node
	root.add_child(plain_world)
	var plain_points := PointWorld.new()
	root.add_child(plain_points)
	await process_frame
	plain_points.setup(plain_world, player)
	var plain_material: ShaderMaterial = (plain_points._meshes[0] as MeshInstance3D).material_override
	check(is_zero_approx(plain_material.get_shader_parameter("aerial_mix") if plain_material.get_shader_parameter("aerial_mix") != null else 0.0), "写真のない世界は、単色のまま (aerial_mix が 0)")

	DirAccess.remove_absolute(directory + "/photo.jpg")
	quit(1 if failures.size() > 0 else 0)
