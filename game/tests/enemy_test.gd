extends SceneTree

# 実行: godot --headless --path game --script res://tests/enemy_test.gd
# 敵 (骸骨) と、プレイヤーの死亡を確かめる: モデルと剣、見つける範囲、近づく、振る (ダメージは 1 回、回避の最初の間は受けない)、
# 当てられる (ひるむ、体力、倒れて消える)、立て直し、プレイヤーが倒れる (DECEASED、動けない、復活)、世界での置き方と、復活で現れ直す

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


# 平らな広い地面 (60 m 四方) の GLB を作る。敵と的が置ける広さが要る
func _write_flat_glb(path: String) -> void:
	var cells := 12  # 5 m の格子 (始める場所は、中央に近い頂点の上になる)
	var vertices := PackedVector3Array()
	for z in cells + 1:
		for x in cells + 1:
			vertices.append(Vector3(-30.0 + x * 5.0, 0.0, -30.0 + z * 5.0))
	var indices := PackedInt32Array()
	for z in cells:
		for x in cells:
			var i := z * (cells + 1) + x
			indices.append_array([i, i + 1, i + cells + 1, i + 1, i + cells + 2, i + cells + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
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
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var player: CharacterBody3D = scene.get_node("Player")
	await _frames(60)
	var combat: PlayerCombat = player.combat
	check(player.is_in_group("player"), "プレイヤーは、グループ player にいる (敵が見つける)")

	# 敵のモデルと剣
	var enemy := Enemy.new()
	scene.add_child(enemy)
	enemy.global_position = player.global_position + Vector3(0.0, 0.05, -20.0)  # 見つける範囲の外
	await _frames(40)
	check(enemy.character.model != null and enemy.character.animation_player != null, "敵の、骸骨のモデルと、動きを読み込める")
	check(enemy.character.weapon != null and enemy.character.weapon.get_parent().name == "WeaponSlot", "骸骨は、右手の骨に、剣を持っている")
	check(enemy.is_in_group("hurtbox") and enemy.is_in_group("enemy"), "敵は、当てられる (hurtbox)")

	# 見つける範囲: 遠くは、見つけない。近づくと、見つけて、近づいてくる
	await create_timer(0.8).timeout
	check(enemy.state == Enemy.State.IDLE, "遠く (20 m) のプレイヤーは、見つけない")
	var before := enemy.global_position.distance_to(player.global_position)
	enemy.global_position = player.global_position + Vector3(0.0, 0.05, -10.0)
	await create_timer(1.2).timeout
	var after := enemy.global_position.distance_to(player.global_position)
	check(enemy.state == Enemy.State.CHASE and after < 10.0 - 2.0, "近く (10 m) に入ると、見つけて、近づいてくる (%.1f → %.1f m)" % [10.0, after])

	# 振る: 近づいたら、振る。ダメージは、1 回の攻撃で 1 度
	await create_timer(2.2).timeout
	check(combat.health <= PlayerCombat.MAX_HEALTH - Enemy.ATTACK_DAMAGE and combat.health >= PlayerCombat.MAX_HEALTH - Enemy.ATTACK_DAMAGE * 2.0 - 0.1, "近づいたら、振って、プレイヤーにダメージ (体力 %.0f)" % combat.health)
	check(is_equal_approx(fmod(PlayerCombat.MAX_HEALTH - combat.health, Enemy.ATTACK_DAMAGE), 0.0), "ダメージは、攻撃ごとに、決まった量 (%.0f ずつ)" % Enemy.ATTACK_DAMAGE)

	# 回避の最初の間は、攻撃を受けない
	combat.revive()
	combat.try_dodge(Vector3.RIGHT)
	enemy._strike(player)
	check(is_equal_approx(combat.health, PlayerCombat.MAX_HEALTH), "回避の最初の間は、敵の攻撃を受けない")
	await create_timer(0.8).timeout

	# 当てられる: ひるむ。体力が減る。数字が出る。倒すと、倒れて、消える
	enemy.global_position = Vector3(player.global_position.x, 0.05, player.global_position.z - 1.3)
	enemy.state = Enemy.State.IDLE
	enemy.velocity = Vector3.ZERO
	var enemy_hits: Array[float] = []
	enemy.damaged.connect(func(d: float) -> void: enemy_hits.append(d))
	var defeated := [false]
	enemy.defeated.connect(func() -> void: defeated[0] = true)
	check(enemy.take_damage(12.0, player) and is_equal_approx(enemy.health, Enemy.MAX_HEALTH - 12.0) and enemy.state == Enemy.State.STAGGER, "当てられると、体力が減り、ひるむ (体力 %.0f)" % enemy.health)
	check(not enemy.find_children("*", "Label3D", false, false).is_empty(), "当てられると、ダメージの数字が出る")
	await create_timer(0.7).timeout
	check(enemy.state != Enemy.State.STAGGER, "ひるみは、しばらくすると、終わる")
	enemy.take_damage(100.0, player)
	check(defeated[0] and enemy.state == Enemy.State.DEAD and not enemy.is_in_group("hurtbox"), "体力がなくなると、倒れる (もう当てられない)")
	check(not enemy.take_damage(5.0, player), "倒れている敵には、ダメージを与えられない")
	await create_timer(2.5).timeout
	check(not is_instance_valid(enemy), "倒した敵は、しばらくして、消える")

	# 立て直し (reset): 体力と、場所が戻る
	var enemy2 := Enemy.new()
	scene.add_child(enemy2)
	enemy2.global_position = player.global_position + Vector3(0.0, 0.05, -20.0)
	enemy2.spawn_position = enemy2.global_position
	await _frames(40)
	enemy2.take_damage(15.0, player)
	enemy2.global_position += Vector3(3.0, 0.0, 0.0)
	enemy2.reset()
	check(is_equal_approx(enemy2.health, Enemy.MAX_HEALTH) and enemy2.global_position.distance_to(enemy2.spawn_position) < 0.01 and enemy2.state == Enemy.State.IDLE, "立て直すと、体力と場所が、最初に戻る")

	# プレイヤーが倒れる: DECEASED、動けない、最後に休んだ篝火 (復帰地点) で、体力とスタミナが戻って復活する
	var revived := [false]
	player.revived.connect(func() -> void: revived[0] = true)
	player.spawn_position = player.global_position + Vector3(4.0, 0.0, 0.0)
	combat.health = 5.0
	player.take_damage(20.0)
	await _frames(5)
	check(player.dead and player.death_banner.visible and player.death_banner.label.text == "DECEASED", "体力がなくなると、倒れて、画面に DECEASED が出る")
	check(not combat.try_attack() and not combat.try_dodge(Vector3.RIGHT), "倒れている間は、攻撃も、回避もできない")
	await create_timer(0.4).timeout
	check(is_zero_approx(player.velocity.x) and is_zero_approx(player.velocity.z), "倒れている間は、動けない")
	var spawn: Vector3 = player.spawn_position
	await create_timer(float(player.DEATH_SECONDS) + float(player.RESCAN_SECONDS) + 0.8).timeout
	check(revived[0] and not player.dead and not player.death_banner.visible, "しばらくすると、復活して、DECEASED は、消える")
	check(is_equal_approx(combat.health, PlayerCombat.MAX_HEALTH) and is_equal_approx(combat.stamina, PlayerCombat.MAX_STAMINA), "復活すると、体力とスタミナは、満タン")
	check(player.global_position.distance_to(spawn) < 1.0, "最後に休んだ篝火 (復帰地点) に戻る (%.1f m)" % player.global_position.distance_to(spawn))
	check(combat.try_attack(), "復活したら、また、攻撃できる")
	scene.queue_free()
	await process_frame

	# 世界での置き方: 敵と的が、始める世界の篝火の近くにいる。倒しても、休むと、また現れる
	var flat_path := ProjectSettings.globalize_path("user://enemy_test_flat.glb")
	_write_flat_glb(flat_path)
	var world_scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	world_scene.get_node("DayNight").settings = settings
	world_scene.get_node("World").world_path = flat_path
	world_scene.get_node("World").save_enabled = false
	root.add_child(world_scene)
	await _frames(60)
	var world_player: CharacterBody3D = world_scene.get_node("Player")
	var placed: Enemy = world_scene.find_child("Enemy", true, false)
	check(placed != null and world_scene.find_child("TrainingDummy", true, false) != null, "世界に、敵と、的が置かれている")
	placed.take_damage(1000.0, world_player)
	await create_timer(2.4).timeout
	check(get_nodes_in_group("enemy").filter(func(e: Node) -> bool: return is_instance_valid(e) and e.state != Enemy.State.DEAD).is_empty(), "倒した敵は、消えている")
	world_player.rested.emit(world_player.global_position)  # 篝火で休んだ
	await _frames(5)
	check(not get_nodes_in_group("enemy").filter(func(e: Node) -> bool: return is_instance_valid(e) and e.state != Enemy.State.DEAD).is_empty(), "篝火で休むと、倒した敵が、また現れる")
	world_scene.queue_free()
	await process_frame
	quit(1 if failures.size() > 0 else 0)
