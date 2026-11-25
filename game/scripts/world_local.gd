extends Node3D
# 指定した世界 (WorldLoader.resolve_path) を読み込み、当たり判定を付けて、歩けるようにする。
# 指定は起動時の引数: godot --path game res://scenes/world_local.tscn -- --world=/path/to/world.glb
#
# 地域: マップ (タイル) の .json に region (地域の名前) があれば、同じ地域のタイルを、まとめて読み込んで、測量座標の位置に
# 並べる。タイルの間は、暗転も読み込みもなく、歩いて渡れる。タイルごとに、篝火、点の表現、セーブの記録がある。
# 地域の外の隣 (別の地域) への端は「関所」で、越えると、その地域を読み込む (暗転する)。
#
# セーブ: 篝火で休んだ時と、ゲームを閉じる時に、続きの状態 (最後に休んだ篝火、時刻、確かめた所) を保存する。
# 次に始める時は、それを読んで、続きから始める。セーブが壊れていても、新しいバージョンのものでも、ゲームは遊べる
# (壊れていれば退けて新しく始め、新しいバージョンのものは、読まず、上書きもしない)

const START_HEIGHT := 2.0
const START_BONFIRE_DISTANCE := 2.0  # 最初の篝火を、始めた場所の、どれだけ前に置くか (m)
const GROUND_MARGIN := 10.0  # 保存した位置の近くに、地面がある、と見なす水平の距離 (m)
const UNDERGROUND_MARGIN := 2.0  # 保存した位置が、地面より、これ以上深いと、地中と見なす (m)
const FRAME_TOLERANCE := 0.01  # 世界の形が同じ、と見なす差 (m)
const SITE_HEIGHT := 0.5  # 篝火の場所と、その真下・真上の地面の、高さの差として許す (m)
const EXIT_MARGIN := 2.0  # 端から、これ以内に近づくと、隣のマップへ移る (m)
const ARRIVAL_INSET := 6.0  # 隣のマップに着く時の、端からの距離 (m)。EXIT_MARGIN より大きくして、すぐ戻らないようにする
const EXIT_COOLDOWN_MS := 1500  # 着いてから、出口が効くまでの時間
const SAVE_RETRY_MS := 3000  # 保存に失敗して、移るのをやめた時に、もう一度試すまでの時間
const FADE_SECONDS := 0.4
const GAME_SCENE := "res://scenes/world_local.tscn"
const MAX_REGION_TILES := 16  # 1 つの地域で、まとめて読み込むタイルの数の上限 (既定)
const COLLISION_STRIPS := 10  # あとから読み込むタイルの当たり判定を、いくつに分けて作るか (1 つずつ、フレームをあけて作り、画面を止めない)
const STREAM_INTERVAL := 0.3  # 地域の残りのタイルを、1 つ読み込むごとに、あける時間 (秒)。歩きながら、少しずつ読み込む
const FALL_MARGIN := 20.0  # 地域でいちばん低い地面から、これだけ下まで落ちたら、位置を見失う (m)
const NOTICE_SECONDS := 3.0  # 保存に失敗した知らせを出しておく時間 (休んだ知らせより長い)
const CLOSE_HOLD_SECONDS := 8.0  # 閉じる時に保存に失敗した時、終了を保留しておく時間

@export var world_path := ""
# 点の表現の方式 (mesh_and_points / points_only / off)。空なら、設定ファイルから読む
@export var point_mode := ""
# セーブを使うか。設定ファイルの [save] enabled と、ヘッドレスでは無効、も合わせて決まる
@export var save_enabled := true
# 出口で、実際に場面を切り替えるか。テストでは、切り替えずに、引き継ぎ (WorldLoader.arrival) だけを確かめる
var auto_change_scene := true
# 地域で、まとめて読み込むタイルの数の上限。テストでは、小さくして、読み込まなかった隣へ移れることを確かめる
var max_tiles := MAX_REGION_TILES

signal traveled(path: String)
signal tile_loaded(tile_name: String)  # 地域のタイルを 1 つ読み込み終えた
signal region_loaded  # 地域のタイルを、全て読み込み終えた

@onready var player: CharacterBody3D = get_node("../Player")
@onready var message: Label = get_node("../HUD/Message")

# 読み込んだタイル。最初が、始める世界 (原点に置く)。タイルごとの情報 (辞書):
#   path, entry (一覧での情報)、offset (始める世界から見た位置)、world (世界のノード)、meshes、bounds (そのタイルの座標での範囲)、
#   fire (篝火)、points (点の表現)、loaded_reveal (保存から読んだ、確かめた所の地図。点の表現が無効な間も、保存に引き継ぐ)、
#   spawn_local (最後に休んだ位置。そのタイルの座標。なければ null)、visited (遊んだか。遊んだタイルだけ保存する)
var _planned_ids := {}  # 読み込む予定のタイルの世界の名前 (まだ読み込んでいないものも)。これらの間は、歩いて渡れる (関所ではない)
var _unready := {}  # 当たり判定が、まだできていないタイルの範囲 (世界の場所 → Rect2。始める世界の座標の、水平の範囲)
var _last_safe := Vector3.ZERO  # 最後に、立っていてよい所にいた位置 (まだできていないタイルへ入りそうな時の、戻り先)
var _pending: Array[Dictionary] = []  # まだ読み込んでいないタイル (始める世界から近い順)
var _streaming := false
var _tiles: Array[Dictionary] = []
var _current := 0  # いま、プレイヤーがいるタイル
var _entries: Array[Dictionary] = []  # 置き場の、遊べるマップの一覧
var _points: PointWorld  # 始める世界の点の表現
var _bounds := AABB()  # 始める世界の範囲 (セーブに入れて、世界が作り直されたかを知るのに使う)
var _save_active := false
var _close_held := false  # 保存に失敗して、終了を保留している間
var _path := ""  # 始める世界の場所
var _entry := {}  # いま、プレイヤーがいるタイルの、一覧 (WorldRegistry) での情報
var _exits := {}  # 関所 (いまのタイルの端から行ける、別の地域のマップ。方角 → 情報)
var _arrival := {}  # 前のマップから引き継いだもの (WorldLoader.arrival)
var _setup_points_position := Vector3.ZERO  # 探索地図を作った時の、プレイヤーの位置 (着く位置で作られたかを、テストで確かめる)
var _arrived_at := 0  # 着いた時刻 (ミリ秒)
var _traveling := false
var _overlay: CanvasLayer
var _veil: ColorRect
var _veil_label: Label
var _menu: TravelMenu
var _menu_destinations: Array[Dictionary] = []


