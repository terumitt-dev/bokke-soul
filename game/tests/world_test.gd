extends SceneTree

# 実行: godot --headless --path game --script res://tests/world_test.gd
# 点群から作ったメッシュ (GLB) を読み込んだ世界を、歩けることを確かめる。
# 先に godot --headless --path game --import --quit で GLB を取り込んでおく

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _initialize() -> void:
	var world: Node = load("res://scenes/world_sample.tscn").instantiate()
	root.add_child(world)
	var player: CharacterBody3D = world.get_node("Player")

	for i in 90:
		await physics_frame
	# 床の上面はボクセル 1 つ分 (0.5m) の高さ。メッシュの上に立てる
	check(player.is_on_floor(), "メッシュの床の上に立てる")
	check(absf(player.global_position.y - 0.5) < 0.1, "床の高さ (0.5m) に立つ")

	# 壁 (x=10 付近) に向かって押し続けても抜けない
	player.global_position = Vector3(8, 0.55, -10)
	for i in 30:
		player.velocity.x = 50
		player.move_and_slide()
		await physics_frame
	check(player.global_position.x < 10.2, "メッシュの壁を抜けない")

	# 床の外側 (メッシュの端の先) へ出ると落ちて、復帰する
	player.global_position = Vector3(-5, 0.55, -10)
	var spawn: Vector3 = player.spawn_position
	# 落下に約 2 秒、復帰の演出に 1.5 秒かかる
	for i in 400:
		await physics_frame
	var horizontal := Vector2(player.global_position.x - spawn.x, player.global_position.z - spawn.z)
	check(horizontal.length() < 0.5 and not player.rescanning, "メッシュの端から落ちると復帰する")

	quit(1 if failures.size() > 0 else 0)
