extends SceneTree

# 実行: godot --headless --path game --script res://tests/region_test.gd
# 地域 (同じ region のマップを、まとめて読み込んで、並べる): 並び方、タイルの間を歩いて渡る (暗転も移動もない)、
# タイルごとの篝火と記録、関所 (地域の外の隣)、続きから、を確かめる。
# サンプルの世界の写しを使う。A と B は、東西に隣り合う同じ地域。X は、A の西にある別の地域。先に godot --headless --path game --import --quit しておく

const SAMPLE := "res://assets/sample_world.glb"
const DIR := "user://test_region"
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


func _survey_of(local: Vector3, origin: Vector3) -> Array:
	return [local.x + origin.x, -local.z + origin.y, local.y + origin.z]


func _make_world(name: String, label: String, origin: Vector3, size: Vector3, region: String, bonfire: Variant, dir := DIR) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var world := "%s/%s.glb" % [dir, name]
	var file := FileAccess.open(world, FileAccess.WRITE)
	file.store_buffer(FileAccess.get_file_as_bytes(SAMPLE))
	file.close()
	var sidecar := {"world_id": "reg-" + name, "name": label, "origin": [origin.x, origin.y, origin.z], "size": [size.x, size.y, size.z]}
	if region != "":
		sidecar["region"] = region
	if bonfire != null:
		sidecar["bonfire"] = _survey_of(bonfire, origin)
	_write("%s/%s.json" % [dir, name], JSON.stringify(sidecar))
	return world


func _start(path: String, with_save := false) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = path
	scene.get_node("World").save_enabled = with_save
	scene.get_node("World").auto_change_scene = false
	root.add_child(scene)
	return scene


# 地域の残りのタイルを、全て読み込み終えるまで待つ (歩きながら、1 つずつ読み込まれる)
func _wait_loaded(scene: Node) -> void:
	var world: Node = scene.get_node("World")
	var waited := 0.0
	while not world.is_region_loaded() and waited < 20.0:
		await create_timer(0.1).timeout
		waited += 0.1


