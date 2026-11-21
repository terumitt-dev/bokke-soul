extends Node3D
# 指定した世界 (WorldLoader.resolve_path) を読み込み、当たり判定を付けて、歩けるようにする。
# 指定は起動時の引数: godot --path game res://scenes/world_local.tscn -- --world=/path/to/world.glb

const START_HEIGHT := 2.0

@export var world_path := ""
# 点の表現の方式 (mesh_and_points / points_only / off)。空なら、設定ファイルから読む
@export var point_mode := ""

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

	_add_points(world)


# 点の表現を入れる。歩いた所だけが現れ、まだの所は暗く沈む。off なら入れず、世界は最初から全て見える
func _add_points(world: Node3D) -> void:
	var mode := point_mode if not point_mode.is_empty() else GameSettings.load_from().point_mode
	if mode == "off":
		return
	var points := PointWorld.new()
	points.name = "PointWorld"
	add_child(points)
	points.setup(world, player, PointWorld.Mode.POINTS_ONLY if mode == "points_only" else PointWorld.Mode.MESH_AND_POINTS)


func _fail(text: String) -> void:
	push_error(text)
	message.text = text
	message.visible = true
	# 床がないので、動かしておくと落ちて「再スキャン中」がエラーを上書きしてしまう
	player.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
