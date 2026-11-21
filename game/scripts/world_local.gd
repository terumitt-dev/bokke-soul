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

	# 世界の中央に一番近い地面の上空から降りる (中央に穴があっても、地面のある所に降りる)
	var start := pick_start(meshes, bounds.get_center())
	start.y += START_HEIGHT
	player.global_position = start
	player.spawn_position = start


# target に水平方向で一番近い、メッシュの頂点を返す。頂点は面のあるところにしかない
static func pick_start(meshes: Array, target: Vector3) -> Vector3:
	var best := target
	var best_distance := INF
	for mesh: MeshInstance3D in meshes:
		for surface in mesh.mesh.get_surface_count():
			var vertices: PackedVector3Array = mesh.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var world_vertex := mesh.global_transform * vertex
				var distance := Vector2(world_vertex.x - target.x, world_vertex.z - target.z).length_squared()
				if distance < best_distance:
					best_distance = distance
					best = world_vertex
	return best


# 実行時に GLB を読むと、メッシュは取り込み用の ImporterMeshInstance3D になる。
# 描画も当たり判定も MeshInstance3D が要るので、置き換える
func _convert_importer_meshes(world: Node) -> void:
	for node: ImporterMeshInstance3D in world.find_children("*", "ImporterMeshInstance3D", true, false):
		var parent := node.get_parent()
		if node.mesh == null:
			parent.remove_child(node)
			node.queue_free()
			continue
		var instance := MeshInstance3D.new()
		instance.mesh = node.mesh.get_mesh()
		instance.transform = node.transform
		# 同じ名前のノードが残っていると名前に @ が付くので、先に外す
		var node_name := node.name
		parent.remove_child(node)
		node.queue_free()
		instance.name = node_name
		parent.add_child(instance)


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
	# 床がないので、動かしておくと落ちて「再スキャン中」がエラーを上書きしてしまう
	player.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
