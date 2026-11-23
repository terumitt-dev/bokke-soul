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


func _start_world(path: String, with_save := false) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = path
	scene.get_node("World").save_enabled = with_save  # 既定では、セーブしない。使う時は、専用の置き場 (SaveGame.directory) に向ける
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
	check(Vector2(world_b._setup_points_position.x - 6.0, world_b._setup_points_position.z + size.z / 2.0).length() < 0.5, "探索地図は、着く位置を、プレイヤーの位置として作られる (いつもの始まりの位置の周りを、探索済みにしない): %s" % [world_b._setup_points_position])
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

	# 探索地図が保存済みのマップへ、移ってくる: 戻した地図に、着いた所は、ない。着いた所の周りを、探索済みにする
	SaveGame.directory = DIR + "/saves"
	SaveGame.allow_headless = true
	SaveGame.delete()
	var blank := RevealMap.new(box)
	check(SaveGame.write(path_b, {"has_rested": false, "reveal_png": SaveGame.encode_bytes(blank.to_png())}), "(準備) 何も探索していない地図を、B の記録として保存する")
	WorldLoader.arrival = {"path": path_b, "position": Vector3(6.0, 5.0, -size.z / 2.0), "yaw": 0.0, "pitch": 0.0}
	var scene_r := _start_world("", true)
	for i in 30:
		await physics_frame
	var points_r: PointWorld = scene_r.get_node("World").find_children("*", "PointWorld", false, false)[0]
	var landed: Vector3 = scene_r.get_node("Player").global_position
	check(points_r.reveal.sample(Vector3(landed.x, 0.0, landed.z)) > 0.5, "保存した地図を戻したあとでも、着いた所の周りは、探索済み (%.2f)" % points_r.reveal.sample(Vector3(landed.x, 0.0, landed.z)))
	scene_r.queue_free()
	await process_frame
	WorldLoader.arrival = {}
	SaveGame.delete()
	SaveGame.allow_headless = false

	# 引き継ぎの位置が不正 (Vector3 でない): 無視して、いつも通り始まる
	WorldLoader.arrival = {"path": path_b, "position": "どこか"}
	var scene_bad := _start_world("")
	for i in 20:
		await physics_frame
	check(scene_bad.get_node("World")._path == path_b and scene_bad.get_node("Player").global_position.y > -50.0, "引き継ぎの位置が不正でも、そのマップで、いつも通り始まる")
	scene_bad.queue_free()
	await process_frame
	WorldLoader.arrival = {}

	# 着く所に面がない (地形の穴や、範囲の外): 一番近い地面へ寄せる (穴の上に立たない)
	WorldLoader.arrival = {"path": path_b, "position": Vector3(size.x + 500.0, 5.0, 500.0), "yaw": 0.0, "pitch": 0.0}
	var scene_hole := _start_world("")
	for i in 30:
		await physics_frame
	var hole_pos: Vector3 = scene_hole.get_node("Player").global_position
	check(hole_pos.x >= 0.0 and hole_pos.x <= size.x and hole_pos.z <= 0.0 and hole_pos.z >= -size.z, "着く所に面がなければ、一番近い地面へ寄せる (世界の中): %s" % [hole_pos])
	check(scene_hole.get_node("Player").spawn_position.x >= 0.0 and scene_hole.get_node("Player").spawn_position.x <= size.x, "復帰地点も、地面のある所")
	scene_hole.queue_free()
	await process_frame

	# 保存に失敗したら、移らない。書けるようになれば、しばらくしてから移る。最後に遊んだエリアは、行き先
	SaveGame.directory = DIR + "/saves"
	SaveGame.allow_headless = true
	SaveGame.delete()
	WorldLoader.arrival = {}
	var scene_s := _start_world(path_a, true)
	for i in 30:
		await physics_frame
	var world_s: Node = scene_s.get_node("World")
	var player_s: CharacterBody3D = scene_s.get_node("Player")
	await create_timer(1.7).timeout
	SaveGame.fail_writes = true
	player_s.global_position = Vector3(size.x - 1.0, 3.0, -size.z / 2.0)
	for i in 20:
		await physics_frame
	await create_timer(0.6).timeout
	check(WorldLoader.arrival.is_empty() and not world_s._traveling, "保存に失敗したら、移らない (いまのマップの探索を、失わない)")
	SaveGame.fail_writes = false
	await create_timer(3.4).timeout  # もう一度試すまでの時間
	player_s.global_position = Vector3(size.x - 1.0, 3.0, -size.z / 2.0)
	for i in 20:
		await physics_frame
	await create_timer(0.6).timeout
	check(WorldLoader.arrival.get("path") == path_b, "書けるようになれば、移る")
	check(SaveGame.current_area() == "exit-b", "移る時に、最後に遊んだエリアは、行き先になる (着いてから、保存しないまま終わっても、行き先から始まる)")
	scene_s.queue_free()
	await process_frame
	WorldLoader.arrival = {}
	SaveGame.delete()
	SaveGame.allow_headless = false

	# 続きから: 最後に遊んだマップから始まる。はじめから: 始まりの世界から
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

	# 移った先で、保存する前に終わった (最後に遊んだエリアは B、記録があるのは A だけ): 「つづきから」と「はじめから」が出る
	SaveGame.delete()
	SaveGame.write(path_a, {"has_rested": true})
	SaveGame.set_current_area(path_b)
	check(SaveGame.has_any() and SaveGame.read(path_b).status == "none", "(準備) 記録があるのは A だけ。最後に遊んだのは B")
	var title2: Node = load("res://scenes/title.tscn").instantiate()
	title2.settings = GameSettings.new()
	title2.auto_change_scene = false
	title2.world_path = path_a
	root.add_child(title2)
	await process_frame
	var newer_file := FileAccess.open(SaveGame.path_for(), FileAccess.WRITE)
	newer_file.store_string(JSON.stringify({"version": SaveGame.VERSION + 1, "areas": {"x": {}}}))
	newer_file.close()
	check(not SaveGame.has_any(), "新しいバージョンのセーブは、「記録がある」とは扱わない (読まず、消しもしない)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGame.path_for()))  # 新しいバージョンのセーブは、SaveGame.delete では消えない。直接消す
	SaveGame.write(path_a, {"has_rested": true})
	SaveGame.set_current_area(path_b)
	check(title2.resolved_path == path_b and title2.has_save and title2.new_game_button.visible and title2.start_button.text == "つづきから", "記録のないマップが再開先でも、「つづきから」と「はじめから」が出る (進行を、消して始め直せる)")
	title2.queue_free()
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