func _ready() -> void:
	_path = WorldLoader.resolve_path(world_path)
	_arrival = WorldLoader.arrival  # 引き継ぎは、ここで受け取って、空にする (次に始める時に、残らないように)
	WorldLoader.arrival = {}
	_entries = WorldRegistry.scan(_path.get_base_dir())

	# 始める世界と、同じ地域のタイルを、まとめて読み込む。始める世界を原点に置き、ほかは、測量座標の位置に並べる
	var home_entry := _entry_by_id(WorldLoader.world_id_for(_path))
	var plan: Array[Dictionary] = [{"path": _path, "entry": home_entry, "offset": Vector3.ZERO}]
	if not home_entry.is_empty() and home_entry.region != "":
		for other in _entries:
			if plan.size() >= max_tiles:
				push_warning("地域のタイルが多すぎるので、%d 個までにします。残りの隣へは、関所で移ります" % max_tiles)
				break
			if other.region == home_entry.region and other.world_id != home_entry.world_id:
				plan.append({"path": other.path, "entry": other, "offset": WorldRegistry.convert_position(other, home_entry, Vector3.ZERO)})
	for item in plan:
		_planned_ids[item.entry.get("world_id", "")] = true
	var home := _load_tile(plan[0], true)
	if home.is_empty():
		return  # 始める世界が読めない (_load_tile が、知らせた)
	_tiles.append(home)
	_bounds = home.bounds
	# 残りのタイルは、始める世界から近い順に、あとで、歩きながら読み込む (始めるまでの待ちを、始める世界の分だけにする)
	_pending.assign(plan.slice(1))
	for item in _pending:
		# 当たり判定ができるまで、入れない範囲 (測量座標の大きさから。東西は x、南北は、北が -z)
		var size: Vector3 = item.entry.size
		var offset: Vector3 = item.offset
		_unready[item.path] = Rect2(offset.x, offset.z - size.z, size.x, size.z)
	_pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a.offset as Vector3).length() < (b.offset as Vector3).length())

	# 始める世界の篝火 (データの .json の bonfire) があれば、そこから始まる。
	# なければ、世界の中央に一番近い地面の上空から降りて、すぐ前に篝火を置く (中央に穴があっても、地面のある所に降りる)
	var area_fire: Node3D = home.fire
	if area_fire != null:
		player.global_position = area_fire.rest_position() + Vector3(0.0, START_HEIGHT, 0.0)
		player.spawn_position = area_fire.rest_position()
	else:
		var start := WorldLoader.pick_start(home.meshes, _bounds.get_center())
		start.y += START_HEIGHT
		player.global_position = start
		player.spawn_position = start
		home["fire"] = _add_start_bonfire(home.meshes, start)  # 始まりの篝火も、タイルの篝火として、火の状態を持つ
	_update_fall_limit()

	_place_arrival(home.meshes)
	_setup_points_position = player.global_position  # テスト用: 探索地図を作る時の、プレイヤーの位置
	_last_safe = player.global_position
	home["points"] = _add_points(home.world, true)
	_points = home.points
	_setup_save()
	_update_current(true)
	_finish_arrival()
	player.travel_requested.connect(_on_travel_requested)
	if not _pending.is_empty():
		_stream_tiles()


# 地域の残りのタイルを、1 つずつ読み込む。読み込みは、数百ミリ秒、画面が止まるので、あけて (STREAM_INTERVAL)、
# その間は、歩ける。読み込んだタイルは、篝火、点の表現、セーブの記録を付けて、つなぐ
func _stream_tiles() -> void:
	_streaming = true
	while not _pending.is_empty():
		await get_tree().create_timer(STREAM_INTERVAL).timeout
		if not is_inside_tree() or _pending.is_empty():
			break
		var plan: Dictionary = _pending.pop_front()
		var tile := _load_tile(plan, false)
		if tile.is_empty():
			# 読み込めなかった。歩いて渡れる予定から外して、そちらの端を、関所に戻す (空白のまま、残さない)
			_planned_ids.erase(plan.entry.get("world_id", ""))
			_unready.erase(plan.path)
			_exits = _gates_of(_entry)
			continue
		await _build_collision(tile.meshes)
		if not is_inside_tree():
			break  # 待っている間に、場面を離れた
		_tiles.append(tile)
		_unready.erase(plan.path)  # 当たり判定ができたので、入れる
		_attach_tile(tile)
	_streaming = false
	region_loaded.emit()


