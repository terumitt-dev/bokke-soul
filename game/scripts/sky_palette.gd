class_name SkyPalette
extends RefCounted
# 時刻ごとの空、霧、太陽、環境光 (ambient は色) の値。世紀末の世界なので、色を抜いた砂埃っぽい色味にしてある。
# 時刻と時刻の間は、なめらかにつなぐ。0 時の値は 24 時につながる

const KEYS := [
	# 夜
	{
		"hour": 0.0, "top": Color(0.015, 0.020, 0.035), "horizon": Color(0.040, 0.048, 0.070),
		"fog": Color(0.040, 0.050, 0.075), "fog_density": 0.012,
		"sun_energy": 0.0, "sun_color": Color(0.60, 0.65, 0.80), "ambient": Color(0.120, 0.140, 0.200),
	},
	# 明け方の前
	{
		"hour": 5.0, "top": Color(0.050, 0.060, 0.090), "horizon": Color(0.280, 0.250, 0.250),
		"fog": Color(0.180, 0.160, 0.160), "fog_density": 0.010,
		"sun_energy": 0.0, "sun_color": Color(1.00, 0.70, 0.45), "ambient": Color(0.160, 0.160, 0.200),
	},
	# 夜明け (砂埃で橙がかる)
	{
		"hour": 6.0, "top": Color(0.220, 0.240, 0.280), "horizon": Color(0.620, 0.450, 0.320),
		"fog": Color(0.450, 0.360, 0.300), "fog_density": 0.008,
		"sun_energy": 0.5, "sun_color": Color(1.00, 0.70, 0.45), "ambient": Color(0.300, 0.260, 0.240),
	},
	# 朝
	{
		"hour": 9.0, "top": Color(0.450, 0.500, 0.540), "horizon": Color(0.720, 0.680, 0.580),
		"fog": Color(0.620, 0.580, 0.500), "fog_density": 0.005,
		"sun_energy": 1.1, "sun_color": Color(1.00, 0.92, 0.78), "ambient": Color(0.420, 0.400, 0.360),
	},
	# 昼
	{
		"hour": 12.0, "top": Color(0.500, 0.550, 0.580), "horizon": Color(0.780, 0.740, 0.640),
		"fog": Color(0.680, 0.640, 0.560), "fog_density": 0.004,
		"sun_energy": 1.4, "sun_color": Color(1.00, 0.96, 0.86), "ambient": Color(0.460, 0.440, 0.400),
	},
	# 午後
	{
		"hour": 15.0, "top": Color(0.480, 0.520, 0.550), "horizon": Color(0.760, 0.700, 0.580),
		"fog": Color(0.650, 0.600, 0.510), "fog_density": 0.005,
		"sun_energy": 1.2, "sun_color": Color(1.00, 0.90, 0.72), "ambient": Color(0.420, 0.400, 0.350),
	},
	# 夕暮れ
	{
		"hour": 17.5, "top": Color(0.250, 0.250, 0.300), "horizon": Color(0.700, 0.400, 0.250),
		"fog": Color(0.500, 0.340, 0.260), "fog_density": 0.008,
		"sun_energy": 0.5, "sun_color": Color(1.00, 0.55, 0.30), "ambient": Color(0.320, 0.260, 0.240),
	},
	# 日が沈んだあと
	{
		"hour": 18.5, "top": Color(0.060, 0.065, 0.100), "horizon": Color(0.300, 0.220, 0.220),
		"fog": Color(0.180, 0.140, 0.140), "fog_density": 0.010,
		"sun_energy": 0.0, "sun_color": Color(1.00, 0.55, 0.30), "ambient": Color(0.160, 0.150, 0.190),
	},
	# 夜
	{
		"hour": 21.0, "top": Color(0.015, 0.020, 0.035), "horizon": Color(0.040, 0.048, 0.070),
		"fog": Color(0.040, 0.050, 0.075), "fog_density": 0.012,
		"sun_energy": 0.0, "sun_color": Color(0.60, 0.65, 0.80), "ambient": Color(0.120, 0.140, 0.200),
	},
]


# hour 時の値を返す。hour は 0〜24 (範囲外は 24 で折り返す)
static func sample(hour: float) -> Dictionary:
	var h := fposmod(hour, 24.0)
	var index := 0
	for i in KEYS.size():
		if KEYS[i].hour <= h:
			index = i
	var from: Dictionary = KEYS[index]
	var to: Dictionary = KEYS[(index + 1) % KEYS.size()]
	var from_hour: float = from.hour
	var to_hour: float = to.hour if index + 1 < KEYS.size() else 24.0
	return _blend(from, to, (h - from_hour) / (to_hour - from_hour))


static func _blend(from: Dictionary, to: Dictionary, t: float) -> Dictionary:
	var result := {}
	for key: String in from:
		if key == "hour":
			continue
		var a: Variant = from[key]
		var b: Variant = to[key]
		result[key] = a.lerp(b, t) if a is Color else lerpf(a, b, t)
	return result
