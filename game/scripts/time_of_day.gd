class_name TimeOfDay
extends RefCounted
# ゲームの中の時刻。昼夜に使う 0〜24 時の hour と、天気に使う通しの時間 weather_hours を持つ。
# 昼夜は、遊ぶ人のローカル時刻で変わる (実時間の方式では、パソコンのタイムゾーンに合わせる)。
# 天気は、世界共通の時刻 (UTC) から決める。同じ瞬間なら、どこの誰のパソコンでも同じ天気になる

const HOURS := 24.0

var settings: GameSettings
var offset_hours := 0.0  # 開発用に時刻を飛ばした分。どの方式でも足される

var _total := 0.0  # 昼夜に使う、通しの時間 (時間単位)。実時間の方式では、ローカル時刻
var _utc_hours := 0.0  # 実時間の方式で、1970 年からの UTC での時間 (時間単位)
var _bias_minutes: Variant = null  # テスト用。タイムゾーンの UTC からのずれ (分) を差し替える

var hour: float:
	get:
		return fposmod(_total + offset_hours, HOURS)

var total_hours: float:
	get:
		return _total + offset_hours

# 天気の枠を決めるための、通しの時間。実時間の方式では UTC (タイムゾーンに依存しない)。
# それ以外の方式では、total_hours と同じ
var weather_hours: float:
	get:
		return (_utc_hours if settings.time_mode == "realtime" else _total) + offset_hours


func _init(game_settings: GameSettings, zone_bias_minutes: Variant = null) -> void:
	settings = game_settings
	_bias_minutes = zone_bias_minutes
	match settings.time_mode:
		"realtime":
			_update_realtime()
		"fixed":
			_total = settings.fixed_hour
		_:
			_total = settings.start_hour


# seconds 秒ぶん進める
func advance(seconds: float) -> void:
	match settings.time_mode:
		"realtime":
			_update_realtime()
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


func _update_realtime() -> void:
	_utc_hours = realtime_utc_hours()
	_total = _utc_hours + _zone_bias_minutes() / 60.0


func _zone_bias_minutes() -> float:
	if _bias_minutes != null:
		return float(_bias_minutes)
	return float(Time.get_time_zone_from_system().bias)


# 遊んでいる人のパソコンの、いまの時刻 (0〜24 時)
static func realtime_hour() -> float:
	var zone := Time.get_time_zone_from_system()
	return fposmod(realtime_utc_hours() + zone.bias / 60.0, HOURS)


# 1970 年からの、UTC での通しの時間。同じ瞬間なら、世界のどこでも同じ値になる
static func realtime_utc_hours() -> float:
	return Time.get_unix_time_from_system() / 3600.0