# 当たり判定 (面ごとの三角形の形) を、少しずつ作る。三角形を、東西に COLLISION_STRIPS 本の帯に分ける作業は、別のスレッドで行い、
# 帯ごとの形は、1 フレームに 1 つずつ作る (24 万の三角形を、1 度に作ると、数百ミリ秒、画面が止まる)
func _build_collision(meshes: Array) -> void:
	for mesh: MeshInstance3D in meshes:
		var strips: Array = []  # 別のスレッドが、ここへ結果を入れる (タスクごとの入れ物なので、並べて走らせても、混ざらない)
		var task := WorkerThreadPool.add_task(_split_faces.bind(mesh.mesh, strips))
		while not WorkerThreadPool.is_task_completed(task):
			if not is_inside_tree():
				WorkerThreadPool.wait_for_task_completion(task)
				return
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(task)
		if not is_inside_tree() or not is_instance_valid(mesh) or not mesh.is_inside_tree():
			return
		var body := StaticBody3D.new()
		mesh.add_child(body)
		for faces: PackedVector3Array in strips:
			if faces.is_empty():
				continue
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(faces)
			var collider := CollisionShape3D.new()
			collider.shape = shape
			body.add_child(collider)
			if not is_inside_tree():
				return
			await get_tree().process_frame


# 別のスレッドで、メッシュの三角形を、x (東西) の帯に分けて、strips に入れる
func _split_faces(mesh: Mesh, strips: Array) -> void:
	var faces := mesh.get_faces()
	var low := INF
	var high := -INF
	for vertex in faces:
		low = minf(low, vertex.x)
		high = maxf(high, vertex.x)
	var width := maxf(high - low, 0.001)
	for i in COLLISION_STRIPS:
		strips.append(PackedVector3Array())
	for i in range(0, faces.size() - 2, 3):
		var center_x := (faces[i].x + faces[i + 1].x + faces[i + 2].x) / 3.0
		var strip: PackedVector3Array = strips[clampi(int((center_x - low) / width * COLLISION_STRIPS), 0, COLLISION_STRIPS - 1)]
		strip.append(faces[i])
		strip.append(faces[i + 1])
		strip.append(faces[i + 2])


# 地域のタイルを全て読み込み終えたか (読み込み中でなく、残りもない)
func is_region_loaded() -> bool:
	return _pending.is_empty() and not _streaming


# 読み込んだ、始める世界以外のタイルに、篝火、点の表現、セーブの記録を付ける
func _attach_tile(tile: Dictionary) -> void:
	# 篝火の場所がない (または、作り直した世界で、使えない) タイルにも、代わりの篝火を置く
	# (歩いて入ったタイルでも、休んで、復帰地点を決められる。始める場所によって、篝火の有無が変わらない)
	if tile.fire == null:
		var center: Vector3 = tile.bounds.get_center() + tile.offset
		tile["fire"] = _add_start_bonfire(tile.meshes, WorldLoader.pick_start(tile.meshes, center), "StartBonfire_" + tile.path.get_file().get_basename())
	_update_fall_limit()
	tile["points"] = _add_points(tile.world, false)
	if _save_active:
		var result := SaveGame.read(tile.path)
		if result.status == "unavailable":
			# このタイルの古いセーブを、新しい形に直せなかった。復元しないまま、そのタイルで保存して、古い進行を置き換えないよう、保存せずに遊ぶ
			push_warning("隣のタイルの古いセーブを読み込めなかったので、保存しません: " + tile.path)
			_save_active = false
			_notify("古いセーブを読み込めませんでした。このあいだは、保存しません")
		elif result.status == "ok":
			_apply_tile_save(tile, result.state, false)
	tile.fire.add_to_group("bonfire")  # タイルを登録し、記録を戻したので、休めるようにする
	tile.fire.visible = true
	tile_loaded.emit(tile.entry.get("name", ""))


# 落ちた、と見なす高さ: 読み込んだタイルのうち、いちばん低い地面の下。標高の低いタイルへ歩いて降りただけで、位置を見失わないように。
# タイルを読み込むたびに、決め直す (低くなる方へだけ動く)
func _update_fall_limit() -> void:
	var lowest := INF
	for tile in _tiles:
		lowest = minf(lowest, tile.offset.y + tile.bounds.position.y)
	player.fall_limit = minf(player.fall_limit, lowest - FALL_MARGIN)  # 既定 (-20) より高くはしない


# 1 つのタイルを読み込む: 世界、当たり判定、篝火。読めなければ、空 (始める世界なら、画面に知らせる)
func _load_tile(plan: Dictionary, is_home: bool) -> Dictionary:
	var loaded := WorldLoader.load_world(plan.path)
	if loaded.node == null:
		if is_home:
			_fail(loaded.error)
		else:
			push_warning("地域のタイルを読み込めませんでした。使いません: " + loaded.error)
		return {}
	var world: Node3D = loaded.node
	var offset: Vector3 = plan.offset
	world.position = offset  # 木に入れる前に置く (入れてからの座標が、位置の通りになる)
	add_child(world)

	# 当たり判定は片面。メッシュの法線が内向きだと、地面を抜けてしまう
	var meshes := world.find_children("*", "MeshInstance3D", true, false)
	var bounds := AABB()
	for i in meshes.size():
		var mesh: MeshInstance3D = meshes[i]
		if is_home:
			mesh.create_trimesh_collision()  # 始める世界は、すぐ立つので、ここで作る (あとから読み込むタイルは、_build_collision で、少しずつ作る)
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	bounds.position -= offset  # そのタイルの座標での範囲にする (セーブに入れる範囲は、そのタイルの座標)
	var fire := _add_area_bonfire(plan.path, meshes, offset)
	if fire != null and not is_home:
		# あとから読み込むタイルの篝火は、タイルを登録し、記録を戻すまで (_attach_tile)、休めない・見えない状態にする
		# (その前に休むと、どのタイルの篝火か分からず、休んだ記録が、失われる)
		fire.remove_from_group("bonfire")
		fire.visible = false
	return {
		"path": plan.path, "entry": plan.entry, "offset": offset, "world": world, "meshes": meshes, "bounds": bounds,
		"fire": fire, "points": null, "loaded_reveal": "", "spawn_local": null,
		"visited": is_home, "dirty": true, "state_cache": null, "saved_revision": -2,
		"encoded": 0,  # テスト用の数: 探索地図を PNG にした回数 (保存で、使い回されたかを確かめる)
	}


