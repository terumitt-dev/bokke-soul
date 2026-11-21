extends Node3D
# 指定した世界 (WorldLoader.resolve_path) を読み込み、当たり判定を付けて、歩けるようにする。
# 指定は起動時の引数: godot --path game res://scenes/world_local.tscn -- --world=/path/to/world.glb

const START_HEIGHT := 2.0

@export var world_path := ""

@onready var player: CharacterBody3D = get_node("../Player")
@onready var message: Label = get_node("../HUD/Message")


func _ready() -> void:
	var loaded := WorldLoader.load_world(WorldLoader.resolve_path(world_path))
	if loaded.node == null:
		_fail(loaded.error)
		return
	var world: Node3D = loaded.node
	add_child(world)

	# 当たり判定は片面。メッシュの法線が内向きだと、地面を抜けてしまう
	var meshes := world.find_children("*", "MeshInstance3D", true, false)
	var bounds := AABB()
	for i in meshes.size():
		var mesh: MeshInstance3D = meshes[i]
		mesh.create_trimesh_collision()
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)

	# 世界の中央に一番近い地面の上空から降りる (中央に穴があっても、地面のある所に降りる)
	var start := WorldLoader.pick_start(meshes, bounds.get_center())
	start.y += START_HEIGHT
	player.global_position = start
	player.spawn_position = start


func _fail(text: String) -> void:
	push_error(text)
	message.text = text
	message.visible = true
	# 床がないので、動かしておくと落ちて「再スキャン中」がエラーを上書きしてしまう
	player.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
