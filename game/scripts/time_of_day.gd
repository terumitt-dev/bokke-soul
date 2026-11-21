class_name TimeOfDay
extends RefCounted
# ゲームの中の時刻 (0〜24 時)。設定に合わせて進める

const HOURS := 24.0

var settings: GameSettings
var offset_hours := 0.0  # 開発用に時刻を飛ばした分。どの方式でも足される

var _base_hour := 0.0

var hour: float:
	get:
		return fposmod(_base_hour + offset_hours, HOURS)


func _init(game_settings: GameSettings) -> void:
	settings = game_settings
	match settings.time_mode:
		"realtime":
			_base_hour = realtime_hour()
		"fixed":
			_base_hour = settings.fixed_hour
		_:
			_base_hour = settings.start_hour


# seconds 秒ぶん進める
func advance(seconds: float) -> void:
	match settings.time_mode:
		"realtime":
			_base_hour = realtime_hour()
		"fixed":
			_base_hour = settings.fixed_hour
		_:
			_base_hour = fposmod(_base_hour + seconds / (settings.day_length_minutes * 60.0) * HOURS, HOURS)


# 時刻を hours 時間ぶん飛ばす (開発用)
func jump(hours: float) -> void:
	offset_hours += hours


func format() -> String:
	var total_minutes := int(floor(hour * 60.0))
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]


# 遊んでいる人のパソコンの、いまの時刻
static func realtime_hour() -> float:
	var now := Time.get_time_dict_from_system()
	return now.hour + now.minute / 60.0 + now.second / 3600.0
