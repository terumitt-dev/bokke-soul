class_name PointWorld
extends Node3D
# 世界を点群として見せる。世界のメッシュの頂点と面の中心を点にして、歩いて確かめた所だけが現れるようにする。
# 確かめた所は RevealMap に書き込み、シェーダーがそれを見て、点とメッシュの見え方を決める。
# このノードは、世界と同じ座標 (原点) に置く。メッシュの当たり判定は、見え方に関係なく残る

enum Mode {
	MESH_AND_POINTS,  # 面は、確かめていない所では暗く沈み、その上に点を重ねる
	POINTS_ONLY,  # 面は見えず、点だけで世界を描く
}

const REVEAL_RADIUS := 16.0  # 歩いた周りで、確かめた所になる半径 (m)
const REST_RADIUS := 40.0  # 篝火で休んだ時に、確かめた所になる半径 (m)。歩いた所より、ずっと広い
const PAINT_STEP := 1.5  # これだけ動くたびに、書き込む (m)
const TEXTURE_INTERVAL := 0.1  # 地図をシェーダーへ反映する間隔 (秒)

var mode := Mode.MESH_AND_POINTS
var reveal: RevealMap
var points_instance: MeshInstance3D
var point_count := 0
var environment: Environment  # 点だけの方式で、空や霧の明るさに合わせて点の色を決める。渡さなければ、場面の WorldEnvironment を探す

var _meshes: Array = []
var _player: Node3D
var _point_material: ShaderMaterial
var _terrain_material: ShaderMaterial
var _last_paint := Vector3(INF, INF, INF)
var _since_update := 0.0


# world の中のメッシュから点を作る。player が動いた所を、確かめた所にする
func setup(world: Node3D, player: Node3D, new_mode: Mode = Mode.MESH_AND_POINTS) -> void:
	add_to_group("point_world")  # 篝火で休んだ時などに、Player から知らされる
	global_transform = Transform3D.IDENTITY
	_player = player
	# メッシュのないノードは、点にも当たり判定にも関係ないので、除く
	_meshes = world.find_children("*", "MeshInstance3D", true, false).filter(func(node: Node) -> bool: return (node as MeshInstance3D).mesh != null)

	var bounds := AABB()
	for i in _meshes.size():
		var mesh: MeshInstance3D = _meshes[i]
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	reveal = RevealMap.new(bounds)

	_point_material = ShaderMaterial.new()
	_point_material.shader = load("res://shaders/points.gdshader")
	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = load("res://shaders/terrain_reveal.gdshader")
	for material: ShaderMaterial in [_point_material, _terrain_material]:
		material.set_shader_parameter("reveal_tex", reveal.texture)
		material.set_shader_parameter("reveal_origin", reveal.origin)
		material.set_shader_parameter("reveal_size", reveal.size)
	_terrain_material.set_shader_parameter("albedo", WorldLoader.TERRAIN_COLOR)

	var points := _collect_points()
	point_count = points.size()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var points_mesh := ArrayMesh.new()
	points_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	points_mesh.custom_aabb = bounds.grow(2.0)
	points_instance = MeshInstance3D.new()
	points_instance.name = "Points"
	points_instance.mesh = points_mesh
	points_instance.material_override = _point_material
	points_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(points_instance)

	set_mode(new_mode)
	_update_colors()
	reveal_at(player.global_position)


func set_mode(new_mode: Mode) -> void:
	mode = new_mode
	# 素材は、確かめた所の明るさを変える専用のものに置き換える。いまの地形は単色なので、元の素材は戻さない。
	# 頂点の色や複数の素材を使う世界を扱う時は、元の素材を保っておく仕組みが要る
	for mesh: MeshInstance3D in _meshes:
		mesh.material_override = _terrain_material
		mesh.visible = mode == Mode.MESH_AND_POINTS


# 篝火で休んだ。ここは確かな場所なので、周囲を広く確かめた所にする (Player が、グループへ知らせる)
func on_rest(position: Vector3) -> void:
	reveal_at(position, REST_RADIUS)


# position の周り、radius (m) を確かめた所にして、すぐシェーダーへ反映する
func reveal_at(position: Vector3, radius: float = REVEAL_RADIUS) -> void:
	reveal.paint(position, radius)
	reveal.update_texture()
	_last_paint = position


func _process(delta: float) -> void:
	if _player == null:
		return
	var position := _player.global_position
	# 地図は真上から見たものなので、水平の距離で比べる (その場でジャンプしても、書き込まない)
	if Vector2(position.x - _last_paint.x, position.z - _last_paint.z).length() > PAINT_STEP:
		reveal.paint(position, REVEAL_RADIUS)
		_last_paint = position
	_since_update += delta
	if _since_update >= TEXTURE_INTERVAL:
		reveal.update_texture()
		_since_update = 0.0
	_point_material.set_shader_parameter("player_position", position)
	_point_material.set_shader_parameter("time_seconds", Time.get_ticks_msec() / 1000.0)
	if mode == Mode.POINTS_ONLY:
		_update_colors()  # 空の明るさは時刻で変わるので、毎フレーム追う


# メッシュの頂点と、三角形の中心を、世界の座標の点にする
func _collect_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	for mesh: MeshInstance3D in _meshes:
		var transform := mesh.global_transform
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			for vertex in vertices:
				points.append(transform * vertex)
			for i in range(0, indices.size() - 2, 3):
				points.append(transform * ((vertices[indices[i]] + vertices[indices[i + 1]] + vertices[indices[i + 2]]) / 3.0))
	return points


# 場面の WorldEnvironment (DayNight が、昼夜に合わせて更新するもの) を探す
func _find_environment() -> Environment:
	var found := get_tree().root.find_children("*", "WorldEnvironment", true, false)
	if found.is_empty():
		return null
	return (found[0] as WorldEnvironment).environment


# 点の色。面と点を重ねる時は、背景が地面 (暗い) なので、昼も夜も、明るい色にする。
# 点だけの時は、背景が空なので、空が明るい昼は暗く、暗い夜は明るくする
func _update_colors() -> void:
	var bright := Color(0.92, 0.88, 0.78)
	var dim := Color(0.45, 0.5, 0.62)
	if mode == Mode.POINTS_ONLY:
		if environment == null:
			environment = _find_environment()
	if mode == Mode.POINTS_ONLY and environment != null:
		var day := smoothstep(0.12, 0.4, environment.fog_light_color.get_luminance())
		bright = bright.lerp(Color(0.12, 0.10, 0.08), day)
		dim = dim.lerp(Color(0.3, 0.28, 0.27), day)
	_point_material.set_shader_parameter("point_color", bright)
	_point_material.set_shader_parameter("unexplored_color", dim)
