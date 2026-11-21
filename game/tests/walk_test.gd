extends SceneTree

# 実行: godot --headless --path game --script res://tests/walk_test.gd
# 失敗した項目があれば終了コード 1 で終わる

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var player: CharacterBody3D = main.get_node("Player")

	for i in 30:
		await physics_frame
	check(player.is_on_floor(), "床の上に立てる")

	# 北の壁 (z=-8) へ押し続けても壁を抜けない
	player.global_position = Vector3(0, 0.05, -6)
	for i in 30:
		player.velocity.z = -50
		player.move_and_slide()
		await physics_frame
	check(player.global_position.z > -7.5, "壁を抜けない")

	# 床の下へ落ちると復帰演出が出て、開始地点へ戻る
	var spawn: Vector3 = player.spawn_position
	player.global_position = Vector3(0, -30, 0)
	await physics_frame
	await physics_frame
	check(player.rescanning and main.get_node("HUD/Message").visible, "落下で再スキャン演出が出る")
	for i in 200:
		await physics_frame
	check(player.global_position.distance_to(spawn) < 0.1 and not player.rescanning, "開始地点へ復帰する")

	quit(1 if failures.size() > 0 else 0)