func _entry_by_id(id: String) -> Dictionary:
	for entry in _entries:
		if entry.world_id == id:
			return entry
	return {}


# 当たり判定が、まだできていないタイルへは、入れない (入ると、床がなく、落ちる)。入りそうな時は、最後に立っていた位置へ戻す。
# 読み込み済みのタイルの上にいる間は、境目の線の上でも、そのまま
func _keep_out_of_unready() -> void:
	var position := player.global_position
	if not _unready.is_empty() and _tile_at(position).is_empty():
		for path: String in _unready:
			if (_unready[path] as Rect2).has_point(Vector2(position.x, position.z)):
				player.global_position = _last_safe
				player.velocity = Vector3.ZERO
				return
	_last_safe = position


# いま、プレイヤーがいるタイルを決める (範囲の中にいるタイル。どこにもいなければ、そのまま)。変わったら、関所を調べ直して、
# そのタイルを、遊んだことにする (遊んだタイルだけ保存する)。first は、始まった時 (名前の知らせは出さない)
func _update_current(first := false) -> void:
	var index := _current
	if first or not _contains_xz(_tiles[_current], player.global_position):  # いまのタイルの中なら、そのまま (継ぎ目の線の上で、切り替わらない)
		for i in _tiles.size():
			if _contains_xz(_tiles[i], player.global_position):
				index = i
				break
	if not first and index == _current:
		return
	_current = index
	var tile: Dictionary = _tiles[_current]
	tile["visited"] = true
	_entry = tile.entry
	_exits = _gates_of(_entry)
	if not first and _entry.get("name", "") != "":
		_notify(_entry.name)  # 入ったタイルの名前


# 関所: entry のタイルの端から行ける、読み込まないマップ。読み込む予定のタイル (同じ地域。読み込み中を含む) は、歩いて渡れるので、関所ではない
# (地域のタイルが多くて、読み込みの上限で外れた隣は、関所として、場面を切り替えて移る)
func _gates_of(entry: Dictionary) -> Dictionary:
	var gates := {}
	if entry.is_empty():
		return gates
	var near := WorldRegistry.neighbors(_entries, entry)
	for direction: String in near:
		if not _planned_ids.has(near[direction].world_id):  # 読み込む予定 (読み込み中を含む) のタイルは、関所ではない
			gates[direction] = near[direction]
	return gates


# 前のマップから移ってきたなら、着く位置を決めて、そこに立たせる (探索地図を作る前に。作る時の位置を、着く位置にするため。
# 先に、いつもの始まりの位置を使うと、行っていない所が、探索済みになる)。着く位置の地面の高さに合わせる
# (傾斜のある所で、地面に埋まらない、高く浮きすぎない)。引き継ぎが不正なら、何もしない
func _place_arrival(meshes: Array) -> void:
	_arrived_at = Time.get_ticks_msec()
	if not (_arrival.get("position") is Vector3):
		_arrival = {}
		return
	var position: Vector3 = _arrival.position
	var ground := position.y - START_HEIGHT  # 前のマップで立っていた高さに、いちばん近い面を選ぶ
	var heights := WorldLoader.surface_heights(meshes, position.x, position.z)
	if not heights.is_empty():
		heights.sort_custom(func(a: float, b: float) -> bool: return absf(a - ground) < absf(b - ground))
		ground = heights[0]
		position.y = ground + START_HEIGHT
	else:
		# 着く所に面がない (地形の穴)。一番近い地面へ寄せる (穴の上に立つと、落ちて、同じ位置へ戻ることを繰り返す)
		var nearest := WorldLoader.pick_start(meshes, position)
		ground = nearest.y
		position = Vector3(nearest.x, nearest.y + START_HEIGHT, nearest.z)
	_arrival["landing"] = position
	_arrival["ground"] = ground
	player.global_position = position
	player.velocity = Vector3.ZERO
	player.pivot.rotation.y = float(_arrival.get("yaw", player.pivot.rotation.y))
	player.pivot.rotation.x = float(_arrival.get("pitch", player.pivot.rotation.x))


