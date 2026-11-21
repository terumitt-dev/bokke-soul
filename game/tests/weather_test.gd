extends SceneTree

# 実行: godot --headless --path game --script res://tests/weather_test.gd
# 天気 (決まり方、なめらかな移り変わり、色味、場面への反映) を確かめる

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func near(a: float, b: float, tolerance: float = 0.001) -> bool:
	return absf(a - b) <= tolerance


func _initialize() -> void:
	_test_choice()
	_test_transition()
	_test_tint()
	await _test_scene()
	quit(1 if failures.size() > 0 else 0)


func _test_choice() -> void:
	var same := true
	for slot in range(-50, 200):
		same = same and Weather.type_at_slot(slot, 7) == Weather.type_at_slot(slot, 7)
	check(same, "同じ種と枠なら、いつ計算しても同じ天気")

	var differing := 0
	for slot in 200:
		if Weather.type_at_slot(slot, 1) != Weather.type_at_slot(slot, 2):
			differing += 1
	check(differing > 50, "種が違えば、天気の並びが変わる (%d / 200 が違う)" % differing)

	# 重みどおりに出る (晴れ 40、曇り 30、砂塵 20、砂嵐 10)
	var counts := {"clear": 0, "overcast": 0, "dust": 0, "storm": 0}
	var slots := 4000
	for slot in slots:
		counts[Weather.type_at_slot(slot, 0)] += 1
	var ok := true
	for id: String in Weather.ORDER:
		ok = ok and absf(float(counts[id]) / slots - Weather.TYPES[id].weight / 100.0) < 0.04
	check(ok, "天気の出る割合が重みに合う (%s)" % [counts])

	check(Weather.params_at(10.0, 0, "storm").type == "storm", "種類を指定すると、その天気に固定できる")
	check(Weather.params_at(10.0, 0, "no_such_weather").has("type"), "知らない種類を指定しても、止まらない")
	check(Weather.params_for("storm").fog_mult > Weather.params_for("clear").fog_mult * 5.0, "砂嵐は晴れより霧がずっと濃い")
	check(Weather.params_for("storm").sun_mult < Weather.params_for("clear").sun_mult * 0.3, "砂嵐は太陽の光が弱い")


func _test_transition() -> void:
	# 前の枠と今の枠で、天気が違う場所を探す
	var slot := 1
	while Weather.type_at_slot(slot, 3) == Weather.type_at_slot(slot - 1, 3):
		slot += 1
	var start := slot * Weather.SLOT_HOURS
	var previous := Weather.params_for(Weather.type_at_slot(slot - 1, 3))
	var current := Weather.params_for(Weather.type_at_slot(slot, 3))

	check(near(Weather.params_at(start, 3).fog_mult, previous.fog_mult), "枠が変わった瞬間は、前の天気のまま")
	check(near(Weather.params_at(start + Weather.TRANSITION_HOURS, 3).fog_mult, current.fog_mult), "移り変わりが終わると、今の天気になる")
	check(Weather.params_at(start + 1.0, 3).type == current.type, "枠の中では、今の天気を名乗る")

	# 1 分ごとの変化が小さい (急に天気が切り替わらない)
	var worst := 0.0
	var previous_fog: float = Weather.params_at(0.0, 3).fog_mult
	for minute in range(1, 100 * 3 * 60):
		var fog: float = Weather.params_at(minute / 60.0, 3).fog_mult
		worst = maxf(worst, absf(fog - previous_fog))
		previous_fog = fog
	check(worst < 0.35, "1 分あたりの霧の変化が小さい (最大 %.3f)" % worst)


func _test_tint() -> void:
	var color := Color(0.50, 0.40, 0.30)
	var haze := Weather.TYPES.dust.haze_color as Color
	check(near(Weather.tint(color, haze, 1.0).get_luminance(), color.get_luminance(), 0.01), "色味を寄せても、明るさは変わらない")
	check(Weather.tint(color, haze, 0.0).is_equal_approx(color), "寄せる度合いが 0 なら、元の色のまま")
	check(Weather.tint(Color(0.01, 0.01, 0.02), haze, 1.0).get_luminance() < 0.05, "夜の暗い色は、色味を寄せても暗いまま")
	check(not Weather.tint(color, haze, 0.5).is_equal_approx(color), "寄せると、色が変わる")


func _settings(weather_enabled: bool = true) -> GameSettings:
	var s := GameSettings.new()
	s.time_mode = "fixed"
	s.fixed_hour = 12.0
	s.weather_enabled = weather_enabled
	return s


func _start(world_settings: GameSettings) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	scene.get_node("World").world_path = "res://assets/sample_world.glb"
	scene.get_node("DayNight").settings = world_settings
	root.add_child(scene)
	return scene


func _test_scene() -> void:
	var scene := _start(_settings())
	await process_frame
	var day_night: DayNight = scene.get_node("DayNight")
	var sun: DirectionalLight3D = scene.get_node("Light")

	day_night.forced_weather = "clear"
	day_night._apply()
	var clear_fog := day_night.environment.fog_density
	var clear_sun := sun.light_energy
	day_night.forced_weather = "storm"
	day_night._apply()
	check(day_night.environment.fog_density > clear_fog * 5.0, "砂嵐だと、霧が濃くなる")
	check(sun.light_energy < clear_sun * 0.3, "砂嵐だと、太陽の光が弱くなる")
	check(scene.get_node("HUD/Clock").text.contains("砂嵐"), "時計の横に天気の名前が出る")

	# Y キーの代わりに、切り替えを直接呼んで、一巡して自動に戻る
	day_night.forced_weather = ""
	var seen: Array[String] = []
	for i in Weather.ORDER.size() + 1:
		day_night._cycle_forced_weather()
		seen.append(day_night.forced_weather)
	check(seen == ["clear", "overcast", "dust", "storm", ""], "天気の切り替えは、一巡して自動に戻る")
	scene.queue_free()
	await process_frame

	# 天気を切ると、いつも晴れ
	var off := _start(_settings(false))
	await process_frame
	check(off.get_node("DayNight").weather.type == "clear", "天気をオフにすると、いつも晴れ")
	off.queue_free()
	await process_frame
