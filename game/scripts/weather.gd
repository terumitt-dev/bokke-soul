class_name Weather
extends RefCounted
# 天気。時刻から決まる疑似乱数で切り替える (ネットワークは使わない)。
# 通しの時間を SLOT_HOURS ごとの「枠」に区切り、枠ごとに天気を 1 つ決める。
# 同じ種 (seed) と同じ枠なら、いつ誰が計算しても同じ天気になる。
# 枠の変わり目では、TRANSITION_HOURS かけてなめらかに移る。

const SLOT_HOURS := 3.0
const TRANSITION_HOURS := 0.5

const ORDER := ["clear", "overcast", "dust", "storm"]

# fog_mult: 霧の濃さの倍率 / sun_mult: 太陽の光の倍率 / ambient_mult: 環境光の倍率
# haze: 空と霧を haze_color の色合いへ寄せる度合い (明るさは変えない)
const TYPES := {
	"clear": {
		"name": "晴れ", "weight": 40,
		"fog_mult": 1.0, "sun_mult": 1.0, "ambient_mult": 1.0, "haze": 0.0, "haze_color": Color(1.0, 1.0, 1.0),
	},
	"overcast": {
		"name": "曇り", "weight": 30,
		"fog_mult": 1.5, "sun_mult": 0.45, "ambient_mult": 0.9, "haze": 0.6, "haze_color": Color(0.78, 0.79, 0.82),
	},
	"dust": {
		"name": "砂塵", "weight": 20,
		"fog_mult": 3.0, "sun_mult": 0.55, "ambient_mult": 0.95, "haze": 0.55, "haze_color": Color(0.78, 0.58, 0.36),
	},
	"storm": {
		"name": "砂嵐", "weight": 10,
		"fog_mult": 7.0, "sun_mult": 0.2, "ambient_mult": 0.8, "haze": 0.75, "haze_color": Color(0.72, 0.50, 0.30),
	},
}


# total_hours 時点の天気の値を返す。forced に種類を渡すと、その天気に固定する (開発用)。
# type は今の枠の天気、name はその日本語名
static func params_at(total_hours: float, world_seed: int, forced: String = "") -> Dictionary:
	if TYPES.has(forced):
		return params_for(forced)
	var slot := slot_of(total_hours)
	var current := type_at_slot(slot, world_seed)
	var previous := type_at_slot(slot - 1, world_seed)
	var into_slot := total_hours - slot * SLOT_HOURS
	var amount := smoothstep(0.0, TRANSITION_HOURS, into_slot)
	var result := _blend(params_for(previous), params_for(current), amount)
	result["type"] = current
	result["name"] = TYPES[current].name
	return result


# 天気 id の値。type と name も入れる
static func params_for(id: String) -> Dictionary:
	var result := {"type": id, "name": TYPES[id].name}
	for key: String in ["fog_mult", "sun_mult", "ambient_mult", "haze", "haze_color"]:
		result[key] = TYPES[id][key]
	return result


static func slot_of(total_hours: float) -> int:
	return int(floorf(total_hours / SLOT_HOURS))


# slot 番目の枠の天気。重み (weight) に応じて選ぶ
static func type_at_slot(slot: int, world_seed: int) -> String:
	var total := 0
	for id: String in ORDER:
		total += int(TYPES[id].weight)
	var roll := _random(slot, world_seed) * total
	var cumulative := 0.0
	for id: String in ORDER:
		cumulative += float(TYPES[id].weight)
		if roll < cumulative:
			return id
	return ORDER[0]


# color を haze_color の色合いへ寄せる。明るさ (輝度) は保つので、夜が明るくなったりしない
static func tint(color: Color, haze_color: Color, amount: float) -> Color:
	var target := haze_color * (color.get_luminance() / maxf(haze_color.get_luminance(), 0.0001))
	target.a = color.a
	return color.lerp(target, amount)


# 枠と種から決まる 0〜1 未満の値。どの環境でも同じ結果になるよう、自前で混ぜる (SplitMix64)
static func _random(slot: int, world_seed: int) -> float:
	var x := slot * 73856093 + world_seed * 19349663
	x += -7046029254386353131  # 0x9E3779B97F4A7C15
	x = (x ^ ((x >> 30) & 0x3FFFFFFFF)) * -4658895280553007687  # 0xBF58476D1CE4E5B9
	x = (x ^ ((x >> 27) & 0x1FFFFFFFFF)) * -7723592293110705685  # 0x94D049BB133111EB
	x = x ^ ((x >> 31) & 0x1FFFFFFFF)
	return float(x & 0xFFFFFFFF) / 4294967296.0


static func _blend(from: Dictionary, to: Dictionary, amount: float) -> Dictionary:
	var result := {}
	for key: String in ["fog_mult", "sun_mult", "ambient_mult", "haze"]:
		result[key] = lerpf(from[key], to[key], amount)
	result["haze_color"] = (from.haze_color as Color).lerp(to.haze_color, amount)
	return result
