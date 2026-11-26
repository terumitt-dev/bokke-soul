extends SceneTree

# 実行: godot --headless --path game --script res://tests/character_test.gd
# プレイヤーの見た目 (人型のモデルと動き) を確かめる: 読み込めること、背の高さ、正面の向き、武器を隠すこと、
# 状態 (待つ、歩く、走る、空中、休む) で動きが変わること、モデルを読み込めない時は仮のカプセルのままであること

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _initialize() -> void:
	# プレイヤーが、場面の中で、高い所に置かれていても、足は、プレイヤーの足元にある (測る座標が、場面の原点でない)
	var high_scene: Node = load("res://scenes/main.tscn").instantiate()
	high_scene.get_node("Player").position = Vector3(30.0, 7.0, -40.0)
	root.add_child(high_scene)
	await process_frame
	var high_player: CharacterBody3D = high_scene.get_node("Player")
	var feet := INF
	for mesh: MeshInstance3D in high_player.character.model.find_children("*", "MeshInstance3D", true, false):
		if not (mesh.name in CharacterModel.WEAPON_PARTS):
			feet = minf(feet, (mesh.global_transform * mesh.get_aabb()).position.y)
	check(absf(feet - high_player.global_position.y) < 0.15, "プレイヤーが、場面の高い所 (y = 7) に置かれていても、足は、プレイヤーの足元にある (差 %.2f)" % (feet - high_player.global_position.y))
	high_scene.queue_free()
	await process_frame

	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var player: CharacterBody3D = scene.get_node("Player")
	for i in 60:
		await physics_frame
	var character: CharacterModel = player.character
	check(character.model != null and character.animation_player != null, "人型のモデルと、その動き (AnimationPlayer) を読み込める")
	check(not player.get_node("Model/Body").visible and not player.get_node("Model/Facing").visible, "モデルを読み込めたら、仮のカプセルは隠れる")

	# 背の高さと、足の位置 (体の部品だけ。武器は除く)
	var low := INF
	var high := -INF
	for mesh: MeshInstance3D in character.model.find_children("*", "MeshInstance3D", true, false):
		if mesh.name in CharacterModel.WEAPON_PARTS:
			check(not mesh.visible, "武器 (%s) は、隠れている" % mesh.name)
			continue
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		low = minf(low, box.position.y - player.global_position.y)
		high = maxf(high, box.end.y - player.global_position.y)
	check(absf((high - low) - CharacterModel.HEIGHT) < 0.1, "背の高さは、約 %.1f m (%.2f)" % [CharacterModel.HEIGHT, high - low])
	check(absf(low) < 0.1, "足は、地面 (プレイヤーの足元) にある (%.2f)" % low)

	# 正面は -Z (このゲームの前): 背中のマントは、体の中心より、後ろ (+Z) に偏る
	var cape: MeshInstance3D = character.model.find_children("Rogue_Cape", "MeshInstance3D", true, false)[0]
	var body: MeshInstance3D = character.model.find_children("Rogue_Body", "MeshInstance3D", true, false)[0]
	var cape_behind := (cape.global_transform * cape.get_aabb().get_center()).z - (body.global_transform * body.get_aabb().get_center()).z
	check(cape_behind > 0.02, "正面は、前 (-Z) を向く。背中のマントは、体より後ろ (+Z) にある (%.3f)" % cape_behind)

	# 状態と動き: 止まっている → 待つ
	player.velocity = Vector3.ZERO
	for i in 30:
		await physics_frame
	check(character.state == "idle" and character.animation_player.current_animation == "Idle", "止まっていると、「待つ」(%s / %s)" % [character.state, character.animation_player.current_animation])
	# 歩く速さ、走る速さ
	player._update_animation(true)
	player.velocity = Vector3(4.0, 0.0, 0.0)
	player._update_animation(true)
	check(character.state == "walk" and character.animation_player.current_animation == "Walking_A", "歩く速さでは、「歩く」(%s)" % character.state)
	player.velocity = Vector3(7.0, 0.0, 0.0)
	player._update_animation(true)
	check(character.state == "run" and character.animation_player.current_animation == "Running_A", "走る速さでは、「走る」(%s)" % character.state)
	player._update_animation(false)
	check(character.state == "air" and character.animation_player.current_animation == "Jump_Idle", "空中では、「空中」(%s)" % character.state)
	# くり返す動きは、くり返す。1 回だけの動きは、くり返さない
	check(character.animation_player.get_animation("Idle").loop_mode == Animation.LOOP_LINEAR and character.animation_player.get_animation("Walking_A").loop_mode == Animation.LOOP_LINEAR, "待つ、歩く動きは、くり返す")
	check(character.animation_player.get_animation("Interact").loop_mode == Animation.LOOP_NONE, "休む動きは、1 回だけ")

	# 休む動き: 流している間は、止まっていても、待つに切り替わらない。動き出したら、すぐ中断する
	player.velocity = Vector3.ZERO
	character.play_once("rest")
	player._update_animation(true)
	check(character.state == "rest", "休む動きの間は、待つに切り替わらない (%s)" % character.state)
	player.velocity = Vector3(4.0, 0.0, 0.0)
	player._update_animation(true)
	check(character.state == "walk", "動き出したら、休む動きを中断して、歩く (%s)" % character.state)

	# 読み込めない時は、仮のカプセルのまま (落ちない)
	var plain := CharacterModel.new()
	var holder := Node3D.new()
	var capsule := MeshInstance3D.new()
	capsule.name = "Body"
	holder.add_child(capsule)
	holder.add_child(plain)
	root.add_child(holder)
	check(not plain.load_model("res://assets/characters/missing.glb") and capsule.visible, "モデルを読み込めない時は、false を返し、仮のカプセルは、そのまま見える")
	plain.play_state("walk")  # 落ちない
	plain.play_once("rest")
	check(plain.state == "", "モデルがなくても、動きの操作は、何もせず、落ちない")
	holder.queue_free()
	scene.queue_free()
	await process_frame
	quit(1 if failures.size() > 0 else 0)
