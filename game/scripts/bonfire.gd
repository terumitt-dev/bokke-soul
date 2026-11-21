extends Node3D
# 篝火 = 測量基準点。休むと、ここが復帰地点になる

const FLICKER_SPEED := 9.0
const BASE_ENERGY := 2.0

var time := 0.0

@onready var light: OmniLight3D = $Light


func _process(delta: float) -> void:
	time += delta
	light.light_energy = BASE_ENERGY + 0.4 * sin(time * FLICKER_SPEED) * sin(time * 3.7)


# 復帰する時に立つ位置 (篝火の少し手前)
func rest_position() -> Vector3:
	return global_position + Vector3(0.0, 0.05, 1.5)