func _initialize() -> void:
	var loaded: Dictionary = WorldLoader.load_world(SAMPLE)
	root.add_child(loaded.node)
	await process_frame
	var meshes: Array = loaded.node.find_children("*", "MeshInstance3D", true, false)
	var box := AABB()
	for i in meshes.size():
		var b: AABB = meshes[i].global_transform * meshes[i].get_aabb()
		box = b if i == 0 else box.merge(b)
	var ground := WorldLoader.pick_start(meshes, Vector3(10.0, 0.0, -10.0))
	loaded.node.free()
	var size := box.size

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	# A (始める世界)、B (A の東に、隙間なく。起伏の標高の原点が、少し違う)、X (A の西。別の地域)
	var origin_b := ORIGIN + Vector3(size.x, 0.0, 0.0)
	var path_a := _make_world("a", "西の台地", ORIGIN, size, "test-region", ground)
	var path_b := _make_world("b", "東の台地", origin_b + Vector3(0.0, 0.0, 3.0), size, "test-region", ground)
	var path_x := _make_world("x", "外の地", ORIGIN - Vector3(size.x, 0.0, 0.0), size, "other-region", null)
	var path_h := _make_world("high", "高い所", ORIGIN, size, "low-region", ground)
	var path_l := _make_world("low", "低い所", ORIGIN + Vector3(size.x, 0.0, -100.0), size, "low-region", ground)
	WorldLoader.arrival = {}

	var entries := WorldRegistry.scan(DIR)
	check(entries.size() == 5 and entries.filter(func(e: Dictionary) -> bool: return e.region == "test-region").size() == 2, "一覧に、地域の名前 (region) が入る")

	# 始める: A と、同じ地域の B が、並んで読み込まれる (X は、別の地域なので、読み込まれない)
	var scene := _start(path_a)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene)
	var world: Node = scene.get_node("World")
	var player: CharacterBody3D = scene.get_node("Player")
	check(world._tiles.size() == 2 and world._tiles[0].entry.world_id == "reg-a" and world._tiles[1].entry.world_id == "reg-b", "同じ地域の 2 つのタイルを、まとめて読み込む。別の地域は、読み込まない")
	var offset_b: Vector3 = world._tiles[1].offset
	check(is_equal_approx(offset_b.x, size.x) and is_equal_approx(offset_b.y, 3.0) and is_equal_approx(offset_b.z, 0.0), "B は、A の東に、測量座標の位置に並ぶ (東へ幅、高さは、B の原点の標高が 3 m 高い分): %s" % [offset_b])
	check(world.find_children("*", "PointWorld", false, false).size() == 2, "タイルごとに、点の表現がある")
	var glitch_layers := 0
	for n in world.find_children("GlitchLayer", "CanvasLayer", true, false):
		glitch_layers += 1
	check(glitch_layers == 1, "画面全体のノイズの層は、1 つだけ (重ねない): %d" % glitch_layers)
	var fires := get_nodes_in_group("bonfire")
	check(fires.size() == 2, "篝火は、タイルごとに 1 つ")
	var fire_b: Node3D = scene.find_child("AreaBonfire_b", true, false)
	check(fire_b != null and fire_b.global_position.is_equal_approx(ground + offset_b) and fire_b.display_name() == "東の台地の篝火", "B の篝火は、B の座標の場所を、並んだ位置に置く。名前もつく")
	check(world._entry.world_id == "reg-a" and world._exits.keys() == ["west"] and world._exits.west.world_id == "reg-x", "A の関所は、別の地域の X だけ (西)。B は、同じ地域なので、関所ではない")

	# B の中へ歩いて渡る: 暗転も、移動もない。関所は、B のものに変わる (B の端に、別の地域はない)
	await create_timer(1.7).timeout
	var traveled := []
	world.traveled.connect(func(path: String) -> void: traveled.append(path))
	player.global_position = Vector3(size.x + 5.0, ground.y + offset_b.y + 2.0, -size.z / 2.0)
	for i in 30:
		await physics_frame
	check(world._entry.world_id == "reg-b" and world._exits.is_empty(), "B に入る。B の関所はない (A は、同じ地域)")
	for i in 60:
		await physics_frame
	check(traveled.is_empty() and WorldLoader.arrival.is_empty() and (world._veil == null or world._veil.modulate.a < 0.01), "地域の中は、暗転も、移動もしない")
	check(player.is_on_floor(), "B の地面に立てる (継ぎ目で落ちない)")
	player.global_position = Vector3(5.0, ground.y + 2.0, -size.z / 2.0)
	for i in 30:
		await physics_frame
	check(world._entry.world_id == "reg-a" and world._exits.has("west"), "A へ戻ると、関所は、また西の X")

	# 継ぎ目の線の上 (A と B の、両方の範囲): いまのタイル (B) のまま、A に切り替わらない
	player.global_position = Vector3(size.x + 5.0, ground.y + offset_b.y + 2.0, -size.z / 2.0)
	for i in 30:
		await physics_frame
	player.global_position = Vector3(size.x, ground.y + offset_b.y + 2.0, -size.z / 2.0)
	for i in 10:
		await physics_frame
	check(world._entry.world_id == "reg-b", "継ぎ目の線の上でも、いまのタイルのまま (A に、切り替わらない)")
	player.global_position = Vector3(5.0, ground.y + 2.0, -size.z / 2.0)
	for i in 30:
		await physics_frame

	# A の西の端 = 関所: 別の地域へ移る (暗転する)
	player.global_position = Vector3(1.0, ground.y + 2.0, -size.z / 2.0)
	for i in 20:
		await physics_frame
	await create_timer(0.6).timeout
	check(WorldLoader.arrival.get("path") == path_x, "関所を越えると、別の地域 (X) へ移る")
	scene.queue_free()
	await process_frame
	WorldLoader.arrival = {}

	# タイルごとの記録: B の篝火で休むと、B の記録ができる (A も、遊んだので、記録がある)。最後に遊んだのは B
	SaveGame.directory = DIR + "/saves"
	SaveGame.allow_headless = true
	SaveGame.delete()
	var scene2 := _start(path_a, true)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene2)
	var world2: Node = scene2.get_node("World")
	var player2: CharacterBody3D = scene2.get_node("Player")
	var b_fire: Node3D = scene2.find_child("AreaBonfire_b", true, false)
	player2.global_position = b_fire.global_position + Vector3(0.5, 0.5, 0.0)
	for i in 10:
		await physics_frame
	player2._update_nearby_bonfire()
	player2.rest()
	check(player2.message.text == "「東の台地の篝火」に火を灯した" and b_fire.lit, "B の篝火で、初めて休むと、その篝火の名前で「火を灯した」")
	var a_fire: Node3D = scene2.find_child("AreaBonfire", true, false)
	check(not a_fire.lit, "A の篝火は、まだ灯っていない (篝火ごとの状態)")
	var record_b := SaveGame.read(path_b)
	var record_a := SaveGame.read(path_a)
	check(record_b.status == "ok" and record_b.state.has_rested and SaveGame.decode_vector(record_b.state.spawn).is_equal_approx(b_fire.rest_position() - world2._tiles[1].offset), "B の記録に、最後に休んだ位置 (B の座標) が入る")
	check(record_a.status == "ok" and not record_a.state.has_rested, "A も、遊んだので、記録がある (休んでいない)")
	check(SaveGame.current_area() == "reg-b", "最後に遊んだエリアは、B")
	player2.rest()
	check(player2.message.text == "「東の台地の篝火」で休んだ", "同じ篝火で、2 度目に休むと「休んだ」")
	scene2.queue_free()
	await process_frame
	await process_frame

	# 始まりの篝火 (.json に bonfire がないマップ) も、火が灯ったまま、続きから始まる
	var plain := _start(SAMPLE, true)
	for i in 40:
		await physics_frame
	var plain_fire: Node3D = plain.find_child("StartBonfire", true, false)
	var plain_player: CharacterBody3D = plain.get_node("Player")
	plain_player.global_position = plain_fire.global_position + Vector3(0.5, 0.5, 0.0)
	for i in 10:
		await physics_frame
	plain_player._update_nearby_bonfire()
	plain_player.rest()
	check(plain_fire.lit, "始まりの篝火で休むと、火が灯る")
	plain.queue_free()
	await process_frame
	await process_frame
	var plain2 := _start(SAMPLE, true)
	for i in 40:
		await physics_frame
	check(plain2.find_child("StartBonfire", true, false).lit, "続きから始めても、始まりの篝火の火は、灯ったまま (初めて休む知らせを、繰り返さない)")
	plain2.queue_free()
	await process_frame
	await process_frame

	# 続きから (A を始める世界にして始める): B の篝火の火は、灯ったまま。B の確かめた所も戻る
	var scene3 := _start(path_a, true)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene3)
	var b_fire3: Node3D = scene3.find_child("AreaBonfire_b", true, false)
	check(b_fire3.lit and not scene3.find_child("AreaBonfire", true, false).lit, "続きから: B の篝火は、灯ったまま。A の篝火は、灯っていない")
	scene3.queue_free()
	await process_frame
	await process_frame

	# B を始める世界にして始める (最後に遊んだタイルから、続きから): B が原点。A は、西に並ぶ。B の最後に休んだ位置から始まる
	var scene4 := _start(path_b, true)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene4)
	var world4: Node = scene4.get_node("World")
	var player4: CharacterBody3D = scene4.get_node("Player")
	var a_offset: Vector3 = world4._tiles[1].offset
	check(world4._tiles[0].entry.world_id == "reg-b" and is_equal_approx(a_offset.x, -size.x) and is_equal_approx(a_offset.y, -3.0), "B を始める世界にすると、B が原点で、A は、その西に並ぶ: %s" % [a_offset])
	check(player4.has_rested and Vector2(player4.global_position.x - (ground.x + 0.0), player4.global_position.z - (ground.z + 1.5)).length() < 1.0, "B の、最後に休んだ篝火から始まる: %s" % [player4.global_position])
	scene4.queue_free()
	await process_frame

	# 隣のタイルの古い (バージョン 1) セーブを取り込めない (書き込みに失敗する): 保存せずに遊ぶ。古い進行を、置き換えない
	SaveGame.delete()
	var legacy_path := "%s/reg-b.json" % (DIR + "/saves")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR + "/saves"))
	_write(legacy_path, JSON.stringify({"version": 1, "world_id": "reg-b", "saved_at": "2026-11-22T07:42:00", "has_rested": true, "spawn": [5.0, 6.0, 7.0]}))
	SaveGame.fail_writes = true
	var scene_u := _start(path_a, true)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene_u)
	SaveGame.fail_writes = false
	var player_u: CharacterBody3D = scene_u.get_node("Player")
	var fire_u: Node3D = scene_u.find_child("AreaBonfire_b", true, false)
	player_u.global_position = fire_u.global_position + Vector3(0.5, 0.5, 0.0)
	for i in 10:
		await physics_frame
	player_u._update_nearby_bonfire()
	player_u.rest()
	check(not scene_u.get_node("World")._save_active and not FileAccess.file_exists(SaveGame.path_for()) and FileAccess.file_exists(legacy_path), "隣のタイルの古いセーブを取り込めなかった間は、保存しない (古いセーブは、そのまま残る)")
	scene_u.queue_free()
	await process_frame
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	SaveGame.delete()

	SaveGame.delete()
	SaveGame.allow_headless = false

	# 標高の低いタイル (原点の標高が 100 m 低い): 歩いて降りても、位置を見失わない。落ちたと見なす高さは、地域でいちばん低い地面の下
	var scene_l := _start(path_h)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene_l)
	var world_l: Node = scene_l.get_node("World")
	var player_l: CharacterBody3D = scene_l.get_node("Player")
	var low_offset: Vector3 = world_l._tiles[1].offset
	check(low_offset.y < -90.0, "(準備) 低いタイルは、始める世界から見て、100 m 近く下に並ぶ (原点が低い分): %s" % [low_offset])
	check(player_l.fall_limit < low_offset.y, "落ちたと見なす高さは、地域でいちばん低い地面の下に決まる (既定の -20 のままでは、低いタイルへ降りただけで、位置を見失う): %s" % [player_l.fall_limit])
	player_l.global_position = Vector3(size.x + 5.0, ground.y + low_offset.y + 2.0, -size.z / 2.0)
	for i in 120:
		await physics_frame
	check(not player_l.rescanning and player_l.is_on_floor() and player_l.global_position.x > size.x and player_l.global_position.y < -50.0, "高さが 100 m 近く違うタイルへ歩いても、位置を見失わず (篝火へ戻されず)、そのタイルの床に立てる: %s" % [player_l.global_position])
	scene_l.queue_free()
	await process_frame

	# 読み込みは、歩きながら: 始める世界だけが先に読み込まれ、残りは、あとから 1 つずつ。読み込み中の隣は、関所ではない
	SaveGame.directory = DIR + "/saves"
	SaveGame.allow_headless = true
	SaveGame.delete()
	var scene_t: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings_t := GameSettings.new()
	settings_t.weather_enabled = false
	scene_t.get_node("DayNight").settings = settings_t
	scene_t.get_node("World").world_path = path_h
	scene_t.get_node("World").save_enabled = true
	scene_t.get_node("World").auto_change_scene = false
	var loaded_names := []
	var region_done := [false]
	scene_t.get_node("World").tile_loaded.connect(func(tile_name: String) -> void: loaded_names.append(tile_name))
	scene_t.get_node("World").region_loaded.connect(func() -> void: region_done[0] = true)
	root.add_child(scene_t)
	await physics_frame
	var world_t: Node = scene_t.get_node("World")
	var limit_before: float = scene_t.get_node("Player").fall_limit
	check(world_t._tiles.size() == 1 and not world_t.is_region_loaded() and loaded_names.is_empty(), "始めた直後は、始める世界のタイルだけが読み込まれている (残りは、あとから)")
	check(world_t._exits.get("east", {}).get("world_id", "") != "reg-low", "読み込み中の隣 (同じ地域) は、関所ではない")
	await _wait_loaded(scene_t)
	check(world_t._tiles.size() == 2 and world_t.is_region_loaded() and region_done[0] and loaded_names == ["低い所"], "残りのタイルが、あとから読み込まれ、通知される: %s" % [loaded_names])
	check(scene_t.get_node("Player").fall_limit < limit_before - 50.0, "あとから読み込んだ低いタイルに合わせて、落ちたと見なす高さが、決め直される (%s → %s)" % [limit_before, scene_t.get_node("Player").fall_limit])

	# 当たり判定ができるまで、読み込み中のタイルへは入れない (入ると、床がなく、落ちる)。できたら、入れる
	var player_g: CharacterBody3D = scene_t.get_node("Player")
	check(world_t._unready.is_empty(), "(準備) 読み込み済み: 入れない範囲は、もうない")
	scene_t.queue_free()
	await process_frame
	var scene_g := _start(path_h)
	await physics_frame
	var world_g: Node = scene_g.get_node("World")
	var player_gate: CharacterBody3D = scene_g.get_node("Player")
	var before_x: float = player_gate.global_position.x
	player_gate.global_position = Vector3(size.x + 5.0, 3.0, -size.z / 2.0)  # まだ読み込み中の、東のタイルの中
	for i in 6:
		await physics_frame
	check(world_g._tiles.size() == 1 and player_gate.global_position.x <= size.x and not player_gate.rescanning, "読み込み中のタイルへは、入れない (戻される): x = %.1f" % player_gate.global_position.x)
	await _wait_loaded(scene_g)
	player_gate.global_position = Vector3(size.x + 5.0, ground.y + world_g._tiles[1].offset.y + 2.0, -size.z / 2.0)
	for i in 6:
		await physics_frame
	check(world_g._tiles.size() == 2 and player_gate.global_position.x > size.x, "読み込みが終わったら、入れる")
	scene_g.queue_free()
	await process_frame
	scene_t = _start(path_h, true)  # 以降の確認のために、保存ありで始め直す
	await _wait_loaded(scene_t)
	world_t = scene_t.get_node("World")

	# 保存: 変わっていないタイルの探索地図は、PNG にし直さない (前回のものを使い回す)。遊んだタイルだけが、保存される
	var low_tile: Dictionary = world_t._tiles[1]
	var player_t: CharacterBody3D = scene_t.get_node("Player")
	var home_spot := player_t.global_position
	player_t.global_position = Vector3(size.x + 10.0, ground.y + low_tile.offset.y + 2.0, -size.z / 2.0)  # 低いタイルへ入る
	await create_timer(1.0).timeout
	check(world_t._entry.world_id == "reg-low" and low_tile.visited, "低いタイルに入ると、遊んだ印が付く")
	player_t.global_position = home_spot + Vector3(0.0, 1.0, 0.0)  # 戻る (低いタイルの探索は、もう変わらない)
	await create_timer(1.0).timeout
	world_t.save_now()
	var encoded_first: int = low_tile.encoded
	await create_timer(0.3).timeout
	world_t.save_now()
	check(encoded_first >= 1 and low_tile.encoded == encoded_first, "遠くの、変わっていないタイルは、次の保存で、探索地図を作り直さない (%d 回)" % low_tile.encoded)
	check(SaveGame.read(path_l).status == "ok" and SaveGame.read(path_h).status == "ok", "遊んだ 2 つのタイルとも、保存されている")
	var home_encoded: int = world_t._tiles[0].encoded
	player_t.global_position += Vector3(8.0, 0.0, 0.0)
	await create_timer(0.3).timeout
	world_t.save_now()
	check(world_t._tiles[0].encoded > home_encoded, "いまいるタイルは、探索地図が変わったので、書き直される")
	scene_t.queue_free()
	await process_frame
	SaveGame.delete()
	SaveGame.allow_headless = false

	# 読み込めなかったタイル (同じ地域): 歩いて渡れる予定から外れ、その端は、関所に戻る
	var fail_path := _make_world("f1", "読めるタイル", ORIGIN, size, "fail-region", ground, DIR + "/fail")
	_make_world("f2", "読めないタイル", ORIGIN + Vector3(size.x, 0.0, 0.0), size, "fail-region", null, DIR + "/fail")
	_write(DIR + "/fail/f2.glb", "これは GLB ではありません")  # 一覧には載るが、読み込めない
	var scene_f := _start(fail_path)
	await _wait_loaded(scene_f)
	var world_f: Node = scene_f.get_node("World")
	check(world_f._tiles.size() == 1 and world_f._exits.get("east", {}).get("world_id", "") == "reg-f2", "読み込めなかった同じ地域のタイルの方向は、関所に戻る (空白のまま、残さない)")
	scene_f.queue_free()
	await process_frame

	# 篝火の場所がないタイルにも、代わりの篝火が置かれる (始める世界以外でも。歩いて入った先で、休める)
	var path_n1 := _make_world("n1", "無印その 1", ORIGIN, size, "plain-region", null)
	_make_world("n2", "無印その 2", ORIGIN + Vector3(size.x, 0.0, 0.0), size, "plain-region", null)
	var scene_n := _start(path_n1)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene_n)
	var near_fire: Node3D = scene_n.find_child("StartBonfire_n2", true, false)
	check(scene_n.find_child("StartBonfire", true, false) != null and near_fire != null and scene_n.get_node("World")._tiles[1].fire == near_fire, "篝火の場所がない、始める世界以外のタイルにも、代わりの篝火が置かれる")
	check(near_fire != null and near_fire.global_position.x > size.x and near_fire.global_position.x < 2.0 * size.x, "代わりの篝火は、そのタイルの中にある: %s" % [near_fire.global_position if near_fire != null else null])
	scene_n.queue_free()
	await process_frame

	# 地域のタイルが、読み込みの上限で外れた時: 外れた隣へは、関所で移る
	var scene_m := _start("")
	scene_m.queue_free()
	await process_frame
	var scene_c: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings_c := GameSettings.new()
	settings_c.weather_enabled = false
	scene_c.get_node("DayNight").settings = settings_c
	scene_c.get_node("World").world_path = path_a
	scene_c.get_node("World").save_enabled = false
	scene_c.get_node("World").auto_change_scene = false
	scene_c.get_node("World").max_tiles = 1  # B は、読み込まれない
	root.add_child(scene_c)
	for i in 40:
		await physics_frame
	var world_c: Node = scene_c.get_node("World")
	check(world_c._tiles.size() == 1 and world_c._exits.has("east") and world_c._exits.east.world_id == "reg-b" and world_c._exits.has("west"), "読み込みの上限で外れた同じ地域の隣 (B) も、関所になる (東)。別の地域 (X) は、西")
	scene_c.queue_free()
	await process_frame

	for sub in ["/saves", "/fail", ""]:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DIR + sub)):
			continue
		for file in DirAccess.get_files_at(DIR + sub):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + sub + "/" + file))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + sub))
	quit(1 if failures.size() > 0 else 0)