# 保存を読んだあとの仕上げ (保存した位置に立たせる処理があるので、そのあと、もう一度、着く位置に立たせる)。
# 篝火で休んだことがあるマップは、復帰地点は、保存した篝火のまま。まだなら、着いた位置。時刻を引き継ぎ、暗転から戻す
func _finish_arrival() -> void:
	if not _arrival.has("landing"):
		return
	var landing: Vector3 = _arrival.landing
	player.global_position = landing
	player.velocity = Vector3.ZERO
	if not player.has_rested:
		player.spawn_position = Vector3(landing.x, float(_arrival.ground) + 0.05, landing.z)
	if _points != null:
		_points.reveal_at(landing)  # 保存した地図を戻したあとで、着いた所の周りを、探索済みにする (戻した地図に、着いた所は、ない)
	if _arrival.has("time"):
		_apply_time(_arrival.time)
	if _entry.get("name", "") != "":
		_notify.call_deferred(_entry.name)  # 着いたマップの名前
	_ensure_veil()
	_veil.modulate.a = 1.0
	_fade(0.0)  # 暗転から、戻す


func _physics_process(_delta: float) -> void:
	if _tiles.is_empty():
		return
	_keep_out_of_unready()
	_update_current()
	if _traveling or _exits.is_empty() or player.rescanning:
		return
	if Time.get_ticks_msec() < _arrived_at + EXIT_COOLDOWN_MS:
		return
	var direction := WorldRegistry.edge_toward(_entry, player.global_position - _tiles[_current].offset, EXIT_MARGIN, _exits)
	if not direction.is_empty():
		_travel(direction)


# 隣のマップへ移る。いまの様子を保存して、暗転して、行き先と、着く位置 (測量座標で同じ場所を、端から少し内側へ) を引き継ぐ
func _travel(direction: String) -> void:
	_traveling = true
	var target: Dictionary = _exits[direction]
	var local_position: Vector3 = player.global_position - _tiles[_current].offset  # いまのタイルの座標
	var position := WorldRegistry.clamp_inside(target, WorldRegistry.convert_position(_entry, target, local_position), ARRIVAL_INSET)
	position.y += START_HEIGHT  # 少し上から降りる (面の高さは、着いてから、床が受ける)
	await _depart(target, position)


# 別の地域のマップ target へ、position (target の座標) に着くように移る。呼ぶ側が、_traveling を立てておく。
# いまの様子を保存して、暗転して、行き先と、着く位置を引き継ぎ、場面を切り替える
func _depart(target: Dictionary, position: Vector3) -> void:
	# 保存してから移る。最後に遊んだエリアは、行き先にする (着いてから一度も保存しないまま終わっても、行き先から始まる)。
	# 保存に失敗したら、移らない (いまのマップの探索が、静かに失われないように)。しばらくしてから、もう一度試す
	if _save_active and not (save_now() and SaveGame.set_current_area(target.path)):
		_traveling = false
		_arrived_at = Time.get_ticks_msec() + SAVE_RETRY_MS - EXIT_COOLDOWN_MS
		return
	var carried := {
		"path": target.path,
		"position": position,
		"yaw": player.pivot.rotation.y,
		"pitch": player.pivot.rotation.x,
		"from": _entry.get("name", ""),
	}
	var day_night := get_node_or_null("../DayNight")
	if day_night != null and day_night.time != null and day_night.settings.time_mode == "accelerated":
		carried["time"] = day_night.time.total_hours
	WorldLoader.arrival = carried
	_ensure_veil()
	_veil_label.visible = true
	await _fade(1.0)
	traveled.emit(target.path)
	if auto_change_scene and get_tree().change_scene_to_file(GAME_SCENE) != OK:
		# 場面を切り替えられなかった。暗転を戻して、しばらくしてから、もう一度試す
		WorldLoader.arrival = {}
		_traveling = false
		_arrived_at = Time.get_ticks_msec() + SAVE_RETRY_MS - EXIT_COOLDOWN_MS
		_veil_label.visible = false
		_fade(0.0)


# 篝火の移動: 火を灯した篝火の近くで、移動の操作をすると、行き先の一覧を開く。選ぶと、その篝火へ移る。
# 同じ地域の篝火へは、暗転して、その場へ。別の地域の篝火へは、場面を切り替えて移る (読み込む)。
# 移るだけで、復帰地点は変えない (休むのは、別の操作)
func _on_travel_requested(here: Node3D) -> void:
	if _traveling or (_menu != null and _menu.is_open()):
		return
	_menu_destinations = _travel_destinations(here)
	if _menu_destinations.is_empty():
		_notify("移れる篝火は、まだありません")
		return
	var names: Array[String] = []
	for destination in _menu_destinations:
		names.append(destination.label)
	_menu = TravelMenu.new()
	add_child(_menu)
	player.input_blocked = true
	_menu.chosen.connect(_on_travel_chosen)
	_menu.closed.connect(func() -> void: player.input_blocked = false)
	_menu.open(names)


func _on_travel_chosen(index: int) -> void:
	player.input_blocked = false
	if index >= 0 and index < _menu_destinations.size():
		_go_to(_menu_destinations[index])


# 移れる篝火の一覧 (火を灯した、ここ以外の篝火)。読み込んだタイルは、いまの火の状態。読み込んでいないマップは、セーブの記録。
# 同じ地域で、読み込み中のタイルは、まだ移れない
func _travel_destinations(here: Node3D) -> Array[Dictionary]:
	var lit := SaveGame.lit_areas() if _save_active else {}
	var result: Array[Dictionary] = []
	for entry in _entries:
		var tile := _tile_of(entry)
		var spawn := Vector3.ZERO
		if not tile.is_empty():
			if tile.fire == here or tile.fire == null or not tile.fire.lit:
				continue
		elif _planned_ids.has(entry.world_id) or not lit.has(entry.world_id):
			continue
		else:
			spawn = lit[entry.world_id]
		var label: String = "%sの篝火" % entry.name if entry.name != "" else entry.world_id
		result.append({"entry": entry, "tile": tile, "spawn": spawn, "label": label})
	return result


