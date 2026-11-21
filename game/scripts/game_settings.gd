class_name GameSettings
extends RefCounted
# ゲームの設定。ローカルの user://settings.cfg から読む。
# 設定ファイルがない、値が不正、といった時は既定値にする (ゲームを止めない)
#
#   [time]
#   mode="accelerated"        ; accelerated = 1 日を短くする / realtime = 実時間 / fixed = 時刻を止める
#   day_length_minutes=60.0   ; accelerated の時、1 日 (昼夜が一巡) を何分にするか
#   start_hour=7.0            ; accelerated の時、始まる時刻 (0〜24)
#   fixed_hour=12.0           ; fixed の時の時刻 (0〜24)
#
#   [weather]
#   enabled=true              ; false なら、いつも晴れ
#   seed=0                    ; 天気の並びを決める種。同じ種なら、同じ時刻は同じ天気になる

const PATH := "user://settings.cfg"
const MODES := ["accelerated", "realtime", "fixed"]
const MIN_DAY_MINUTES := 1.0
const MAX_DAY_MINUTES := 10080.0  # 1 週間
const MAX_SEED := 2147483647

var time_mode := "accelerated"
var day_length_minutes := 60.0
var start_hour := 7.0
var fixed_hour := 12.0
var weather_enabled := true
var weather_seed := 0


static func load_from(path: String = PATH) -> GameSettings:
	var settings := GameSettings.new()
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return settings

	var mode: Variant = file.get_value("time", "mode", settings.time_mode)
	if mode is String and mode in MODES:
		settings.time_mode = mode
	settings.day_length_minutes = _number(
		file.get_value("time", "day_length_minutes", ""), settings.day_length_minutes, MIN_DAY_MINUTES, MAX_DAY_MINUTES
	)
	settings.start_hour = _hour(file.get_value("time", "start_hour", ""), settings.start_hour)
	settings.fixed_hour = _hour(file.get_value("time", "fixed_hour", ""), settings.fixed_hour)

	var enabled: Variant = file.get_value("weather", "enabled", "")
	if enabled is bool:
		settings.weather_enabled = enabled
	var world_seed: Variant = file.get_value("weather", "seed", "")
	if world_seed is int and absi(world_seed) <= MAX_SEED:
		settings.weather_seed = world_seed
	return settings


static func _hour(value: Variant, fallback: float) -> float:
	# 24 は 0 と同じ時刻なので、24 未満に限る
	return _number(value, fallback, 0.0, 23.999)


static func _number(value: Variant, fallback: float, minimum: float, maximum: float) -> float:
	if (value is float or value is int) and is_finite(value) and value >= minimum and value <= maximum:
		return float(value)
	return fallback
