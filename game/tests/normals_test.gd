extends SceneTree

# 実行: godot --headless --path game --script res://tests/normals_test.gd
# 地形の法線 (面の向き) を確かめる。法線がないと、Godot は全ての面が同じ向きだと見なして、
# 光 (太陽、月、篝火) が、起伏と関係なく、半分の面にしか当たらない

const TMP := "user://normals_test"

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	_test_sample_world()
	_test_missing_normals()
	_test_existing_normals_are_kept()
	for file in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [TMP, file]))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	quit(1 if failures.size() > 0 else 0)


func _surface_arrays(world: Node3D) -> Array:
	var mesh := world.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	return mesh.mesh.surface_get_arrays(0)


# 法線が、頂点と同じ数だけあり、長さが 1 か
func _normals_ok(arrays: Array) -> bool:
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	if normals == null or (normals as PackedVector3Array).size() != (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
		return false
	for normal: Vector3 in normals:
		if absf(normal.length() - 1.0) > 0.01:
			return false
	return true


# 法線のない GLB を作る (三角形の格子。傾き slope_x で、東 (+X) へ上る斜面)
func _write_glb_without_normals(path: String, slope_x: float) -> void:
	var cells := 6
	var vertices := PackedVector3Array()
	for z in cells + 1:
		for x in cells + 1:
			vertices.append(Vector3(x, x * slope_x, z))
	var indices := PackedInt32Array()
	for z in cells:
		for x in cells:
			var i := z * (cells + 1) + x
			# 上から見て、手前 (+Z) から奥へ。Godot の表 (時計回り) になる順
			indices.append_array([i, i + 1, i + cells + 1, i + 1, i + cells + 2, i + cells + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices  # 法線は、わざと入れない
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


func _test_sample_world() -> void:
	var loaded := WorldLoader.load_world(WorldLoader.SAMPLE_PATH)
	var arrays := _surface_arrays(loaded.node)
	check(_normals_ok(arrays), "リポジトリのサンプルの世界には、法線が入っている (頂点と同じ数、長さ 1)")
	# 床の上面は +Y、壁は水平の向き。向きが、いろいろあること (一方向に固定されていない)
	var up := 0
	var sideways := 0
	for normal: Vector3 in arrays[Mesh.ARRAY_NORMAL]:
		if normal.y > 0.99:
			up += 1
		elif absf(normal.y) < 0.01:
			sideways += 1
	check(up > 100 and sideways > 100, "法線の向きが、面に合っている (上向き %d、横向き %d)" % [up, sideways])
	loaded.node.free()


func _test_missing_normals() -> void:
	var path := TMP + "/slope.glb"
	_write_glb_without_normals(path, 0.5)
	var loaded := WorldLoader.load_world(path)
	check(loaded.node != null, "法線のない GLB も、読み込める")
	var arrays := _surface_arrays(loaded.node)
	check(_normals_ok(arrays), "法線のない GLB は、読み込む時に、法線を作る (頂点と同じ数、長さ 1)")

	# 東へ上る斜面 (傾き 0.5) の法線は、上向きで、西 (-X) へ傾く
	var mean := Vector3.ZERO
	var all_up := true
	for normal: Vector3 in arrays[Mesh.ARRAY_NORMAL]:
		mean += normal
		all_up = all_up and normal.y > 0.5
	mean = mean.normalized()
	check(all_up, "作った法線は、地形の表 (上) を向く (表裏を取り違えていない)")
	check(mean.x < -0.3, "東へ上る斜面の法線は、西へ傾く (x = %.2f)" % mean.x)
	var tilt := rad_to_deg(acos(mean.y))
	check(absf(tilt - rad_to_deg(atan(0.5))) < 3.0, "法線の傾きが、斜面の傾きに合う (%.1f 度、斜面は %.1f 度)" % [tilt, rad_to_deg(atan(0.5))])

	# 平らな面は、真上
	var flat_path := TMP + "/flat.glb"
	_write_glb_without_normals(flat_path, 0.0)
	var flat := WorldLoader.load_world(flat_path)
	var flat_ok := true
	for normal: Vector3 in _surface_arrays(flat.node)[Mesh.ARRAY_NORMAL]:
		flat_ok = flat_ok and normal.dot(Vector3.UP) > 0.999999  # GLB の書き出しと読み込みで、ごく小さな誤差が入る
	check(flat_ok, "平らな面の法線は、ほぼ真上 (ずれは 0.1 度未満)")
	loaded.node.free()
	flat.node.free()

	# 読み込んだ世界は、実際に光が当たる形で使える (法線がある素材として、メッシュが有効)
	var reloaded := WorldLoader.load_world(path)
	var mesh_instance := reloaded.node.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	check(mesh_instance.mesh.get_surface_count() == 1 and mesh_instance.material_override is StandardMaterial3D, "法線を作ったあとも、メッシュは 1 つで、砂の素材が付く")
	reloaded.node.free()


func _test_existing_normals_are_kept() -> void:
	# 法線が入っている GLB は、作り直さない (変えない。読み込みも遅くならない)
	var loaded := WorldLoader.load_world(WorldLoader.SAMPLE_PATH)
	var arrays := _surface_arrays(loaded.node)
	var again := WorldLoader.load_world(WorldLoader.SAMPLE_PATH)
	var again_arrays := _surface_arrays(again.node)
	check((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array) == (again_arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array), "法線のある GLB は、毎回、同じ法線で読み込まれる (作り直さない)")
	var started := Time.get_ticks_usec()
	var third := WorldLoader.load_world(WorldLoader.SAMPLE_PATH)
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	check(elapsed < 500.0, "サンプルの世界の読み込みは、速い (%.0f ms)" % elapsed)
	loaded.node.free()
	again.node.free()
	third.node.free()
