class_name DayNight
extends Node
# 昼夜の移り変わり。時刻に合わせて、太陽の角度、空、霧、環境光を変える。
# 同じシーンの WorldEnvironment と、Light (DirectionalLight3D) を動かす。
# HUD/Clock があれば、時刻を表示する。開発中は T キーで時刻を 3 時間ずつ飛ばせる

const SUN_YAW := -30.0
const SUN_DEGREES_PER_HOUR := 15.0  # 6 時に水平線、12 時に真上、18 時に水平線
const DEV_JUMP_HOURS := 3.0

# テストで差し替えられるように、設定は外から渡せる (なければ、設定ファイルから読む)
var settings: GameSettings
var time: TimeOfDay
var environment: Environment
var sky_material: ProceduralSkyMaterial

@onready var world_environment: WorldEnvironment = get_node("../WorldEnvironment")
@onready var sun: DirectionalLight3D = get_node("../Light")
@onready var clock: Label = get_node_or_null("../HUD/Clock")


func _ready() -> void:
	if settings == null:
		settings = GameSettings.load_from()
	time = TimeOfDay.new(settings)
	_setup_sky()
	_apply()


func _process(delta: float) -> void:
	time.advance(delta)
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_T:
		time.jump(DEV_JUMP_HOURS)
		_apply()


func _setup_sky() -> void:
	environment = world_environment.environment
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

	sky_material.sky_top_color = palette.top
	sky_material.sky_horizon_color = palette.horizon
	sky_material.ground_horizon_color = palette.horizon
	sky_material.ground_bottom_color = palette.horizon.darkened(0.5)
	environment.fog_light_color = palette.fog
	environment.fog_density = palette.fog_density
	environment.ambient_light_color = palette.ambient

	sun.light_color = palette.sun_color
	sun.light_energy = palette.sun_energy
	sun.visible = palette.sun_energy > 0.001
	sun.rotation_degrees = Vector3(-(hour - 6.0) * SUN_DEGREES_PER_HOUR, SUN_YAW, 0.0)

	if clock:
		clock.text = "%s  (T: +%d 時間)" % [time.format(), int(DEV_JUMP_HOURS)]
