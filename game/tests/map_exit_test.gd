extends SceneTree

# 実行: godot --headless --path game --script res://tests/map_exit_test.gd
# マップの端の出口 (隣のマップへ移る)、着いた位置、暗転、続きから (最後に遊んだマップ) を確かめる。
# 2 つのマップ (サンプルの世界の写し) を、東西に並べて使う。先に godot --headless --path game --import --quit しておく

const SAMPLE := "res://assets/sample_world.glb"
const DIR := "user://test_map_exit"
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


func _make_world(name: String, id: String, label: String, origin: Vector3, size: Vector3) -> String:
	var world := "%s/%s.glb" % [DIR, name]
	var file := FileAccess.open(world, FileAccess.WRITE)
	file.store_buffer(FileAccess.get_file_as_bytes(SAMPLE))
	file.close()
	_write("%s/%s.json" % [DIR, name], JSON.stringify({"world_id": id, "name": label, "origin": [origin.x, origin.y, origin.z], "size": [size.x, size.y, size.z]}))
	return world


func _start_world(path: String) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = path
	scene.get_node("World").save_enabled = false  # 本物のセーブに触らない
	scene.get_node("World").auto_change_scene = false  # 場面は切り替えず、引き継ぎ (WorldLoader.arrival) を確かめる
	root.add_child(scene)
	return scene


