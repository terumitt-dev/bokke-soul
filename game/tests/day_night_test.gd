extends SceneTree

# 実行: godot --headless --path game --script res://tests/day_night_test.gd
# 昼夜 (時刻の進み方、設定、空の色、場面への反映) を確かめる

const TMP_SETTINGS := "user://test_settings.cfg"

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func near(a: float, b: float, tolerance: float = 0.001) -> bool:
	return absf(a - b) <= tolerance


func _settings(mode: String, day_minutes: float = 60.0, start: float = 7.0, fixed: float = 12.0) -> GameSettings:
	var s := GameSettings.new()
	s.time_mode = mode
	s.day_length_minutes = day_minutes
	s.start_hour = start
	s.fixed_hour = fixed
	s.weather_enabled = false  # ここでは昼夜だけを確かめる。天気は weather_test で確かめる
	return s


func _write_cfg(values: Dictionary) -> void:
	var file := ConfigFile.new()
	for key: String in values:
		file.set_value("time", key, values[key])
	file.save(TMP_SETTINGS)


func _initialize() -> void:
	_test_time()
	_test_settings()
	_test_palette()
	await _test_scene()
	quit(1 if failures.size() > 0 else 0)


func _test_time() -> void:
	# 1 日 60 分: 30 分で半日 (12 時間) 進む
	var t := TimeOfDay.new(_settings("accelerated", 60.0, 7.0))
	check(near(t.hour, 7.0), "開始時刻から始まる")
	t.advance(1800.0)
	check(near(t.hour, 19.0), "1 日 60 分なら、30 分で 12 時間進む")
	t.advance(1800.0)
	check(near(t.hour, 7.0), "24 時を過ぎると 0 時に戻る")
	check(near(t.total_hours, 31.0), "通しの時間は 24 時で折り返さない (7 時から 1 日進むと 31)")

	# 1 日 5 時間 (300 分): 150 分で半日
	var slow := TimeOfDay.new(_settings("accelerated", 300.0, 6.0))
	slow.advance(150.0 * 60.0)
	check(near(slow.hour, 18.0), "1 日 5 時間なら、2.5 時間で 12 時間進む")

	# 時刻を止める
	var fixed := TimeOfDay.new(_settings("fixed", 60.0, 7.0, 21.5))
	fixed.advance(10000.0)
	check(near(fixed.hour, 21.5), "fixed は時刻が進まない")

	# 実時間
	var real := TimeOfDay.new(_settings("realtime"))
	real.advance(0.0)
	var diff := absf(real.hour - TimeOfDay.realtime_hour())
	check(minf(diff, 24.0 - diff) < 0.01, "realtime は、パソコンの時刻に合う")

	# 時刻の飛ばし (開発用) は、どの方式でも効く
	var jump := TimeOfDay.new(_settings("fixed", 60.0, 7.0, 22.0))
	jump.jump(3.0)
	jump.advance(1.0)
	check(near(jump.hour, 1.0), "jump は 24 時で折り返す")
	check(TimeOfDay.new(_settings("accelerated", 60.0, 9.25)).format() == "09:15", "時刻を HH:MM で表示する")


