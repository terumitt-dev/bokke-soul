class_name PointWorld
extends Node3D
# 世界を点群として見せる。世界のメッシュの頂点と面の中心を点にして、歩いて確かめた所だけが現れるようにする。
# 確かめた所は RevealMap に書き込み、シェーダーがそれを見て、点とメッシュの見え方を決める。
# このノードは、世界と同じ座標 (原点) に置く。メッシュの当たり判定は、見え方に関係なく残る。
#
# 演出:
#   - 落ちて位置を見失うと (on_lost)、世界の点が散らばって、薄れていく (崩れ)
#   - 篝火へ戻ると (on_rescan)、そこから波が広がり、波が通った所から、点が元の位置へ戻る (再構成)。
#     遠くの点は、波のあと、ゆっくり戻る
#   - 篝火で休むと (on_rest)、同じ波が出る (世界は崩れない)
#   波は、見せ方だけを動かす。確かめた所の地図には、最初から最終の範囲を書き込んでおく
#   - 落ちている間は、画面全体にもノイズがかかる (世界の下へ落ちると、世界の点が視界に入らないため)。
#     波が広がる間に、消える

enum Mode {
	MESH_AND_POINTS,  # 面は、確かめていない所では暗く沈み、その上に点を重ねる
	POINTS_ONLY,  # 面は見えず、点だけで世界を描く
}

const REVEAL_RADIUS := 16.0  # 歩いた周りで、確かめた所になる半径 (m)
const REST_RADIUS := 40.0  # 篝火で休んだ時に、確かめた所になる半径 (m)。歩いた所より、ずっと広い
const PAINT_STEP := 1.5  # これだけ動くたびに、書き込む (m)
const TEXTURE_INTERVAL := 0.1  # 地図をシェーダーへ反映する間隔 (秒)
const COLLAPSE_SECONDS := 0.8  # 落ちてから、世界が崩れ切るまで (秒)
const PULSE_SECONDS := 1.8  # 波が、最大の半径まで広がる時間 (秒)
const PULSE_OVERSHOOT := 1.2  # 波は、書き込んだ半径より少し先まで広がる (倍率)
const PULSE_EDGE := 3.0  # 波の縁の幅 (m)
const RECOVER_SECONDS := 1.2  # 波のあと、遠くの崩れが戻るまで (秒)
const GLITCH_FADE_SECONDS := 1.0  # 復帰してから、画面のノイズが消えるまで (秒)

var mode := Mode.MESH_AND_POINTS
var reveal: RevealMap
var points_instance: MeshInstance3D
var point_count := 0
var disturbance := 0.0  # 世界の崩れ具合 (0〜1)
var glitch := 0.0  # 画面全体のノイズの強さ (0〜1)
var glitch_rect: ColorRect
var pulse_active := false  # 波が広がっている間
var pulse_radius := 0.0  # 波の、いまの半径 (m)
var prev_image: Image  # 波が出る直前の、確かめた所の地図
# 画面全体のノイズの層を作るか。複数のタイルを並べる時は、1 つの点の表現だけが作る (重ねて、何度も描かない)
var glitch_overlay := true
var environment: Environment  # 点だけの方式で、空や霧の明るさに合わせて点の色を決める。渡さなければ、場面の WorldEnvironment を探す

var _meshes: Array = []
var _player: Node3D
var _point_material: ShaderMaterial
var _terrain_material: ShaderMaterial
var _last_paint := Vector3(INF, INF, INF)
var _since_update := 0.0
var _disturbance_target := 0.0
var _glitch_target := 0.0
var _pulse_center := Vector3.ZERO
var _pulse_time := 0.0
var _pulse_max := 0.0
var _rebuild := false  # この波が、落下からの再構成か (そうなら、波が終わったら、崩れを戻し始める)
var _prev_texture: ImageTexture


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
	prev_image = reveal.snapshot()
	_prev_texture = ImageTexture.create_from_image(prev_image)
	for material: ShaderMaterial in [_point_material, _terrain_material]:
		material.set_shader_parameter("reveal_tex", reveal.texture)
		material.set_shader_parameter("prev_reveal_tex", _prev_texture)
		material.set_shader_parameter("reveal_origin", reveal.origin)
		material.set_shader_parameter("reveal_size", reveal.size)
	_terrain_material.set_shader_parameter("albedo", WorldLoader.TERRAIN_COLOR)
	var aerial: Variant = world.get_meta(WorldLoader.AERIAL_META) if world.has_meta(WorldLoader.AERIAL_META) else null
	if aerial is Texture2D:
		# 写真は、地形メッシュの範囲に重なる (西北の角が左上)。範囲は、いまの位置 (ゲームの座標) の、東西 x、南北 z
		_terrain_material.set_shader_parameter("aerial_tex", aerial)
		_terrain_material.set_shader_parameter("aerial_rect", Vector4(bounds.position.x, bounds.position.z, bounds.size.x, bounds.size.z))
		_terrain_material.set_shader_parameter("aerial_mix", 1.0)

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

	if glitch_overlay:
		_add_glitch_overlay()
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


# 保存した地図 (PNG) を戻す。受け付けなければ false。波の前の地図も、戻した地図に合わせる
func restore_reveal(png: PackedByteArray) -> bool:
	if not reveal.load_png(png):
		return false
	prev_image = reveal.snapshot()
	_prev_texture.update(prev_image)
	return true


