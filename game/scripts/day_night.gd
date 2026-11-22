class_name DayNight
extends Node
# 昼夜と天気。時刻に合わせて、太陽の角度、空、霧、環境光を変え、天気で霧や光を重ねる。
# 同じシーンの WorldEnvironment と、Light (DirectionalLight3D) を動かす (場所は NodePath で変えられる)。
# HUD/Clock があれば、時刻と天気を表示する。
# 開発ビルドでは、T キーで時刻を 3 時間ずつ、Y キーで天気を切り替えられる

const SUN_YAW := -30.0
const MOON_YAW_OFFSET := 55.0  # 月は、太陽と少しずらした向きから照らす
const DEV_JUMP_HOURS := 3.0

@export var environment_path: NodePath = ^"../WorldEnvironment"
@export var sun_path: NodePath = ^"../Light"
@export var clock_path: NodePath = ^"../HUD/Clock"

# テストで差し替えられるように、設定は外から渡せる (なければ、設定ファイルから読む)
var settings: GameSettings
var time: TimeOfDay
var environment: Environment
var sky_material: ProceduralSkyMaterial
var grade := ColorGrade.look()  # 見た目の最終調整。既定はこのゲームの見た目 (ColorGrade.look)
var restore_total_hours := NAN  # セーブから戻す時刻 (通しの時間)。_ready の前に渡す
var forced_weather := ""  # 開発用。種類の id を入れると、その天気に固定する
var weather: Dictionary  # いまの天気の値 (Weather.params_at)

var moon: DirectionalLight3D  # 月明かり。太陽の反対側から、青白く照らす

var _sun: DirectionalLight3D
var _clock: Label


func _ready() -> void:
	if settings == null:
		settings = GameSettings.load_from()
	time = TimeOfDay.new(settings)
	if not is_nan(restore_total_hours):
		time.restore(restore_total_hours)
	environment = (get_node(environment_path) as WorldEnvironment).environment
	_sun = get_node(sun_path)
	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_color = SkyPalette.MOON_COLOR
	moon.visible = false
	add_child(moon)
	_clock = get_node_or_null(clock_path)
	_setup_sky()
	_apply()


func _process(delta: float) -> void:
	time.advance(delta)
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_T:
			time.jump(DEV_JUMP_HOURS)
			_apply()
		elif event.physical_keycode == KEY_Y:
			_cycle_forced_weather()
			_apply()


# 天気を「自動 → 晴れ → 曇り → 砂塵 → 砂嵐 → 自動…」と切り替える
func _cycle_forced_weather() -> void:
	var choices := [""] + Weather.ORDER
	forced_weather = choices[(choices.find(forced_weather) + 1) % choices.size()]


func _setup_sky() -> void:
	sky_material = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	# 環境光は空の色からは取らず、時刻ごとの色で決める (夜の空が暗くても、地面が真っ暗にならない)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_energy = 1.0
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = true


func _apply() -> void:
	var hour := time.hour
	var palette := SkyPalette.sample(hour)
	weather = _current_weather()
	var haze: float = weather.haze
	var haze_color: Color = weather.haze_color

	var horizon := grade.apply_saturation(Weather.tint(palette.horizon, haze_color, haze))
	sky_material.sky_top_color = grade.apply_saturation(Weather.tint(palette.top, haze_color, haze))
	sky_material.sky_horizon_color = horizon
	sky_material.ground_horizon_color = horizon
	sky_material.ground_bottom_color = horizon.darkened(0.5)
	environment.fog_light_color = grade.apply_saturation(Weather.tint(palette.fog, haze_color, haze))
	environment.fog_density = float(palette.fog_density) * float(weather.fog_mult) * grade.fog
	environment.ambient_light_color = grade.apply_saturation(palette.ambient as Color) * float(weather.ambient_mult) * grade.ambient

	var energy := SkyPalette.sun_energy(hour) * float(weather.sun_mult) * grade.sun
	_sun.light_color = grade.apply_saturation(palette.sun_color)
	_sun.light_energy = energy
	_sun.visible = energy > 0.001
	_sun.rotation_degrees = Vector3(-(hour - 6.0) * SkyPalette.SUN_DEGREES_PER_HOUR, SUN_YAW, 0.0)

	# 月明かり。天気で弱まる (砂嵐の夜は、月もかすむ)。太陽が出ている間は消える
	var moon_energy := SkyPalette.moon_level(hour) * grade.moon * float(weather.sun_mult)
	moon.light_energy = moon_energy
	moon.visible = moon_energy > 0.001
	moon.rotation_degrees = Vector3(-(hour - 18.0) * SkyPalette.SUN_DEGREES_PER_HOUR, SUN_YAW + MOON_YAW_OFFSET, 0.0)

	# 篝火は、暗いほど強く、遠くまで光る (昼は目立たず、夜は「確かな場所」として目立つ)
	var darkness := 1.0 - clampf(energy, 0.0, 1.0)
	get_tree().call_group("bonfire", "set_darkness", darkness)

	if _clock:
		_clock.text = "%s  %s" % [time.format(), weather.name]
		if OS.is_debug_build():
			_clock.text += "  (T: +%d 時間 / Y: 天気%s)" % [int(DEV_JUMP_HOURS), "を固定中" if forced_weather != "" else ""]


func _current_weather() -> Dictionary:
	if not settings.weather_enabled:
		return Weather.params_for("clear")
	return Weather.params_at(time.weather_hours, settings.weather_seed, forced_weather)