func _tile_of(entry: Dictionary) -> Dictionary:
	for tile in _tiles:
		if tile.entry.get("world_id", "") == entry.world_id:
			return tile
	return {}


# destination へ移る。読み込んだタイルなら、暗転して、その篝火のそばへ。そうでなければ、そのマップへ、場面を切り替えて
func _go_to(destination: Dictionary) -> void:
	_traveling = true
	if destination.tile.is_empty():
		await _depart(destination.entry, destination.spawn + Vector3(0.0, START_HEIGHT, 0.0))
		return
	_ensure_veil()
	_veil_label.visible = false  # 同じ地域の中は、読み込まないので、「読み込み中」は出さない
	await _fade(1.0)
	var fire: Node3D = destination.tile.fire
	var landing: Vector3 = fire.rest_position() + Vector3(0.0, 0.5, 0.0)
	player.global_position = landing
	player.velocity = Vector3.ZERO
	_last_safe = landing
	_update_current()
	_arrived_at = Time.get_ticks_msec()  # 着いた直後は、端の出口が効かない
	await _fade(0.0)
	_traveling = false


# 暗転の幕。画面全体を覆う黒と、「読み込み中」の文字
func _ensure_veil() -> void:
	if _overlay != null:
		return
	_overlay = CanvasLayer.new()
	_overlay.layer = 100
	add_child(_overlay)
	_veil = ColorRect.new()
	_veil.color = Color.BLACK
	_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_veil.modulate.a = 0.0
	_overlay.add_child(_veil)
	_veil_label = Label.new()
	_veil_label.text = "読み込み中…"
	_veil_label.set_anchors_preset(Control.PRESET_CENTER)
	_veil_label.visible = false
	_veil.add_child(_veil_label)


func _fade(alpha: float) -> void:
	_ensure_veil()
	var tween := create_tween()
	tween.tween_property(_veil, "modulate:a", alpha, FADE_SECONDS)
	await tween.finished
	if alpha == 0.0:
		_veil_label.visible = false


func _notification(what: int) -> void:
	# ゲームを閉じる時にも保存する (確かめた所を、休まずに閉じても残す)
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_requested()
	elif what == NOTIFICATION_EXIT_TREE:
		get_tree().auto_accept_quit = true  # 保留のまま、終了の設定を残さない


# 閉じる操作。保存して、そのまま終了する。保存に失敗したら、終了を保留して、知らせる
# (失敗の知らせを読む前に閉じると、最後の保存以降の探索が、静かに失われるため)。
# もう一度閉じれば、保存できなくても、終了する (閉じられなくなることはない)。
# 閉じる操作の通知は、終了の処理より先に届くので、ここで終了の自動受け付けを切れば、保留できる
func _on_close_requested() -> void:
	var saved := save_now()
	var tree := get_tree()
	if _save_active and not saved and not _close_held:
		_close_held = true
		tree.auto_accept_quit = false
		player.notice("セーブに失敗しました。もう一度閉じると、保存せずに終了します", CLOSE_HOLD_SECONDS)
		await tree.create_timer(CLOSE_HOLD_SECONDS).timeout
		if _close_held:  # 保留したまま放っておいた。保留を解く (閉じる操作が、効かなくなったままにならないように)
			_close_held = false
			tree.auto_accept_quit = true
	else:
		_close_held = false
		tree.auto_accept_quit = true


# マップの篝火を置く。場所は、データの .json の bonfire (測量座標)。置けた篝火を返す。
# 場所がない、または、作り直した世界で地面のない所 (範囲の外、地面の中) になる時は、置かず null を返す
func _add_area_bonfire(path: String, meshes: Array, offset: Vector3) -> Node3D:
	var place: Variant = WorldLoader.bonfire_for(path)
	if place != null:
		place += offset  # そのタイルの座標から、始める世界の座標へ
	# 篝火と、復帰する時に立つ位置の両方が、地面の上にあること (作り直した世界で、地面が上がって埋まる、下がって浮く、
	# 範囲の外になる、のどれかなら置かない。立つ位置が埋まると、落ちて、同じ位置へ戻ることを繰り返す)
	if place == null or not _site_is_solid(meshes, place) or not _site_is_solid(meshes, place + Bonfire.REST_OFFSET):
		if place != null:
			push_warning("篝火の場所が、作り直した世界の地面と合わないので、いつもの始まり方にします: " + str(place))
		return null
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	fire.name = "AreaBonfire" if offset == Vector3.ZERO else "AreaBonfire_" + path.get_file().get_basename()  # 始める世界の篝火だけ、決まった名前
	fire.area_name = WorldLoader.name_for(path)
	add_child(fire)
	fire.global_position = place
	return fire


# position が、地面にほぼ接しているか。position の真上か真下に、メッシュの面があり、その高さとの差が SITE_HEIGHT 以内
# (頂点の間隔が広いメッシュでも、面の高さで見る。セーブした位置の判定 _is_on_ground とは違い、埋まるのも、浮くのも許さない)
func _site_is_solid(meshes: Array, position: Vector3) -> bool:
	for height in WorldLoader.surface_heights(meshes, position.x, position.z):
		if absf(position.y - height) <= SITE_HEIGHT:
			return true
	return false


