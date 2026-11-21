extends Node3D
# 点群から作ったメッシュ (GLB) を読み込み、歩けるように当たり判定を付ける

@export var world_scene: PackedScene


func _ready() -> void:
	var world := world_scene.instantiate()
	add_child(world)
	# 当たり判定は片面。メッシュの法線が内向きだと、床を抜けてしまう
	for mesh: MeshInstance3D in world.find_children("*", "MeshInstance3D", true, false):
		mesh.create_trimesh_collision()
