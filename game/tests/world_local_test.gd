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

	quit(1 if failures.size() > 0 else 0)
