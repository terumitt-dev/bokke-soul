extends SceneTree

# 実行: godot --headless --path game --script res://tests/world_local_test.gd
# 実行時に指定した GLB (取り込みを通さない) を読み込んで、歩けることを確かめる

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _start(path: String) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	scene.get_node("World").world_path = path
	root.add_child(scene)
	return scene


# 4 つの頂点で 1 枚の板を作る
func _quad_mesh(corners: Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(corners)
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _initialize() -> void:
	# 人工のサンプル (床 20m 四方と壁)。世界の中央の上空から降りて、地面に立つ
	var scene := _start("res://assets/sample_world.glb")
	var player: CharacterBody3D = scene.get_node("Player")
	for i in 120:
		await physics_frame
	check(player.is_on_floor(), "指定した GLB の地面に立てる")
	check(player.global_position.y > 0.4, "地面の下へ落ちていない")
	check(scene.get_node("World").find_children("*", "StaticBody3D", true, false).size() > 0, "当たり判定が作られている")
	scene.queue_free()
	await process_frame

	# 存在しないファイルは、メッセージを出して止まる (クラッシュしない)
	var broken := _start("/nonexistent/world.glb")
	await process_frame
	check(broken.get_node("HUD/Message").visible, "読み込めない時はメッセージを出す")
	check(broken.get_node("World").get_child_count() == 0, "読み込めない時は何も追加しない")
	# 床がなくても、プレイヤーは落ち続けて「再スキャン中」でエラー表示を上書きしない
	for i in 300:
		await physics_frame
	check(not broken.get_node("Player").rescanning, "読み込めない時はプレイヤーを止める")
	check("読み込めませんでした" in broken.get_node("HUD/Message").text, "読み込めない時はエラー表示が残る")

	# 世界の中央に穴があっても、開始地点は地面のある所になる
	var ring := MeshInstance3D.new()
	ring.mesh = _quad_mesh([Vector3(-12, 5, -2), Vector3(-8, 5, -2), Vector3(-8, 5, 2), Vector3(-12, 5, 2)])
	var ring2 := MeshInstance3D.new()
	ring2.mesh = _quad_mesh([Vector3(8, 7, -2), Vector3(12, 7, -2), Vector3(12, 7, 2), Vector3(8, 7, 2)])
	root.add_child(ring)
	root.add_child(ring2)
	var start: Vector3 = load("res://scripts/world_local.gd").pick_start([ring, ring2], Vector3.ZERO)
	check(absf(absf(start.x) - 8.0) < 0.01 and (start.y == 5.0 or start.y == 7.0), "中央が穴でも、地面のある頂点を開始地点にする")

	quit(1 if failures.size() > 0 else 0)