# 最初の基準点として、始めた場所のすぐ前に、篝火を 1 つ置く。ここで休める (休むとセーブされ、落ちたらここへ戻る)。
# 篝火を、世界のあちこちへ置く仕組みは、探索の骨格 (段階4) で作る
func _add_start_bonfire(meshes: Array, start: Vector3, fire_name := "StartBonfire") -> Node3D:
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	fire.name = fire_name
	add_child(fire)
	fire.global_position = WorldLoader.pick_start(meshes, Vector3(start.x, 0.0, start.z - START_BONFIRE_DISTANCE))
	return fire


# 点の表現を入れる。歩いた所だけが現れ、まだの所は暗く沈む。off なら入れず (null を返し)、世界は最初から全て見える。
# first でないタイルは、画面全体のノイズの層を作らない (重ねて、何度も描かないため)
func _add_points(world: Node3D, first := true) -> PointWorld:
	var mode := point_mode if point_mode in GameSettings.POINT_MODES else GameSettings.load_from().point_mode
	if mode == "off":
		return null
	var points := PointWorld.new()
	points.name = "PointWorld" if first else "PointWorld_" + str(world.get_instance_id())
	points.glitch_overlay = first
	add_child(points)
	points.setup(world, player, PointWorld.Mode.POINTS_ONLY if mode == "points_only" else PointWorld.Mode.MESH_AND_POINTS)
	return points


# セーブを使う準備。あれば読んで、続きから始める。篝火で休んだら、保存する。
# 読み込んだタイルごとに、その記録 (篝火に火が灯っているか、確かめた所) を戻す。プレイヤーの位置は、始める世界の記録で決まる
func _setup_save() -> void:
	_save_active = save_enabled and GameSettings.load_from().save_enabled and SaveGame.enabled()
	if not _save_active:
		return
	var result := SaveGame.read(_path)
	if result.status == "newer":
		# 新しいバージョンのゲームで作ったセーブ。読めないし、上書きして壊してもいけない。保存せずに遊ぶ
		push_warning("新しいバージョンのセーブなので、続きからは始めず、保存もしません")
		_save_active = false
		return
	if result.status == "unavailable":
		# 古いセーブを新しい形に直せなかった (ディスクの空きがない時など)。復元しないまま保存して、古い進行を置き換えないよう、保存せずに遊ぶ
		push_warning("古いセーブを読み込めなかったので、続きからは始めず、保存もしません")
		_save_active = false
		_notify.call_deferred("古いセーブを読み込めませんでした。このあいだは、保存しません")
		return
	if result.status == "ok":
		_apply_tile_save(_tiles[0], result.state, true)
	else:
		_apply_time(result.game.get("time_total_hours"))  # 初めて訪れるエリアでも、時刻は続く
	player.rested.connect(_on_rested)


# 休んだ。休んだ篝火があるタイルの、最後に休んだ位置を更新して、保存する
func _on_rested(position: Vector3) -> void:
	var tile := _tile_at(position)
	if not tile.is_empty():
		tile["spawn_local"] = player.spawn_position - tile.offset
		tile["visited"] = true
		tile["dirty"] = true
		if tile.fire != null:
			tile.fire.lit = true
	save_now()


# global 座標 position (水平) を含むタイル。なければ、空
func _tile_at(position: Vector3) -> Dictionary:
	for tile in _tiles:
		if _contains_xz(tile, position):
			return tile
	return {}


# タイルの範囲 (水平) に、global 座標 position が入っているか
func _contains_xz(tile: Dictionary, position: Vector3) -> bool:
	var local: Vector3 = position - tile.offset
	var box: AABB = tile.bounds
	return local.x >= box.position.x and local.x <= box.end.x and local.z >= box.position.z and local.z <= box.end.z


# 読んだセーブ (1 つのタイルの記録) を、ゲームへ反映する。項目ごとに検証して、不正なものは、黙って無視する。
# is_home なら、プレイヤーを、最後に休んだ位置に立たせる。そうでないタイルは、篝火の火と、確かめた所だけを戻す。
#
# セーブには、保存した時の世界の形 (測量座標の原点と、メッシュの範囲。どちらも、そのタイルの座標) も入っている。いまの世界と見比べて、
#   - 同じなら、そのまま信用する (地面の検査はしない。斜面の途中の篝火を、誤って捨てないため)
#   - 違えば、作り直された世界。位置は、原点の動きだけ直した上で、地面の上にあるか確かめ、
#     地面のない所 (範囲の外) や、地面の中 (メッシュを粗くして、地面が上がった時など) なら、使わず、いつもの始まり方にする
#     (使うと、落ちて、同じ位置へ戻ることを繰り返し、遊べなくなる)
#   - 確かめた所の地図は、水平の原点と、水平の範囲が同じ時だけ使う (違うと、ずれて重なる。範囲で、画素の間隔も変わる)
func _apply_tile_save(tile: Dictionary, state: Dictionary, is_home: bool) -> void:
	var saved_origin: Variant = SaveGame.decode_vector(state.get("origin"))
	var origin: Variant = WorldLoader.origin_for(tile.path)
	var saved_bounds: Variant = _decode_bounds(state.get("bounds"))
	var box: AABB = tile.bounds
	var shift := Vector3.ZERO
	var same_map := true
	if saved_origin != null and origin != null:
		var moved: Vector3 = saved_origin - origin  # 測量座標 (東, 北, 標高) での、原点の動き
		shift = Vector3(moved.x, moved.z, -moved.y)  # ゲームの座標 (x, 高さ, z) に直す
		same_map = is_zero_approx(moved.x) and is_zero_approx(moved.y)
	var unchanged := shift == Vector3.ZERO
	if saved_bounds != null:
		var old: AABB = saved_bounds
		unchanged = unchanged and _same_box(old.position, box.position) and _same_box(old.size, box.size)
		same_map = same_map and Vector2(old.position.x - box.position.x, old.position.z - box.position.z).length() < FRAME_TOLERANCE \
			and Vector2(old.size.x - box.size.x, old.size.z - box.size.z).length() < FRAME_TOLERANCE
	var kept: Variant = state.get("reveal_png") if same_map else null
	if kept is String:
		tile["loaded_reveal"] = kept
	tile["visited"] = true
	tile["dirty"] = true
	var spawn: Variant = SaveGame.decode_vector(state.get("spawn"))
	if spawn != null and not unchanged and not _is_on_ground(tile.meshes, spawn + shift + tile.offset):
		spawn = null
	if spawn != null:
		spawn += shift
		tile["spawn_local"] = spawn
		if tile.fire != null:
			tile.fire.lit = true  # 休んだことがある篝火は、火が灯っている
		if is_home:
			var global_spawn: Vector3 = spawn + tile.offset
			player.global_position = global_spawn
			player.spawn_position = global_spawn
			player.velocity = Vector3.ZERO
			player.has_rested = true
	if tile.points != null:
		tile.points.restore_reveal(SaveGame.decode_bytes(kept))
	if is_home:
		_apply_time(state.get("time_total_hours"))


