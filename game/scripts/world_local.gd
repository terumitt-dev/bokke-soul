extends Node3D
# 実行時に指定した GLB (点群や標高グリッドから作った世界) を読み込み、歩けるようにする。
# データはリポジトリに入れないので、取り込みは通さず、起動時に場所を渡す:
#   godot --path game res://scenes/world_local.tscn -- --world=/path/to/world.glb

const ARG_PREFIX := "--world="
const START_HEIGHT := 2.0

@export var world_path := ""

@onready var player: CharacterBody3D = get_node("../Player")
@onready var message: Label = get_node("../HUD/Message")


func _ready() -> void:
	var path := _resolve_path()
	if path.is_empty():
		_fail("世界が指定されていません。起動時に -- --world=<GLB のパス> を付けてください")
		return

	var state := GLTFState.new()
	var error := GLTFDocument.new().append_from_file(path, state)
	if error != OK:
		_fail("読み込めませんでした: %s (エラー %d)" % [path, error])
		return
	var world := GLTFDocument.new().generate_scene(state)
	if world == null:
		_fail("シーンを作れませんでした: " + path)
		return
	add_child(world)
	_convert_importer_meshes(world)

	# 当たり判定は片面。メッシュの法線が内向きだと、地面を抜けてしまう
	var meshes := world.find_children("*", "MeshInstance3D", true, false)
	var bounds := AABB()
	for i in meshes.size():
		var mesh: MeshInstance3D = meshes[i]
		mesh.create_trimesh_collision()
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)

	# 世界の中央の上空から、地面に降り立つ
	var top := bounds.get_center()
	top.y = bounds.end.y + START_HEIGHT
	player.global_position = top
	player.spawn_position = top


# 実行時に GLB を読むと、メッシュは取り込み用の ImporterMeshInstance3D になる。
# 描画も当たり判定も MeshInstance3D が要るので、置き換える
func _convert_importer_meshes(world: Node) -> void:
	for node: ImporterMeshInstance3D in world.find_children("*", "ImporterMeshInstance3D", true, false):
		var instance := MeshInstance3D.new()
		instance.name = node.name
		instance.transform = node.transform
		instance.mesh = node.mesh.get_mesh()
		node.get_parent().add_child(instance)
		node.queue_free()


func _resolve_path() -> String:
	if not world_path.is_empty():
		return world_path
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_PREFIX):
			return arg.trim_prefix(ARG_PREFIX)
	return ""


func _fail(text: String) -> void:
	push_error(text)
	message.text = text
	message.visible = true
