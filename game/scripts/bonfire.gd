extends Node3D
# 篝火 = 測量基準点。休むと、ここが復帰地点になる

const FLICKER_SPEED := 9.0
const DAY_ENERGY := 2.0  # 昼の光の強さ
const NIGHT_ENERGY := 6.0  # 夜の光の強さ
const DAY_RANGE := 8.0
const NIGHT_RANGE := 18.0

var time := 0.0
var darkness := 0.0  # 0 が昼、1 が真っ暗

@onready var light: OmniLight3D = $Light


func _process(delta: float) -> void:
	time += delta
	var base := lerpf(DAY_ENERGY, NIGHT_ENERGY, darkness)
	light.light_energy = base + 0.4 * base / DAY_ENERGY * sin(time * FLICKER_SPEED) * sin(time * 3.7)
	light.omni_range = lerpf(DAY_RANGE, NIGHT_RANGE, darkness)


# 暗さを受け取る (DayNight が、毎フレーム「bonfire」グループへ知らせる)
func set_darkness(value: float) -> void:
	darkness = clampf(value, 0.0, 1.0)


# 復帰する時に立つ位置 (篝火の少し手前)
func rest_position() -> Vector3:
	return global_position + Vector3(0.0, 0.05, 1.5)
