class_name ColorGrade
extends RefCounted
# 世界全体の見た目の調整。時刻や天気の色 (SkyPalette、Weather) の上から、まとめてかける。
# 5 つの値は独立していて、組み合わせて決められる。何も変えない値は ColorGrade.new() (月明かりだけは 0)。
#
#   saturation: 色の鮮やかさ。0 で白黒、1 で元のまま、1 より大きいと鮮やか (明るさは保つ)
#   sun:        太陽の光の強さの倍率。大きいほど、明暗がはっきりする
#   ambient:    環境光の倍率。小さいほど影が暗くなり、夜は見えにくくなる
#   fog:        霧の濃さの倍率。小さいほど遠くまで見える
#   moon:       月明かりのライトの強さそのもの (昼の太陽の光は 1.4 前後)。0 なら月明かりなし

var saturation := 1.0
var sun := 1.0
var ambient := 1.0
var fog := 1.0
var moon := 0.0


# このゲームの見た目 (A 現在、B くすんだ・乾いた、C 劇的 を見比べて、B と強い月明かりを選んだ)。
# 色を抜いた乾いた世界で、夜は月明かりで歩ける。地形の色は WorldLoader.TERRAIN_COLOR
static func look() -> ColorGrade:
	return make(0.55, 0.9, 1.0, 1.1, 0.6)


static func make(
	saturation_value: float, sun_value: float, ambient_value: float, fog_value: float, moon_value: float = 0.0
) -> ColorGrade:
	var grade := ColorGrade.new()
	grade.saturation = saturation_value
	grade.sun = sun_value
	grade.ambient = ambient_value
	grade.fog = fog_value
	grade.moon = moon_value
	return grade


# 色の鮮やかさを変える。明るさ (輝度) は保つ
func apply_saturation(color: Color) -> Color:
	var gray := color.get_luminance()
	return Color(
		maxf(lerpf(gray, color.r, saturation), 0.0),
		maxf(lerpf(gray, color.g, saturation), 0.0),
		maxf(lerpf(gray, color.b, saturation), 0.0),
		color.a
	)
