class_name TimeOfDay
extends RefCounted
# ゲームの中の時刻。0〜24 時の hour と、始まってからの通しの時間 total_hours を持つ。
# 天気は total_hours から決める (何日目の何時か、まで同じなら、同じ天気になる)

const HOURS := 24.0

var settings: GameSettings
var offset_hours := 0.0  # 開発用に時刻を飛ばした分。どの方式でも足される

var _total := 0.0  # 通しの時間 (時間単位)

var hour: float:
	get:
		return fposmod(_total + offset_hours, HOURS)

var total_hours: float:
	get:
		return _total + offset_hours


func _init(game_settings: GameSettings) -> void:
	settings = game_settings
	match settings.time_mode:
		"realtime":
			_total = realtime_total_hours()
		"fixed":
			_total = settings.fixed_hour
		_:
			_total = settings.start_hour


# seconds 秒ぶん進める
func advance(seconds: float) -> void:
	match settings.time_mode:
		"realtime":
			_total = realtime_total_hours()
		"fixed":
			_total = settings.fixed_hour
		_:
			_total += seconds / (settings.day_length_minutes * 60.0) * HOURS


# 時刻を hours 時間ぶん飛ばす (開発用)
func jump(hours: float) -> void:
	offset_hours += hours


func format() -> String:
	var total_minutes := int(floor(hour * 60.0))
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]


# 遊んでいる人のパソコンの、いまの時刻 (0〜24 時)
static func realtime_hour() -> float:
	return fposmod(realtime_total_hours(), HOURS)


# 1970 年からの通しの時間 (パソコンの時刻のずれを含む)。同じ時刻なら、誰のパソコンでも同じ値になる
static func realtime_total_hours() -> float:
	var zone := Time.get_time_zone_from_system()
	return (Time.get_unix_time_from_system() + zone.bias * 60.0) / 3600.0
