extends SceneTree

# 実行: godot --headless --path game --script res://tests/reveal_test.gd
# 点群の見せ方 (確かめた所の地図、点の生成、歩くと現れる、休むと広く現れる、設定) を確かめる

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _initialize() -> void:
	_test_reveal_map()
	_test_settings()
	await _test_point_world()
	await _test_integration()
	await _test_environment_colors()
	await _test_robustness()
	await _test_rescan_effect()
	await _test_rescan_flow()
	quit(1 if failures.size() > 0 else 0)


func _test_reveal_map() -> void:
	# 100m x 60m の世界 (x: 0〜100、z: 0〜60)
	var map := RevealMap.new(AABB(Vector3(0, 0, 0), Vector3(100, 10, 60)), 0.5)
	check(map.width() == 200 and map.height() == 120, "世界の大きさに合わせた地図ができる (%d x %d)" % [map.width(), map.height()])
	check(map.sample(Vector3(50, 0, 30)) == 0.0 and map.coverage() == 0.0, "最初は、どこも確かめていない")

	map.paint(Vector3(50, 0, 30), 10.0)
	check(map.sample(Vector3(50, 0, 30)) > 0.99, "書き込んだ中心は、確かめた所になる")
	var edge := map.sample(Vector3(58, 0, 30))
	check(edge > 0.0 and edge < 0.6, "縁へ向けて、なめらかに弱くなる (%.2f)" % edge)
	check(map.sample(Vector3(70, 0, 30)) == 0.0, "半径の外は、確かめていない")
	var coverage := map.coverage()
	check(coverage > 0.02 and coverage < 0.08, "確かめた割合が、円の面積に近い (%.3f)" % coverage)

	# 一度確かめた所は、消えない (弱い書き込みで上書きされない)
	var center_before := map.sample(Vector3(50, 0, 30))
	map.paint(Vector3(53, 0, 30), 3.0)
	check(map.sample(Vector3(50, 0, 30)) >= center_before, "一度確かめた所は、消えない")
	check(map.sample(Vector3(50, 0, 30)) == map.sample(Vector3(50, 0, 30)), "同じ場所を読むと、同じ値")

	# 範囲の外へ書き込んでも、止まらない
	map.paint(Vector3(-50, 0, -50), 10.0)
	map.paint(Vector3(500, 0, 500), 10.0)
	map.paint(Vector3(0, 0, 0), 5.0)
	check(map.sample(Vector3(0.5, 0, 0.5)) > 0.9, "世界の隅でも、書き込める")
	check(map.sample(Vector3(-100, 0, -100)) >= 0.0, "範囲の外を読んでも、止まらない")

	# 書き込みがあった時だけ、テクスチャを更新する
	check(map.update_texture(), "書き込みがあれば、テクスチャを更新する")
	check(not map.update_texture(), "書き込みがなければ、更新しない")

	# 世界が大きすぎる時は、粗くして、画素数を抑える
	var huge := RevealMap.new(AABB(Vector3(0, 0, 0), Vector3(20000, 10, 20000)), 0.5)
	check(huge.width() * huge.height() <= RevealMap.MAX_PIXELS * 1.05 and huge.cell > 0.5, "世界が大きすぎる時は、地図を粗くする (1 画素 %.1fm)" % huge.cell)


func _test_settings() -> void:
	var path := "user://test_look.cfg"
	check(GameSettings.new().point_mode == "mesh_and_points", "点の表現の既定は、面と点を重ねる")

	var file := ConfigFile.new()
	file.set_value("look", "point_mode", "points_only")
	file.save(path)
	check(GameSettings.load_from(path).point_mode == "points_only", "設定ファイルで、点だけにできる")
	file.set_value("look", "point_mode", "off")
	file.save(path)
	check(GameSettings.load_from(path).point_mode == "off", "設定ファイルで、点の表現を切れる")
	file.set_value("look", "point_mode", "bogus")
	file.save(path)
	check(GameSettings.load_from(path).point_mode == "mesh_and_points", "不正な値は、既定にする")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


class Recorder:
	extends Node
	var calls: Array[Vector3] = []
	var events: Array[String] = []  # 呼ばれた順 ("rest"、"lost"、"rescan")
	var rescan_positions: Array[Vector3] = []

	func on_rest(position: Vector3) -> void:
		calls.append(position)
		events.append("rest")

	func on_lost() -> void:
		events.append("lost")

	func on_rescan(position: Vector3) -> void:
		events.append("rescan")
		rescan_positions.append(position)


func _start_world(point_mode: String) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	scene.get_node("World").world_path = "res://assets/sample_world.glb"
	scene.get_node("World").point_mode = point_mode
	root.add_child(scene)
	return scene


