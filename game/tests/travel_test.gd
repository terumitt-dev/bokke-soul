extends SceneTree

# 実行: godot --headless --path game --script res://tests/travel_test.gd
# 篝火の移動を確かめる: 火を灯した篝火の近くで、移動の操作をすると、行き先の一覧が開く。選ぶと、同じ地域の篝火へは暗転して移り、
# 別の地域の篝火へは、場面の切り替え (引き継ぎ) で移る。移るだけで、復帰地点は変えない。
# A と B は、東西に隣り合う同じ地域。X は、A の西にある別の地域。サンプルの世界の写しを使う。先に godot --headless --path game --import --quit しておく

const SAMPLE := "res://assets/sample_world.glb"
const DIR := "user://test_travel"
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


func _make_world(name: String, label: String, origin: Vector3, size: Vector3, region: String, bonfire: Vector3) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var world := "%s/%s.glb" % [DIR, name]
	var file := FileAccess.open(world, FileAccess.WRITE)
	file.store_buffer(FileAccess.get_file_as_bytes(SAMPLE))
	file.close()
	_write("%s/%s.json" % [DIR, name], JSON.stringify({
		"world_id": "trv-" + name, "name": label, "region": region,
		"origin": [origin.x, origin.y, origin.z], "size": [size.x, size.y, size.z],
		"bonfire": [bonfire.x + origin.x, -bonfire.z + origin.y, bonfire.y + origin.z],
	}))
	return world