# 落ちて、位置を見失った。世界が崩れ始め、画面にノイズがかかる (Player が、グループへ知らせる)
func on_lost() -> void:
	# 前回の波の範囲 (半径と、波の前の地図) を引きずらない。引きずると、その円の中は崩れず、
	# 円の外は、古い地図 (前回の波のあとに歩いた所が、まだ未確認のまま) で描かれてしまう。
	# 世界全体が、いまの地図で、一様に崩れるようにする
	pulse_active = false
	pulse_radius = 0.0
	prev_image = reveal.snapshot()
	_prev_texture.update(prev_image)
	_disturbance_target = 1.0
	_glitch_target = 1.0
	_update_effect(0.0)  # 次のフレームを待たず、すぐシェーダーへ伝える (1 フレームだけ古い波の範囲で描かれないように)


# 最後の篝火へ戻った。そこから波が広がって、世界が再構成される (Player が、グループへ知らせる)
func on_rescan(position: Vector3) -> void:
	_glitch_target = 0.0  # 波が広がる間に、画面のノイズが消える
	_start_scan(position, REST_RADIUS, true)


# 篝火で休んだ。ここは確かな場所なので、周囲を広く確かめた所にして、波を出す (Player が、グループへ知らせる)
func on_rest(position: Vector3) -> void:
	_start_scan(position, REST_RADIUS, false)


# position を中心に、radius (m) を確かめた所にして、波を出す。
# 波の最中に、もう一度呼ばれた時 (再構成の最中に休んだ時など) は、前の波は、ここで確定させる
# (前の波がまだ届いていない所は、すぐ確定した表示になる。まず起きない操作なので、許す)。
# 地図には最終の範囲を先に書き込み、波の前の地図を別に残す。シェーダーは、波が通った所だけ、新しい地図を見せる
func _start_scan(position: Vector3, radius: float, rebuild: bool) -> void:
	prev_image = reveal.snapshot()
	_prev_texture.update(prev_image)
	reveal_at(position, radius)
	pulse_active = true
	pulse_radius = 0.0
	_pulse_center = position
	_pulse_time = 0.0
	_pulse_max = radius * PULSE_OVERSHOOT
	# 崩れが残っている間 (再構成の最中に休んだ時など) は、新しい波が終わった時に、崩れを戻し始める。
	# 再構成の印を上書きすると、波が終わっても崩れが戻らず、遠くが崩れたままになる
	_rebuild = rebuild or _disturbance_target > 0.0


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
	_update_effect(delta)
	_point_material.set_shader_parameter("player_position", position)
	_point_material.set_shader_parameter("time_seconds", Time.get_ticks_msec() / 1000.0)
	if mode == Mode.POINTS_ONLY:
		_update_colors()  # 空の明るさは時刻で変わるので、毎フレーム追う


# 画面全体のノイズの層を作る。メッセージ (HUD) より下に置いて、文字が読めるようにする。
# ノイズがない間は隠して、描画の負荷をなくす
func _add_glitch_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.name = "GlitchLayer"
	layer.layer = 0  # HUD は 1。その下
	add_child(layer)
	glitch_rect = ColorRect.new()
	glitch_rect.name = "Glitch"
	glitch_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	glitch_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/glitch.gdshader")
	glitch_rect.material = material
	glitch_rect.visible = false
	layer.add_child(glitch_rect)


# 崩れ具合と波と画面のノイズを進めて、シェーダーへ伝える
func _update_effect(delta: float) -> void:
	var seconds := COLLAPSE_SECONDS if _disturbance_target > disturbance else RECOVER_SECONDS
	disturbance = move_toward(disturbance, _disturbance_target, delta / seconds)

	var glitch_seconds := COLLAPSE_SECONDS if _glitch_target > glitch else GLITCH_FADE_SECONDS
	glitch = move_toward(glitch, _glitch_target, delta / glitch_seconds)
	if glitch_rect != null:
		glitch_rect.visible = glitch > 0.0
	if glitch_rect != null and glitch_rect.visible:
		var glitch_material := glitch_rect.material as ShaderMaterial
		glitch_material.set_shader_parameter("intensity", glitch)
		glitch_material.set_shader_parameter("time_seconds", Time.get_ticks_msec() / 1000.0)

	var ring := 0.0
	if pulse_active:
		_pulse_time += delta
		var progress := clampf(_pulse_time / PULSE_SECONDS, 0.0, 1.0)
		pulse_radius = _pulse_max * (1.0 - pow(1.0 - progress, 2.0))  # 勢いよく出て、だんだんゆっくりになる
		ring = 1.0 - smoothstep(0.7, 1.0, progress)  # 波の光は、終わりに向けて消える
		if progress >= 1.0:
			pulse_active = false
			if _rebuild:
				_disturbance_target = 0.0  # 波が通れなかった遠くの崩れを、ゆっくり戻し始める

	# 波が終わったあとも、遠くの崩れが戻りきるまでは、波の範囲 (内側は修復済み) を保つ。
	# 保たないと、波の内側の点まで、崩れた状態へ戻ってしまう
	var enabled := 1.0 if (pulse_active or disturbance > 0.0) else 0.0
	for material: ShaderMaterial in [_point_material, _terrain_material]:
		material.set_shader_parameter("disturbance", disturbance)
		material.set_shader_parameter("pulse_enabled", enabled)
		material.set_shader_parameter("pulse_center", _pulse_center)
		material.set_shader_parameter("pulse_radius", pulse_radius)
		material.set_shader_parameter("pulse_edge", PULSE_EDGE)
		material.set_shader_parameter("ring_strength", ring)


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
