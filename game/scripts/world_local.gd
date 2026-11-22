extends Node3D
# 指定した世界 (WorldLoader.resolve_path) を読み込み、当たり判定を付けて、歩けるようにする。
# 指定は起動時の引数: godot --path game res://scenes/world_local.tscn -- --world=/path/to/world.glb
#
# セーブ: 篝火で休んだ時と、ゲームを閉じる時に、続きの状態 (最後に休んだ篝火、時刻、確かめた所) を保存する。
# 次に始める時は、それを読んで、続きから始める。セーブが壊れていても、新しいバージョンのものでも、ゲームは遊べる
# (壊れていれば退けて新しく始め、新しいバージョンのものは、読まず、上書きもしない)

const START_HEIGHT := 2.0
const START_BONFIRE_DISTANCE := 2.0  # 最初の篝火を、始めた場所の、どれだけ前に置くか (m)
const NOTICE_SECONDS := 3.0  # 保存に失敗した知らせを出しておく時間 (休んだ知らせより長い)
const CLOSE_HOLD_SECONDS := 8.0  # 閉じる時に保存に失敗した時、終了を保留しておく時間

@export var world_path := ""
# 点の表現の方式 (mesh_and_points / points_only / off)。空なら、設定ファイルから読む
@export var point_mode := ""
# セーブを使うか。設定ファイルの [save] enabled と、ヘッドレスでは無効、も合わせて決まる
@export var save_enabled := true

@onready var player: CharacterBody3D = get_node("../Player")
@onready var message: Label = get_node("../HUD/Message")

var _points: PointWorld
var _save_world := ""  # セーブの対象の世界の場所
var _save_active := false
# セーブから読んだ、確かめた所の地図 (PNG)。点の表現が無効な間も、保存に引き継ぐ。
# 設定を一時的に切り替えただけで、それまで確かめた所が失われないように
var _loaded_reveal := ""
var _close_held := false  # 保存に失敗して、終了を保留している間


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
	_add_start_bonfire(meshes, start)

	_points = _add_points(world)
	_setup_save()


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


# 最初の基準点として、始めた場所のすぐ前に、篝火を 1 つ置く。ここで休める (休むとセーブされ、落ちたらここへ戻る)。
# 篝火を、世界のあちこちへ置く仕組みは、探索の骨格 (段階4) で作る
func _add_start_bonfire(meshes: Array, start: Vector3) -> void:
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	fire.name = "StartBonfire"
	add_child(fire)
	fire.global_position = WorldLoader.pick_start(meshes, Vector3(start.x, 0.0, start.z - START_BONFIRE_DISTANCE))


# 点の表現を入れる。歩いた所だけが現れ、まだの所は暗く沈む。off なら入れず (null を返し)、世界は最初から全て見える
func _add_points(world: Node3D) -> PointWorld:
	var mode := point_mode if point_mode in GameSettings.POINT_MODES else GameSettings.load_from().point_mode
	if mode == "off":
		return null
	var points := PointWorld.new()
	points.name = "PointWorld"
	add_child(points)
	points.setup(world, player, PointWorld.Mode.POINTS_ONLY if mode == "points_only" else PointWorld.Mode.MESH_AND_POINTS)
	return points


# セーブを使う準備。あれば読んで、続きから始める。篝火で休んだら、保存する
func _setup_save() -> void:
	_save_world = WorldLoader.resolve_path(world_path)
	_save_active = save_enabled and GameSettings.load_from().save_enabled and SaveGame.enabled()
	if not _save_active:
		return
	var result := SaveGame.read(_save_world)
	if result.status == "newer":
		# 新しいバージョンのゲームで作ったセーブ。読めないし、上書きして壊してもいけない。保存せずに遊ぶ
		push_warning("新しいバージョンのセーブなので、続きからは始めず、保存もしません")
		_save_active = false
		return
	if result.status == "ok":
		_apply_save(result.state)
	player.rested.connect(func(_position: Vector3) -> void: save_now())


# 読んだセーブを、ゲームへ反映する。項目ごとに検証して、不正なものは、黙って無視する
func _apply_save(state: Dictionary) -> void:
	var kept: Variant = state.get("reveal_png")
	if kept is String:
		_loaded_reveal = kept
	var spawn: Variant = SaveGame.decode_vector(state.get("spawn"))
	if spawn != null:
		player.global_position = spawn
		player.spawn_position = spawn
		player.velocity = Vector3.ZERO
		player.has_rested = true
	if _points != null:
		_points.restore_reveal(SaveGame.decode_bytes(state.get("reveal_png")))
	var saved_time: Variant = state.get("time_total_hours")
	var day_night := get_node_or_null("../DayNight")
	if day_night != null and (saved_time is float or saved_time is int):
		day_night.restore_total_hours = saved_time  # DayNight は、このあとで始まるので、始まる時に戻される


# 続きの状態を保存する。保存できたら true
func save_now() -> bool:
	if not _save_active:
		return false
	var state := {"has_rested": player.has_rested}
	if player.has_rested:
		state["spawn"] = SaveGame.encode_vector(player.spawn_position)
	var day_night := get_node_or_null("../DayNight")
	if day_night != null and day_night.time != null and day_night.settings.time_mode == "accelerated":
		state["time_total_hours"] = day_night.time.total_hours
	if _points != null:
		state["reveal_png"] = SaveGame.encode_bytes(_points.reveal.to_png())
	elif not _loaded_reveal.is_empty():
		state["reveal_png"] = _loaded_reveal  # 点の表現を切っている間も、保存済みの地図は残す
	var saved := SaveGame.write(_save_world, state)
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