func _action(name: String, pressed := true) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = name
	event.pressed = pressed
	return event


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

	var path_a := _make_world("a", "西の台地", ORIGIN, size, "trv-region", ground)
	_make_world("b", "東の台地", ORIGIN + Vector3(size.x, 0.0, 0.0), size, "trv-region", ground)
	var path_x := _make_world("x", "外の地", ORIGIN - Vector3(size.x, 0.0, 0.0), size, "trv-other", ground)
	SaveGame.directory = DIR + "/saves"
	SaveGame.allow_headless = true
	SaveGame.delete()
	WorldLoader.arrival = {}
	# X の篝火は、前に火を灯した (セーブに記録がある)。復帰位置は、X の座標
	var x_spawn := ground + Bonfire.REST_OFFSET
	var x_origin := ORIGIN - Vector3(size.x, 0.0, 0.0)
	SaveGame.write(path_x, {"has_rested": true, "spawn": SaveGame.encode_vector(x_spawn), "origin": SaveGame.encode_vector(x_origin)})
	check(SaveGame.lit_areas().size() == 1 and SaveGame.lit_areas().has("trv-x") and SaveGame.lit_areas()["trv-x"].is_equal_approx(x_spawn), "(準備) セーブから、火を灯したエリアと、その復帰位置が分かる")

	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = path_a
	scene.get_node("World").save_enabled = true
	scene.get_node("World").auto_change_scene = false
	root.add_child(scene)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene)
	var world: Node = scene.get_node("World")
	var player: CharacterBody3D = scene.get_node("Player")
	var fire_a: Node3D = scene.find_child("AreaBonfire", true, false)
	var fire_b: Node3D = scene.find_child("AreaBonfire_b", true, false)
	var traveled := []
	world.traveled.connect(func(path: String) -> void: traveled.append(path))

	# 火が灯っていない篝火では、移動の一覧は開かない
	player.global_position = fire_a.global_position + Vector3(0.5, 0.5, 0.0)
	for i in 10:
		await physics_frame
	player._unhandled_input(_action("travel"))
	check(world._menu == null and not player.input_blocked, "火が灯っていない篝火では、移動の一覧は開かない")
	check(player.prompt.text == "E: 休む", "案内は、休むだけ: %s" % player.prompt.text)

	# 休んで火を灯す: 案内に、移動も出る。行き先は、前に火を灯した X (別の地域) だけ (B は、まだ灯っていない)
	player.rest()
	for i in 10:
		await physics_frame
	check(player.prompt.text == "E: 休む    F: 移動する", "火を灯した篝火では、案内に、移動も出る: %s" % player.prompt.text)
	player._unhandled_input(_action("travel"))
	check(world._menu != null and world._menu.is_open() and player.input_blocked, "移動の操作で、一覧が開く。そのあいだ、プレイヤーの操作は止まる")
	check(world._menu_destinations.size() == 1 and world._menu_destinations[0].label == "外の地の篝火", "行き先は、火を灯した X だけ (B は、まだ灯っていない): %s" % [world._menu_destinations.map(func(d: Dictionary) -> String: return d.label)])
	check(world._menu.buttons.size() == 2, "一覧には、行き先と、「やめる」が並ぶ")
	player.velocity = Vector3(5.0, 0.0, 5.0)
	for i in 5:
		await physics_frame
	check(is_zero_approx(player.velocity.x) and is_zero_approx(player.velocity.z), "一覧を開いている間は、動けない")
	world._menu._unhandled_input(_action("ui_cancel"))
	await process_frame
	check(not player.input_blocked and not world._menu_destinations.is_empty(), "取り消しで、一覧が閉じ、操作が戻る")
	await process_frame
	player._unhandled_input(_action("travel"))
	check(is_instance_valid(world._menu) and world._menu.is_open() and player.input_blocked, "閉じたあとも、もう一度、一覧を開ける (解放済みの一覧を触らない)")
	world._menu._unhandled_input(_action("ui_cancel"))
	await process_frame
	# マウスを握っていた状態は、一覧を閉じると、元に戻る (握っていなければ、握らないまま)
	player.mouse_captured = true
	player._unhandled_input(_action("travel"))
	player.mouse_captured = false  # 一覧を開いている間に、ウィンドウの外へ出て、印が下りた時 (player.gd の focus-out と同じ)
	world._menu._unhandled_input(_action("ui_cancel"))
	await process_frame
	check(player.mouse_captured, "マウスを握っていた時は、一覧を閉じると、握った状態に戻る (開いている間に印が下りても)")
	player.mouse_captured = false
	player._unhandled_input(_action("travel"))
	world._menu._unhandled_input(_action("ui_cancel"))
	await process_frame
	check(not player.mouse_captured, "マウスを握っていなかった時は、一覧を閉じても、握らない")
	# 一覧を開いている間に倒れたら、一覧は閉じる。行き先を選んでも、移らない
	player.mouse_captured = true
	player._unhandled_input(_action("travel"))
	var open_menu: TravelMenu = world._menu
	player.take_damage(1000.0)
	await process_frame
	check(player.dead and (not is_instance_valid(open_menu) or not open_menu.is_open()) and world._menu == null, "一覧を開いている間に倒れたら、一覧は閉じる")
	check(not player.input_blocked and player.mouse_captured, "倒れて一覧が閉じても、操作の止まりと、マウスの印は、元に戻る")
	world._on_travel_chosen(0)
	check(world._traveling == false and world._path == path_a, "倒れている間は、行き先を選んでも、移らない")
	await create_timer(float(player.DEATH_SECONDS) + float(player.RESCAN_SECONDS) + 0.8).timeout
	check(not player.dead, "復活すると、また動ける")

	# B の篝火にも火を灯して、A に戻って休む (復帰地点は、A)
	player.global_position = fire_b.global_position + Vector3(0.5, 0.5, 0.0)
	for i in 10:
		await physics_frame
	player.rest()
	player.global_position = fire_a.global_position + Vector3(0.5, 0.5, 0.0)
	for i in 10:
		await physics_frame
	player.rest()
	var spawn_before: Vector3 = player.spawn_position
	check(spawn_before.is_equal_approx(fire_a.rest_position()), "(準備) 最後に休んだのは A の篝火")
	await create_timer(0.3).timeout

	# 同じ地域の篝火 (B) へ: 暗転して、その篝火のそばへ。復帰地点は、変わらない
	player._unhandled_input(_action("travel"))
	var labels: Array = world._menu_destinations.map(func(d: Dictionary) -> String: return d.label)
	check(labels == ["東の台地の篝火", "外の地の篝火"], "行き先は、火を灯した B と X: %s" % [labels])
	world._menu.buttons[0].pressed.emit()
	await create_timer(0.2).timeout  # 暗転の途中
	check(world._traveling and player.immune and not player.take_damage(1000.0) and not player.dead, "移動の暗転中は、ダメージを受けない (倒れて、復活の処理を迂回しない)")
	await create_timer(0.9).timeout  # 暗転 (0.4 秒) と、戻り (0.4 秒)
	check(not player.immune, "着いたら、またダメージを受ける")
	var distance := Vector2(player.global_position.x - fire_b.global_position.x, player.global_position.z - fire_b.global_position.z).length()
	check(distance < 3.0 and world._entry.world_id == "trv-b", "同じ地域の篝火へ移る。B の篝火のそばに立つ (距離 %.1f)" % distance)
	check(player.spawn_position.is_equal_approx(spawn_before), "移るだけで、復帰地点は、変わらない")
	check(traveled.is_empty() and WorldLoader.arrival.is_empty(), "同じ地域の中は、場面を切り替えない")
	check(world._veil.modulate.a < 0.01 and not world._traveling, "暗転は、戻っている (veil=%.2f、移動中=%s)" % [world._veil.modulate.a, world._traveling])

	# 別の地域の篝火 (X) へ: 場面を切り替える引き継ぎ。着く位置は、X の復帰位置のそば。最後に遊んだエリアは、X
	for i in 40:
		await physics_frame
	player._unhandled_input(_action("travel"))
	check(world._menu != null and world._menu.is_open(), "B の篝火でも、一覧が開く")
	var x_index := -1
	for i in world._menu_destinations.size():
		if world._menu_destinations[i].entry.world_id == "trv-x":
			x_index = i
	world._menu.buttons[x_index].pressed.emit()
	await create_timer(0.8).timeout
	var carried: Dictionary = WorldLoader.arrival
	check(carried.get("path") == path_x and traveled == [path_x], "別の地域の篝火へは、その地域のマップへ、場面を切り替えて移る")
	check(carried.get("at_bonfire", false) and not carried.has("position"), "着く位置は、行き先が、自分の記録から決める (位置は渡さない)")
	check(SaveGame.current_area() == "trv-x" and SaveGame.read(path_a).status == "ok", "最後に遊んだエリアは X。いまの様子は、保存されている")
	scene.queue_free()
	await process_frame
	WorldLoader.arrival = {}

	# 行き先のマップを作り直して、水平の原点が動いていた時: 着く位置は、補正した復帰位置 (保存した座標のままではない)
	var moved_origin := x_origin - Vector3(4.0, 0.0, 0.0)
	_make_world("x", "外の地", moved_origin, size, "trv-other", ground)  # 原点が、西へ 4 m 動いた (同じ場所は、x が 4 大きくなる)
	WorldLoader.arrival = {"path": path_x, "at_bonfire": true, "yaw": 0.0, "pitch": 0.0}
	var scene_r: Node = load("res://scenes/world_local.tscn").instantiate()
	scene_r.get_node("DayNight").settings = settings
	scene_r.get_node("World").save_enabled = true
	scene_r.get_node("World").auto_change_scene = false
	root.add_child(scene_r)
	for i in 60:
		await physics_frame
	var player_r: CharacterBody3D = scene_r.get_node("Player")
	check(scene_r.get_node("World")._path == path_x and absf(player_r.global_position.x - (x_spawn.x + 4.0)) < 1.5, "作り直したマップへ移っても、補正した復帰位置のそばに着く (x = %.1f、補正前 %.1f)" % [player_r.global_position.x, x_spawn.x])
	scene_r.queue_free()
	await process_frame
	WorldLoader.arrival = {}

	# 移れる篝火がない時: 知らせるだけ (一覧は開かない)
	SaveGame.delete()
	var scene2: Node = load("res://scenes/world_local.tscn").instantiate()
	scene2.get_node("DayNight").settings = settings
	scene2.get_node("World").world_path = path_a
	scene2.get_node("World").save_enabled = true
	scene2.get_node("World").auto_change_scene = false
	root.add_child(scene2)
	for i in 40:
		await physics_frame
	await _wait_loaded(scene2)
	var player2: CharacterBody3D = scene2.get_node("Player")
	var fire2: Node3D = scene2.find_child("AreaBonfire", true, false)
	player2.global_position = fire2.global_position + Vector3(0.5, 0.5, 0.0)
	for i in 10:
		await physics_frame
	player2.rest()
	player2._unhandled_input(_action("travel"))
	check(scene2.get_node("World")._menu == null and player2.message.text == "移れる篝火は、まだありません" and not player2.input_blocked, "移れる篝火がない時は、知らせるだけ (一覧は開かない)")
	scene2.queue_free()
	await process_frame

	# 行き先が多くても、画面からはみ出さない: スクロールできる枠に並び、「やめる」は、いつも見える
	root.size = Vector2i(1152, 648)  # ヘッドレスの画面は、既定では、とても小さい。ふつうのウィンドウの大きさにする
	var many := TravelMenu.new()
	root.add_child(many)
	var many_names: Array[String] = []
	for i in 60:
		many_names.append("たくさんの篝火 %d" % i)
	many.open(many_names)
	for i in 3:
		await process_frame
	var view := many.get_viewport().get_visible_rect().size
	var cancel_button: Button = many.buttons[many.buttons.size() - 1]
	check(many.scroll != null and many.scroll.size.y <= view.y * TravelMenu.MAX_HEIGHT_RATIO + 1.0, "行き先が 60 個でも、一覧の枠の高さは、画面の高さの上限を超えない (%.0f / %.0f)" % [many.scroll.size.y, view.y])
	check(cancel_button.global_position.y + cancel_button.size.y <= view.y and cancel_button.global_position.y >= 0.0, "「やめる」は、いつも、画面の中に見える (y=%.0f 高さ=%.0f 画面=%s)" % [cancel_button.global_position.y, cancel_button.size.y, view])
	many.buttons[40].grab_focus()
	await process_frame
	await process_frame
	check(many.scroll.scroll_vertical > 0, "遠い行き先を選ぶと、枠が、その行までスクロールする (%d)" % many.scroll.scroll_vertical)
	many.close()
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