func _test_settings() -> void:
	check(GameSettings.load_from("user://no_such_file.cfg").time_mode == "accelerated", "設定ファイルがなくても、既定値で動く")

	_write_cfg({"mode": "realtime", "day_length_minutes": 300.0, "start_hour": 5.5, "fixed_hour": 3.0})
	var ok := GameSettings.load_from(TMP_SETTINGS)
	check(ok.time_mode == "realtime" and near(ok.day_length_minutes, 300.0) and near(ok.start_hour, 5.5), "設定ファイルの値を読む")

	_write_cfg({"mode": "bogus", "day_length_minutes": -5.0, "start_hour": 99.0, "fixed_hour": "noon"})
	var bad := GameSettings.load_from(TMP_SETTINGS)
	check(bad.time_mode == "accelerated" and near(bad.day_length_minutes, 60.0), "不正な方式と 1 日の長さは、既定値にする")
	check(near(bad.start_hour, 7.0) and near(bad.fixed_hour, 12.0), "不正な時刻 (範囲外、文字) は、既定値にする")

	var weather_cfg := ConfigFile.new()
	weather_cfg.set_value("weather", "enabled", false)
	weather_cfg.set_value("weather", "seed", 42)
	weather_cfg.save(TMP_SETTINGS)
	var weather_ok := GameSettings.load_from(TMP_SETTINGS)
	check(not weather_ok.weather_enabled and weather_ok.weather_seed == 42, "天気の設定 (enabled、seed) を読む")
	weather_cfg.set_value("weather", "enabled", "yes")
	weather_cfg.set_value("weather", "seed", 1.5)
	weather_cfg.save(TMP_SETTINGS)
	var weather_bad := GameSettings.load_from(TMP_SETTINGS)
	check(weather_bad.weather_enabled and weather_bad.weather_seed == 0, "不正な天気の設定 (文字、小数) は、既定値にする")

	_write_cfg({"day_length_minutes": 0.0})
	check(near(GameSettings.load_from(TMP_SETTINGS).day_length_minutes, 60.0), "1 日の長さが 0 なら、既定値にする (0 での割り算を防ぐ)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_SETTINGS))


func _test_palette() -> void:
	var night := SkyPalette.sample(0.0)
	var noon := SkyPalette.sample(12.0)
	check(near(night.sun_energy, 0.0) and noon.sun_energy > 1.0, "夜は太陽が消え、昼は明るい")
	check(night.fog_density > noon.fog_density, "夜の方が霧が濃い")
	check(noon.top.get_luminance() > night.top.get_luminance() * 5.0, "昼の空は夜より明るい")
	check(SkyPalette.sample(24.0).top.is_equal_approx(night.top), "24 時は 0 時と同じ")
	check(SkyPalette.sample(-1.0).top.is_equal_approx(SkyPalette.sample(23.0).top), "負の時刻も折り返す")

	# 切り替わりでぶつ切りにならない (1 分ごとの変化が小さい)
	var worst := 0.0
	var previous := SkyPalette.sample(0.0)
	for minute in range(1, 24 * 60 + 1):
		var current := SkyPalette.sample(minute / 60.0)
		worst = maxf(worst, absf(current.top.r - previous.top.r))
		worst = maxf(worst, absf(current.sun_energy - previous.sun_energy))
		previous = current
	check(worst < 0.02, "1 分あたりの変化が小さい (最大 %.4f)" % worst)

	# 太陽が地平線の下にある間は、光がない (下から地面を照らさない)。日の出前後と日没前後もここに入る
	var dark_hours_ok := true
	for hour in [0.0, 2.0, 4.0, 5.5, 6.0, 18.0, 18.2, 19.0, 21.0, 23.0]:
		dark_hours_ok = dark_hours_ok and SkyPalette.sun_energy(hour) < 0.001
	check(dark_hours_ok, "日の出前と日没後 (5.5 時、18.2 時を含む) は、太陽の光がない")
	check(SkyPalette.sun_energy(7.0) > 0.3 and SkyPalette.sun_energy(12.0) > 1.0, "日が昇ると光が出る")
	check(SkyPalette.sun_energy(6.5) < SkyPalette.sun_energy(7.0), "日の出の直後は、光が徐々に強くなる")


func _test_scene() -> void:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	scene.get_node("World").world_path = "res://assets/sample_world.glb"
	scene.get_node("DayNight").settings = _settings("fixed", 60.0, 7.0, 12.0)
	root.add_child(scene)
	await process_frame

	var day_night: DayNight = scene.get_node("DayNight")
	var sun: DirectionalLight3D = scene.get_node("Light")
	check(day_night.environment.background_mode == Environment.BG_SKY, "空が昼夜の空になる")
	check(sun.light_energy > 1.0 and sun.visible, "昼は太陽が点く")
	# 真上 (x = -90 度) は角度の境界なので、向きのベクトルで確かめる。光は真下に近い向きに進む
	check((-sun.global_transform.basis.z).y < -0.9, "昼は太陽が高い所にある")
	check(scene.get_node("HUD/Clock").text.begins_with("12:00"), "時計に 12:00 と出る")

	# 時刻を 3 時間ずつ飛ばして、夜にする
	for i in 4:
		day_night.time.jump(3.0)
	day_night._apply()
	check(day_night.time.hour < 1.0 or day_night.time.hour > 23.9, "12 時から 12 時間飛ばすと、0 時になる")
	check(not sun.visible and near(sun.light_energy, 0.0), "夜は太陽が消える")
	check(day_night.environment.fog_density > 0.01, "夜は霧が濃い")
	scene.queue_free()
	await process_frame