# 200m x 200m の平らな世界 (5m 間隔の格子)。サンプルの世界は 20m 四方で、歩いた周りの半径だけで全域が埋まってしまうため、距離の確認には広い世界を使う
func _big_world() -> Node3D:
	var world := Node3D.new()
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cells := 40
	for z in cells + 1:
		for x in cells + 1:
			tool.add_vertex(Vector3(x * 5.0, 0.0, z * 5.0))
	for z in cells:
		for x in cells:
			var i := z * (cells + 1) + x
			for index in [i, i + 1, i + cells + 1, i + 1, i + cells + 2, i + cells + 1]:
				tool.add_index(index)
	var instance := MeshInstance3D.new()
	instance.mesh = tool.commit()
	world.add_child(instance)
	return world


func _test_point_world() -> void:
	var world := _big_world()
	var player := Node3D.new()
	root.add_child(world)
	root.add_child(player)
	player.global_position = Vector3(100, 0, 100)
	var mesh_instance: MeshInstance3D = world.get_child(0)

	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	var expected := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() + (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3

	var point_world := PointWorld.new()
	root.add_child(point_world)
	point_world.setup(world, player, PointWorld.Mode.MESH_AND_POINTS)
	check(point_world.point_count == expected and expected > 1000, "点は、頂点と三角形の中心から作られる (%d 個)" % point_world.point_count)
	check(point_world.points_instance.mesh.get_surface_count() == 1, "点は、1 つのメッシュにまとまる (描画が軽い)")
	check(point_world.reveal.sample(player.global_position) > 0.9, "最初に、いる所の周りが確かめた所になる")
	check(mesh_instance.visible and mesh_instance.material_override is ShaderMaterial, "面と点の時は、面が見えて、確かめた所だけ明るい素材になる")

	point_world.set_mode(PointWorld.Mode.POINTS_ONLY)
	check(not mesh_instance.visible, "点だけの時は、面を隠す")
	point_world.set_mode(PointWorld.Mode.MESH_AND_POINTS)
	check(mesh_instance.visible, "面と点に戻すと、面がまた見える")

	# 離れた所は、まだ確かめていない。歩くと、そこが確かめた所になる
	var far := Vector3(160, 0, 100)
	check(point_world.reveal.sample(far) == 0.0, "離れた所は、まだ確かめていない")
	player.global_position = far
	for i in 5:
		await process_frame
	check(point_world.reveal.sample(far) > 0.9, "歩いて行くと、そこが確かめた所になる")
	var covered := point_world.reveal.coverage()
	for i in 5:
		await process_frame
	check(point_world.reveal.coverage() == covered, "立ち止まっている間は、広がらない (書き込みを繰り返さない)")

	# 少し動いただけでは、書き込まない (毎フレーム書き込むと重い)
	player.global_position = far + Vector3(PointWorld.PAINT_STEP * 0.5, 0, 0)
	for i in 3:
		await process_frame
	check(point_world.reveal.coverage() == covered, "少し動いただけでは、書き込まない")

	# 篝火で休むと、歩いた所よりずっと広く確かめた所になる
	var rest_target := Vector3(30, 0, 160)
	check(point_world.reveal.sample(rest_target) == 0.0, "休む前は、遠くは、まだ確かめていない")
	point_world.on_rest(Vector3(30 + PointWorld.REST_RADIUS - 10.0, 0, 160))  # 中心から 30m。歩いた時の半径 (16m) より遠い
	check(point_world.reveal.sample(rest_target) > 0.3, "篝火で休むと、周囲が広く確かめた所になる")
	check(PointWorld.REST_RADIUS > PointWorld.REVEAL_RADIUS * 2.0, "休んだ時の広がりは、歩いた時より、ずっと広い")

	point_world.queue_free()
	world.queue_free()
	player.queue_free()
	await process_frame


func _test_integration() -> void:
	# 点の表現を切ると、点は作られない
	var off := _start_world("off")
	for i in 30:
		await physics_frame
	check(off.get_node("World").find_children("*", "PointWorld", false, false).is_empty(), "点の表現を切ると、点は作られない")
	off.queue_free()
	await process_frame

	# 世界の読み込みで、点の表現が自動で入る (既定は、面と点)
	var scene := _start_world("mesh_and_points")
	for i in 60:
		await physics_frame
	var world: Node3D = scene.get_node("World")
	var found := world.find_children("*", "PointWorld", false, false)
	check(found.size() == 1 and (found[0] as PointWorld).mode == PointWorld.Mode.MESH_AND_POINTS, "世界を読み込むと、点の表現が入る")
	check(scene.get_node("Player").is_on_floor(), "点の表現が入っても、地面に立てる (当たり判定に影響しない)")
	check(not world.find_children("*", "StaticBody3D", true, false).is_empty(), "当たり判定が、そのまま残っている")

	var points_only := _start_world("points_only")
	for i in 30:
		await physics_frame
	var only: PointWorld = points_only.get_node("World").find_children("*", "PointWorld", false, false)[0]
	check(only.mode == PointWorld.Mode.POINTS_ONLY, "設定で、点だけにできる")
	check(points_only.get_node("Player").is_on_floor(), "点だけの時 (面を隠している時) も、地面に立てる")
	points_only.queue_free()
	await process_frame

	# Player が篝火で休むと、点の表現へ知らせる
	var recorder := Recorder.new()
	recorder.add_to_group("point_world")
	scene.add_child(recorder)
	var player: CharacterBody3D = scene.get_node("Player")
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	scene.add_child(fire)
	fire.global_position = player.global_position + Vector3(1.0, 0.0, 0.0)
	for i in 5:
		await process_frame
	player.rest()
	check(recorder.calls.size() == 1 and recorder.calls[0].is_equal_approx(fire.global_position), "休むと、点の表現へ、篝火の位置を知らせる")
	scene.queue_free()
	await process_frame


# 点だけの方式の色は、空の明るさに合わせて変わる (昼は暗く、夜は明るく)。
# 空の明るさ (WorldEnvironment) は、PointWorld が自分で探す
func _point_color_at(hour: float, mode: String) -> Color:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.time_mode = "fixed"
	settings.fixed_hour = hour
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = "res://assets/sample_world.glb"
	scene.get_node("World").point_mode = mode
	root.add_child(scene)
	for i in 40:
		await physics_frame
	var point_world: PointWorld = scene.get_node("World").find_children("*", "PointWorld", false, false)[0]
	var color: Color = point_world._point_material.get_shader_parameter("point_color")
	check(point_world.environment != null or mode == "mesh_and_points", "PointWorld が、場面の WorldEnvironment を自分で探して、空の明るさを知る (%s)" % mode)
	scene.queue_free()
	await process_frame
	return color


func _test_environment_colors() -> void:
	var day: Color = await _point_color_at(12.0, "points_only")
	var night: Color = await _point_color_at(23.0, "points_only")
	check(day.get_luminance() < 0.4 and night.get_luminance() > 0.6, "点だけの方式: 昼は暗く、夜は明るい点になる (昼 %.2f、夜 %.2f)" % [day.get_luminance(), night.get_luminance()])

	# 面と点を重ねる方式は、背景が地面なので、昼も夜も明るい点
	var mesh_day: Color = await _point_color_at(12.0, "mesh_and_points")
	var mesh_night: Color = await _point_color_at(23.0, "mesh_and_points")
	check(mesh_day.get_luminance() > 0.6 and mesh_night.get_luminance() > 0.6, "面と点の方式: 昼も夜も、明るい点 (昼 %.2f、夜 %.2f)" % [mesh_day.get_luminance(), mesh_night.get_luminance()])


func _test_robustness() -> void:
	# メッシュのない MeshInstance3D があっても、止まらない
	var world := Node3D.new()
	var good := _big_world()
	world.add_child(good.get_child(0).duplicate())
	world.add_child(MeshInstance3D.new())  # mesh が null
	var player := Node3D.new()
	root.add_child(world)
	root.add_child(player)
	var point_world := PointWorld.new()
	root.add_child(point_world)
	point_world.setup(world, player)
	check(point_world.point_count > 0, "メッシュのない MeshInstance3D があっても、点が作られる (止まらない)")

	# 高さだけ動いても (ジャンプ)、書き込まない。地図は真上から見たものなので、水平の距離で比べる
	player.global_position = Vector3(100, 0, 100)
	for i in 3:
		await process_frame
	var covered := point_world.reveal.coverage()
	player.global_position = Vector3(100, PointWorld.PAINT_STEP * 4.0, 100)
	for i in 3:
		await process_frame
	check(point_world.reveal.coverage() == covered, "真上へ跳んだだけでは、書き込まない (水平の距離で比べる)")
	point_world.queue_free()
	world.queue_free()
	player.queue_free()
	good.queue_free()

	# 半径 0 以下の書き込みは、何も起きず、止まらない
	var map := RevealMap.new(AABB(Vector3.ZERO, Vector3(10, 1, 10)), 0.5)
	map.paint(Vector3(5, 0, 5), 0.0)
	map.paint(Vector3(5, 0, 5), -3.0)
	check(map.sample(Vector3(5, 0, 5)) == 0.0 and map.coverage() == 0.0, "半径が 0 以下の書き込みは、何も起きない")

	# 不正な point_mode は、既定 (面と点) にする
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	scene.get_node("World").world_path = "res://assets/sample_world.glb"
	scene.get_node("World").point_mode = "bogus"
	root.add_child(scene)
	for i in 30:
		await physics_frame
	var found := scene.get_node("World").find_children("*", "PointWorld", false, false)
	check(found.size() == 1 and (found[0] as PointWorld).mode == PointWorld.Mode.MESH_AND_POINTS, "不正な point_mode (@export 経由) も、既定の面と点にする")
	scene.queue_free()
	await process_frame


func _param(point_world: PointWorld, name: String) -> Variant:
	return point_world._point_material.get_shader_parameter(name)


# 時間を待つ。ヘッドレスは、描画のフレームが 1 秒に約 140 回回るので、フレーム数では時間を測れない
func _seconds(seconds: float) -> void:
	await create_timer(seconds).timeout


# 再スキャンの演出: 世界が崩れ、波が広がって再構成される。篝火で休んだ時も、同じ波が出る (崩れはなし)
func _test_rescan_effect() -> void:
	var world := _big_world()
	var player := Node3D.new()
	root.add_child(world)
	root.add_child(player)
	player.global_position = Vector3(100, 0, 100)
	var point_world := PointWorld.new()
	root.add_child(point_world)
	point_world.setup(world, player)
	await _seconds(0.1)

	check(point_world.disturbance == 0.0 and not point_world.pulse_active, "最初は、崩れていないし、波も出ていない")
	check(_param(point_world, "disturbance") == 0.0 and _param(point_world, "pulse_enabled") == 0.0, "シェーダーにも、崩れも波もないと伝わる")

	# 崩れる: 約 0.8 秒で最大になる
	point_world.on_lost()
	await _seconds(0.33)
	var halfway: float = point_world.disturbance
	check(halfway > 0.2 and halfway < 0.8, "落ちると、世界が少しずつ崩れていく (途中 %.2f)" % halfway)
	await _seconds(0.7)
	check(point_world.disturbance > 0.99, "約 0.8 秒で、崩れが最大になる (%.2f)" % point_world.disturbance)
	check(is_equal_approx(_param(point_world, "disturbance"), point_world.disturbance), "崩れ具合が、シェーダーへ伝わる")
	await _seconds(1.0)
	check(point_world.disturbance > 0.99, "再構成が始まるまで、崩れたまま保たれる")

	# 画面全体のノイズ (世界の点が視界に入らなくても、「位置を見失った」と伝わるように)
	var glitch_rect: ColorRect = point_world.glitch_rect
	check(point_world.glitch > 0.99 and glitch_rect.visible, "崩れている間は、画面全体にノイズがかかる (%.2f)" % point_world.glitch)
	check(is_equal_approx((glitch_rect.material as ShaderMaterial).get_shader_parameter("intensity"), point_world.glitch), "ノイズの強さが、シェーダーへ伝わる")
	check(glitch_rect.mouse_filter == Control.MOUSE_FILTER_IGNORE, "ノイズの層は、マウスの操作を邪魔しない")
	check((glitch_rect.get_parent() as CanvasLayer).layer < 1, "ノイズの層は、メッセージ (HUD) より下にある (文字が読める)")

	# 再構成: 篝火の位置から、波が広がる。波が通るまで、新しく現れる所は見えない
	var center := Vector3(30, 0, 160)
	var before: Image = point_world.reveal.snapshot()
	var target := center + Vector3(PointWorld.REST_RADIUS - 10.0, 0, 0)  # 中心から 30m
	check(point_world.reveal.sample(target) == 0.0, "再構成の前は、そこをまだ確かめていない")
	point_world.on_rescan(center)
	check(point_world.pulse_active and point_world.pulse_radius < 1.0, "再構成が始まると、波が出る (半径はほぼ 0)")
	check(point_world.prev_image != null and point_world.prev_image.get_pixelv(point_world.reveal.pixel_of(target)).r == 0.0, "波の前の状態を、別に残す (新しく現れる所は、波が通るまで見えない)")
	check(point_world.reveal.sample(target) > 0.3, "確かめた所の地図には、最初から最終の範囲が書かれる (波は、見せ方だけを動かす)")
	check(before.get_pixelv(point_world.reveal.pixel_of(target)).r == 0.0, "波の前のコピーは、あとの書き込みの影響を受けない")

	var previous_radius := 0.0
	var monotonic := true
	var max_radius := 0.0
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < int((PointWorld.PULSE_SECONDS + 0.25) * 1000.0):
		await process_frame
		monotonic = monotonic and point_world.pulse_radius >= previous_radius - 0.0001
		previous_radius = point_world.pulse_radius
		max_radius = maxf(max_radius, point_world.pulse_radius)
	check(monotonic, "波は、広がり続ける (縮まない)")
	check(max_radius > PointWorld.REST_RADIUS, "波は、書き込んだ範囲を超えて広がる (%.1f m)" % max_radius)
	check(not point_world.pulse_active, "波は、決まった時間で終わる")
	check(_param(point_world, "ring_strength") == 0.0, "波が終わると、波の縁の光も消える (シェーダーにも伝わる)")
	check(_param(point_world, "pulse_enabled") == 1.0, "遠くの崩れが戻るまでは、波の範囲を保つ (内側が、崩れた状態へ戻らない)")

	# 画面全体のノイズは、波が広がる間に消える (遠くの崩れが戻るのを待たない)
	check(point_world.glitch == 0.0 and not glitch_rect.visible, "波が広がる間に、画面のノイズは消える (描画の負荷もなくなる)")

	# 波が終わってから、遠くの崩れが、ゆっくり戻る
	check(point_world.disturbance > 0.0 and point_world.disturbance < 1.0, "波が終わったあとは、崩れが少しずつ戻っていく (%.2f)" % point_world.disturbance)
	await _seconds(PointWorld.RECOVER_SECONDS + 0.4)
	check(point_world.disturbance == 0.0, "やがて、崩れが完全に戻る")
	check(_param(point_world, "pulse_enabled") == 0.0, "崩れが戻りきると、波の範囲も外れる")

	# 篝火で休んだ時も、波が出る。崩れは起きない
	var rest_center := Vector3(160, 0, 30)
	point_world.on_rest(rest_center)
	check(point_world.pulse_active and point_world.disturbance == 0.0 and not glitch_rect.visible, "篝火で休んだ時も波が出る (世界は崩れず、画面のノイズもない)")
	check(point_world.reveal.sample(rest_center) > 0.9, "休んだ篝火の周りは、確かめた所になる")
	await _seconds(PointWorld.PULSE_SECONDS + 0.3)
	check(not point_world.pulse_active and point_world.disturbance == 0.0, "休んだ時の波も、終わる (崩れは起きないまま)")

	point_world.queue_free()
	world.queue_free()
	player.queue_free()
	await process_frame


# Player が落ちて、復帰するまでの流れ
func _test_rescan_flow() -> void:
	var scene := _start_world("mesh_and_points")
	for i in 60:
		await physics_frame
	var player: CharacterBody3D = scene.get_node("Player")
	var recorder := Recorder.new()
	recorder.add_to_group("point_world")
	scene.add_child(recorder)
	var point_world: PointWorld = scene.get_node("World").find_children("*", "PointWorld", false, false)[0]
	var spawn: Vector3 = player.spawn_position

	player.global_position = Vector3(0, -30, 0)  # 世界の下へ落とす
	await _seconds(0.4)
	check(recorder.events == ["lost"] and player.rescanning, "落ちると、まず点の表現へ「位置を見失った」と知らせる")
	check(point_world.disturbance > 0.2, "落ちている間に、世界が崩れ始める (%.2f)" % point_world.disturbance)

	# 復帰するまで (RESCAN_SECONDS)
	await _seconds(player.RESCAN_SECONDS)
	var horizontal := Vector2(player.global_position.x - spawn.x, player.global_position.z - spawn.z).length()
	check(not player.rescanning and horizontal < 0.5, "復帰した (篝火の位置、水平の距離 %.2f)" % horizontal)
	check(recorder.events == ["lost", "rescan"], "復帰したあとに、再構成を知らせる (順番: 位置を見失う → 再構成)")
	check(recorder.rescan_positions.size() == 1 and recorder.rescan_positions[0].is_equal_approx(spawn), "再構成は、復帰した篝火の位置から始まる")
	check(point_world.pulse_active, "復帰した直後に、波が出ている")

	# 全部おさまる (波 + 崩れが戻る時間)
	await _seconds(PointWorld.PULSE_SECONDS + PointWorld.RECOVER_SECONDS + 0.8)
	check(point_world.disturbance == 0.0 and not point_world.pulse_active, "しばらくすると、崩れも波もおさまる")
	check(player.is_on_floor(), "再スキャンのあとも、地面に立てる")
	scene.queue_free()
	await process_frame
