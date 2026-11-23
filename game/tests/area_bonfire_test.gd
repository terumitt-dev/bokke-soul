extends SceneTree

# 実行: godot --headless --path game --script res://tests/area_bonfire_test.gd
# マップの篝火 (データの隣の .json の bonfire と name) を、測量座標から正しく置き、そこから始まり、
# 名前を出して休めることを確かめる。先に godot --headless --path game --import --quit でデータを取り込んでおく

const SAMPLE := "res://assets/sample_world.glb"
const DIR := "user://test_area_bonfire"
const ORIGIN := Vector3(1000.0, 2000.0, 50.0)

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


# サンプルの世界を、専用の場所へ写して、隣の .json (sidecar) を付ける。測量座標 (東, 北, 標高) → ゲームの座標は、
# (東 - origin.東, 標高 - origin.標高, -(北 - origin.北))
func _make_world(name: String, sidecar: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var world := "%s/%s.glb" % [DIR, name]
	var file := FileAccess.open(world, FileAccess.WRITE)
	file.store_buffer(FileAccess.get_file_as_bytes(SAMPLE))
	file.close()
	_write("%s/%s.json" % [DIR, name], JSON.stringify(sidecar))
	return world


func _survey_of(local: Vector3) -> Array:
	return [local.x + ORIGIN.x, -local.z + ORIGIN.y, local.y + ORIGIN.z]


func _start_world(path: String) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = path
	scene.get_node("World").save_enabled = false  # 本物のセーブに触らない
	root.add_child(scene)
	return scene


func _initialize() -> void:
	var loaded: Dictionary = WorldLoader.load_world(SAMPLE)
	var meshes: Array = loaded.node.find_children("*", "MeshInstance3D", true, false)
	var ground := WorldLoader.pick_start(meshes, Vector3.ZERO)  # サンプルの地面の、ある点 (ゲームの座標)
	loaded.node.free()

	# 読み込み (測量座標 → ゲームの座標)
	var base := {"origin": [ORIGIN.x, ORIGIN.y, ORIGIN.z]}
	var named := _make_world("named", base.merged({"name": " テスト ", "bonfire": _survey_of(ground)}))
	var placed: Variant = WorldLoader.bonfire_for(named)
	check(placed != null and (placed as Vector3).is_equal_approx(ground), "篝火の場所を、測量座標から、ゲームの座標に直せる: %s" % [placed])
	check(WorldLoader.name_for(named) == "テスト", "マップの名前を読める (前後の空白は取る)")
	check(WorldLoader.bonfire_for(SAMPLE) == null and WorldLoader.name_for(SAMPLE) == "", ".json がない世界は、篝火の場所も、名前もない")
	for bad in [{"bonfire": [1, 2]}, {"bonfire": [1.0, 2.0, NAN]}, {"bonfire": "x"}, {"origin": [1, 2, 3]}, {}]:
		var broken := _make_world("broken", bad.merged(base) if not bad.has("origin") else bad)
		check(WorldLoader.bonfire_for(broken) == null, "場所が不正、または、足りない時は、null: %s" % [bad])
	# 原点が動いても (作り直して)、測量座標が同じなら、同じ場所を指す
	var moved := _make_world("moved", {"origin": [ORIGIN.x + 10.0, ORIGIN.y, ORIGIN.z], "bonfire": _survey_of(ground)})
	check((WorldLoader.bonfire_for(moved) as Vector3).is_equal_approx(ground - Vector3(10.0, 0.0, 0.0)), "原点が動いたら、篝火の、ゲームの座標も、同じだけ動く (測量座標では、同じ場所)")

	# 置いて、そこから始まる
	var scene := _start_world(named)
	for i in 60:
		await physics_frame
	var fire: Node3D = scene.find_child("AreaBonfire", true, false)
	var player: CharacterBody3D = scene.get_node("Player")
	check(fire != null and scene.find_child("StartBonfire", true, false) == null, "マップの篝火があれば、そこへ置く (いつもの始まりの篝火は、置かない)")
	check(fire != null and fire.global_position.is_equal_approx(ground), "篝火は、データの場所に置かれる")
	check(fire != null and fire.display_name() == "テストの篝火", "名前は「<マップの名前>の篝火」")
	check(fire != null and Vector2(player.global_position.x - fire.global_position.x, player.global_position.z - fire.global_position.z).length() < 3.0, "新しく始める時は、その篝火のそばから始まる")
	check(fire != null and player.spawn_position.is_equal_approx(fire.rest_position()) and not player.has_rested, "復帰する位置は、その篝火。まだ、休んでいない")

	# 休んだ時の知らせ: 初めては「火を灯した」、2 度目からは「休んだ」
	player.global_position = fire.global_position + Vector3(0.5, 0.5, 0.0)
	player._update_nearby_bonfire()
	player.rest()
	check(player.message.text == "「テストの篝火」に火を灯した", "初めて休むと、名前つきで「火を灯した」: %s" % player.message.text)
	player.rest()
	check(player.message.text == "「テストの篝火」で休んだ", "2 度目からは、「休んだ」: %s" % player.message.text)
	scene.queue_free()
	await process_frame
	await process_frame

	# 名前がない篝火は、いつもの知らせ
	var unnamed := _make_world("unnamed", {"origin": [ORIGIN.x, ORIGIN.y, ORIGIN.z], "bonfire": _survey_of(ground)})
	var plain := _start_world(unnamed)
	for i in 60:
		await physics_frame
	var plain_player: CharacterBody3D = plain.get_node("Player")
	var plain_fire: Node3D = plain.find_child("AreaBonfire", true, false)
	plain_player.global_position = plain_fire.global_position + Vector3(0.5, 0.5, 0.0)
	plain_player._update_nearby_bonfire()
	plain_player.rest()
	check(plain_fire.display_name() == "" and plain_player.message.text == "基準点を確定しました", "名前がなければ、「基準点を確定しました」")
	plain.queue_free()
	await process_frame
	await process_frame

	# 場所が、世界の外 (地面のない所): いつもの始まり方にする
	var outside := _make_world("outside", {"origin": [ORIGIN.x, ORIGIN.y, ORIGIN.z], "bonfire": [ORIGIN.x + 5000.0, ORIGIN.y, ORIGIN.z]})
	var fallback := _start_world(outside)
	for i in 30:
		await physics_frame
	check(fallback.find_child("AreaBonfire", true, false) == null and fallback.find_child("StartBonfire", true, false) != null, "篝火の場所が世界の外なら、置かず、いつもの始まり方にする")
	fallback.queue_free()
	await process_frame

	for file in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	quit(1 if failures.size() > 0 else 0)