func _initialize() -> void:
	# サンプルの世界の大きさ (幅 = 東西、奥行き = 南北)
	var loaded: Dictionary = WorldLoader.load_world(SAMPLE)
	root.add_child(loaded.node)
	await process_frame
	var box := AABB()
	var first := true
	for mesh: MeshInstance3D in loaded.node.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = mesh.global_transform * mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	loaded.node.free()
	var size := box.size
	check(size.x >= 15.0 and size.z >= 15.0, "(準備) サンプルの世界の大きさが分かる: %s" % [size])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	# A の東に、隙間 1 m で、B を並べる (測量座標で、B の原点 = A の原点 + 幅 + 1)
	var path_a := _make_world("a", "exit-a", "西の入口", ORIGIN, size)
	var path_b := _make_world("b", "exit-b", "東の入口", ORIGIN + Vector3(size.x + 1.0, 0.0, 0.0), size)
	WorldLoader.arrival = {}

	# A を始める。隣は、東の B だけ
	var scene := _start_world(path_a)
	for i in 30:
		await physics_frame
	var world: Node = scene.get_node("World")
	var player: CharacterBody3D = scene.get_node("Player")
	check(world._exits.size() == 1 and world._exits.has("east") and world._exits.east.world_id == "exit-b", "A の隣は、東の B だけ (%s)" % [world._exits.keys()])
	await create_timer(1.7).timeout  # 始めてからの、出口が効かない時間 (着いた直後に戻らないため) を、過ぎる

	# 端から離れていれば、出口にならない。隣のない西の端でも、ならない
	player.global_position = Vector3(size.x / 2.0, 3.0, -size.z / 2.0)
	for i in 10:
		await physics_frame
	check(WorldLoader.arrival.is_empty() and not world._traveling, "真ん中では、移らない")
	player.global_position = Vector3(1.0, 3.0, -size.z / 2.0)
	for i in 10:
		await physics_frame
	check(WorldLoader.arrival.is_empty() and not world._traveling, "隣のない西の端では、移らない")

	# 東の端に近づくと、B へ移る。着く位置は、測量座標で同じ場所を、端から少し内側へ
	player.pivot.rotation.y = 0.7
	player.global_position = Vector3(size.x - 1.0, 3.0, -size.z / 2.0)
	var traveled_to := []
	world.traveled.connect(func(path: String) -> void: traveled_to.append(path))
	for i in 20:
		await physics_frame
	await create_timer(0.6).timeout  # 暗転
	var carried: Dictionary = WorldLoader.arrival
	check(not carried.is_empty() and carried.path == path_b and traveled_to == [path_b], "東の端に近づくと、B へ移る (行き先: %s)" % [carried.get("path")])
	var arrive: Vector3 = carried.get("position", Vector3.ZERO)
	check(is_equal_approx(arrive.x, 6.0), "着く位置は、B の端から 6 m の内側 (x = %s)" % [arrive.x])
	check(absf(arrive.z - (-size.z / 2.0)) < 0.01, "南北は、同じ場所 (測量座標で連続): z = %s" % [arrive.z])
	check(is_equal_approx(float(carried.get("yaw", 0.0)), 0.7) and carried.get("from") == "西の入口", "視点の向きと、前のマップの名前を引き継ぐ")
	check(world._veil != null and world._veil.modulate.a > 0.99 and world._veil_label.visible, "暗転して、「読み込み中」が出る")
	scene.queue_free()
	await process_frame
	await process_frame

	# 着いた先 (B): 引き継ぎから始まる。世界の場所は、引き継ぎが決める (world_path は空)
	WorldLoader.arrival = {"path": path_b, "position": Vector3(6.0, 500.0, -size.z / 2.0), "yaw": 1.0, "pitch": -0.2, "time": 40.0, "from": "西の入口"}
	var scene_b: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings_b := GameSettings.new()
	settings_b.weather_enabled = false
	scene_b.get_node("DayNight").settings = settings_b
	scene_b.get_node("World").save_enabled = false
	scene_b.get_node("World").auto_change_scene = false
	root.add_child(scene_b)
	for i in 30:
		await physics_frame
	var world_b: Node = scene_b.get_node("World")
	var player_b: CharacterBody3D = scene_b.get_node("Player")
	check(WorldLoader.arrival.is_empty(), "引き継ぎは、受け取ったら、空になる (次に始める時に、残らない)")
	check(world_b._path == path_b and world_b._entry.world_id == "exit-b", "世界の場所は、引き継ぎが決める (world_path が空でも、B)")
	check(Vector2(player_b.global_position.x - 6.0, player_b.global_position.z + size.z / 2.0).length() < 2.0, "着いた位置に立つ: %s" % [player_b.global_position])
	check(absf(player_b.pivot.rotation.y - 1.0) < 0.01 and absf(player_b.pivot.rotation.x + 0.2) < 0.01, "視点の向きが、引き継がれる")
	var surfaces := WorldLoader.surface_heights(player_b.get_parent().find_children("*", "MeshInstance3D", true, false), 6.0, -size.z / 2.0)
	check(is_equal_approx(player_b.spawn_position.x, 6.0) and surfaces.any(func(h: float) -> bool: return absf(h + 0.05 - player_b.spawn_position.y) < 0.01), "篝火で休んでいなければ、復帰地点は、着いた位置 (地面の高さに合わせる): %s" % [player_b.spawn_position])
	check(player_b.global_position.y < 50.0, "着く高さは、地面に合わせる (引き継いだ高さが、桁外れでも、空高くに出ない): %s" % [player_b.global_position.y])
	check(scene_b.get_node("DayNight").time.total_hours >= 40.0, "時刻が、引き継がれる (%.2f)" % scene_b.get_node("DayNight").time.total_hours)
	check(world_b._exits.size() == 1 and world_b._exits.has("west"), "B の隣は、西の A だけ")
	# 着いた直後は、端に寄っても、すぐには移らない (行き来を繰り返さない)。時間が過ぎれば、移る
	player_b.global_position = Vector3(1.0, 3.0, -size.z / 2.0)
	for i in 10:
		await physics_frame
	check(WorldLoader.arrival.is_empty() and not world_b._traveling, "着いた直後は、端に寄っても、すぐには戻らない")
	await create_timer(1.7).timeout
	player_b.global_position = Vector3(1.0, 3.0, -size.z / 2.0)
	for i in 10:
		await physics_frame
	check(WorldLoader.arrival.get("path") == path_a, "時間が過ぎれば、西の端から A へ戻れる")
	scene_b.queue_free()
	await process_frame
	WorldLoader.arrival = {}

	# 続きから: 最後に遊んだマップから始まる。はじめから: 始まりの世界から
	SaveGame.directory = DIR + "/saves"
	SaveGame.allow_headless = true
	SaveGame.delete()
	check(SaveGame.current_area() == "", "セーブがなければ、最後に遊んだマップはない")
	SaveGame.write(path_a, {"has_rested": true})
	SaveGame.write(path_b, {"has_rested": true})
	check(SaveGame.current_area() == "exit-b", "最後に保存した世界が、最後に遊んだマップ")
	var title: Node = load("res://scenes/title.tscn").instantiate()
	var settings_t := GameSettings.new()
	title.settings = settings_t
	title.auto_change_scene = false
	title.world_path = path_a
	root.add_child(title)
	await process_frame
	check(title.default_path == path_a and title.resolved_path == path_b, "つづきから は、最後に遊んだマップ (B)。始まりの世界は、A のまま")
	check(title.has_save, "セーブがあるので、「つづきから」が出る")
	title._new_game()
	await title._new_game()
	check(title.resolved_path == path_a, "はじめからは、始まりの世界 (A) から")
	title.queue_free()
	await process_frame
	SaveGame.delete()
	SaveGame.allow_headless = false

	for sub in ["/saves", ""]:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DIR + sub)):
			continue
		for file in DirAccess.get_files_at(DIR + sub):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + sub + "/" + file))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + sub))
	quit(1 if failures.size() > 0 else 0)