# 保存した時刻 (ゲーム全体のもの) を、昼夜に渡す。DayNight は、このあとで始まるので、始まる時に戻される
func _apply_time(saved_time: Variant) -> void:
	var day_night := get_node_or_null("../DayNight")
	if day_night != null and (saved_time is float or saved_time is int):
		day_night.restore_total_hours = saved_time


static func _same_box(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < FRAME_TOLERANCE


# 範囲を、[x, y, z, 幅, 高さ, 奥行き] の 6 つの数で保存する。読めなければ null
static func _decode_bounds(value: Variant) -> Variant:
	if not (value is Array) or (value as Array).size() != 6:
		return null
	var position: Variant = SaveGame.decode_vector((value as Array).slice(0, 3))
	var size: Variant = SaveGame.decode_vector((value as Array).slice(3, 6))
	if position == null or size == null:
		return null
	return AABB(position, size)


static func _encode_bounds(box: AABB) -> Array:
	return SaveGame.encode_vector(box.position) + SaveGame.encode_vector(box.size)


# position が、地面の上 (または、空中) にあるか。一番近い地面 (メッシュの頂点) が、水平に離れすぎている、
# または、position が、その地面より深く埋まっている時は、false
func _is_on_ground(meshes: Array, position: Vector3) -> bool:
	var ground := WorldLoader.pick_start(meshes, position)
	var near := Vector2(ground.x - position.x, ground.z - position.z).length() <= GROUND_MARGIN
	return near and position.y >= ground.y - UNDERGROUND_MARGIN


# タイルの記録 (保存する内容)。探索地図 (PNG にする処理が重い) は、前回から変わっていなければ、前回のものを使い回す。
# 変わったかは、探索地図の revision と、休んだ・記録を読んだ印 (dirty) で分かる
func _tile_state(tile: Dictionary) -> Dictionary:
	var revision: int = tile.points.reveal.revision if tile.points != null else -1
	if tile.state_cache != null and not tile.dirty and revision == tile.saved_revision:
		return tile.state_cache
	var state := {"has_rested": tile.spawn_local != null}
	var origin: Variant = WorldLoader.origin_for(tile.path)
	if origin != null:
		state["origin"] = SaveGame.encode_vector(origin)  # 位置は、この原点からの値。世界を作り直したら、直すのに使う
	state["bounds"] = _encode_bounds(tile.bounds)  # 世界の形。いまの世界と見比べて、作り直されたかを知る
	if tile.spawn_local != null:
		state["spawn"] = SaveGame.encode_vector(tile.spawn_local)
	if tile.points != null:
		state["reveal_png"] = SaveGame.encode_bytes(tile.points.reveal.to_png())
		tile["encoded"] += 1
	elif not tile.loaded_reveal.is_empty():
		state["reveal_png"] = tile.loaded_reveal  # 点の表現を切っている間も、保存済みの地図は残す
	tile["state_cache"] = state
	tile["saved_revision"] = revision
	tile["dirty"] = false
	return state


# 続きの状態を保存する。保存できたら true。遊んだタイル (始める世界と、入った、休んだ、記録を読んだ、タイル) を、1 度にまとめて書く
func save_now() -> bool:
	if not _save_active:
		return false
	var day_night := get_node_or_null("../DayNight")
	var items: Array = []
	for tile in _tiles:
		if tile.visited:
			items.append({"path": tile.path, "state": _tile_state(tile)})
	if day_night != null and day_night.time != null and day_night.settings.time_mode == "accelerated" and not items.is_empty():
		items[0]["state"] = (items[0].state as Dictionary).duplicate()  # 前回の記録 (キャッシュ) を、書き換えない
		items[0].state["time_total_hours"] = day_night.time.total_hours
	var saved := SaveGame.write_many(items, _tiles[_current].path)
	if not saved:
		_notify("セーブに失敗しました")
	return saved


# 画面に、しばらくメッセージを出す。休んだ知らせに上書きされないよう、Player の通知を使う
func _notify(text: String) -> void:
	player.notice(text, NOTICE_SECONDS)


func _fail(text: String) -> void:
	push_error(text)
	message.text = text
	message.visible = true
	# 床がないので、動かしておくと落ちて「再スキャン中」がエラーを上書きしてしまう
	player.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
