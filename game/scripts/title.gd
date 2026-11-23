extends Node3D
# タイトル画面。世界を背景に見せ (ゆっくり見回す)、「はじめる」「クレジット」「おわる」を出す。
# 世界のデータの出典は、データの隣の .json から読んで、画面の隅に小さく出す。
# 背景の世界と空は、ゲーム本体と同じ (昼夜と天気も同じ)

const GAME_SCENE := "res://scenes/world_local.tscn"
const EYE_HEIGHT := 3.0
const TURN_SPEED := 0.04  # ラジアン/秒。約 2 分半で一周
const LOOK_DOWN := -0.06
const NEW_GAME_CONFIRM_SECONDS := 4.0  # 「はじめから」の確認を待つ時間 (秒)

signal start_requested(world_path: String)

@export var world_path := ""

# テストでは、場面を切り替えずに確かめる
var auto_change_scene := true
var resolved_path := ""
var default_path := ""  # 最後に遊んだマップに、よらない、始まりの世界 (起動時の引数、サンプル)。「はじめから」は、ここから
var credit := {"credit": "", "license_url": ""}
var has_save := false
# 設定。テストで差し替えられる (なければ、設定ファイルから読む)
var settings: GameSettings
var _new_game_confirming := false

@onready var camera: Camera3D = $Camera3D
@onready var world_root: Node3D = $World
@onready var menu: VBoxContainer = $UI/Menu
@onready var start_button: Button = $UI/Menu/StartButton
@onready var new_game_button: Button = $UI/Menu/NewGameButton
@onready var credits_button: Button = $UI/Menu/CreditsButton
@onready var quit_button: Button = $UI/Menu/QuitButton
@onready var attribution: Label = $UI/Attribution
@onready var credits_panel: PanelContainer = $UI/Credits
@onready var credits_body: Label = $UI/Credits/Box/Body
@onready var back_button: Button = $UI/Credits/Box/BackButton


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if settings == null:
		settings = GameSettings.load_from()
	default_path = WorldLoader.resolve_path(world_path)
	resolved_path = _resume_path(default_path)
	_load_background()
	apply_credit(WorldLoader.credit_for(resolved_path))
	_refresh_save()

	start_button.pressed.connect(_start)
	new_game_button.pressed.connect(_new_game)
	credits_button.pressed.connect(_show_credits)
	back_button.pressed.connect(_hide_credits)
	quit_button.pressed.connect(func() -> void: get_tree().quit())
	start_button.grab_focus()


func _process(delta: float) -> void:
	camera.rotation.y += delta * TURN_SPEED


func _unhandled_input(event: InputEvent) -> void:
	# クレジットを開いている間は、Esc で戻る
	if credits_panel.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_hide_credits()
		get_viewport().set_input_as_handled()


# 「つづきから」で始める世界。最後に遊んだエリアが、同じ置き場にあれば、そこ。なければ、path のまま
func _resume_path(path: String) -> String:
	if not settings.save_enabled or not SaveGame.enabled():
		return path
	var id := SaveGame.current_area()
	if id.is_empty() or id == WorldLoader.world_id_for(path) or id == SaveGame.world_id(path):
		return path
	for entry in WorldRegistry.scan(path.get_base_dir()):
		if entry.world_id == id:
			return entry.path
	return path


# 世界を背景に置き、カメラを地面の上に立たせる。読み込めなければ、空だけを見せる
func _load_background() -> void:
	var loaded := WorldLoader.load_world(resolved_path)
	if loaded.node == null:
		push_warning(loaded.error)
		camera.position = Vector3(0, EYE_HEIGHT, 0)
		return
	var world: Node3D = loaded.node
	world_root.add_child(world)
	var meshes := world.find_children("*", "MeshInstance3D", true, false)
	var bounds := AABB()
	for i in meshes.size():
		var box: AABB = (meshes[i] as MeshInstance3D).global_transform * (meshes[i] as MeshInstance3D).get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	var ground := WorldLoader.pick_start(meshes, bounds.get_center())
	camera.position = ground + Vector3(0, EYE_HEIGHT, 0)
	camera.rotation.x = LOOK_DOWN


# 出典を画面の隅とクレジットに出す。出典がない (人工のサンプルなど) 時は、隅には何も出さない
func apply_credit(info: Dictionary) -> void:
	credit = info
	var line: String = info.get("credit", "")
	var url: String = info.get("license_url", "")
	attribution.text = line
	attribution.visible = not line.is_empty()

	var body := PackedStringArray()
	body.append("世界のデータ")
	if line.is_empty():
		body.append("  人工のサンプルデータ (出典の表示が必要なデータは使っていません)")
	else:
		body.append("  " + line)
		if not url.is_empty():
			body.append("  " + url)
	body.append("")
	body.append("地名 (篝火の名前)")
	body.append("  近くの道、歩道、停留所の名前は、OpenStreetMap による")
	body.append("  © OpenStreetMap contributors (ODbL)")
	body.append("  https://www.openstreetmap.org/copyright")
	body.append("")
	body.append("書体")
	body.append("  Cinzel (The Cinzel Project Authors)")
	body.append("  Zen Old Mincho (The Zen Old Mincho Project Authors)")
	body.append("  SIL Open Font License 1.1")
	body.append("")
	body.append("ゲームエンジン")
	body.append("  Godot Engine (MIT License)")
	credits_body.text = "\n".join(body)


# セーブがあれば、「つづきから」と「はじめから」を出す。なければ「はじめる」だけ。
# 設定でセーブを切っている時は、ゲームが、復元も保存もしないので、出さない (消せもしない)
func _refresh_save() -> void:
	# 続きがあるか: どこかのエリアに、遊んだ記録があれば。表示するマップに記録がなくても (移った先で、保存する前に終わった時)、
	# 「つづきから」と「はじめから」を出す (進行があるのに、消して始め直せなくならない)
	has_save = settings.save_enabled and (SaveGame.read(resolved_path).status == "ok" or SaveGame.has_any())
	start_button.text = "つづきから" if has_save else "はじめる"
	new_game_button.visible = has_save
	_new_game_confirming = false
	new_game_button.text = "はじめから"


# 「はじめから」: セーブを消すので、うっかり押しても消えないよう、もう一度押して確定する
func _new_game() -> void:
	if not _new_game_confirming:
		_new_game_confirming = true
		new_game_button.text = "セーブを消します。もう一度押すと、はじめから"
		await get_tree().create_timer(NEW_GAME_CONFIRM_SECONDS).timeout
		if _new_game_confirming:  # 確定されなかった。元に戻す
			_new_game_confirming = false
			new_game_button.text = "はじめから"
		return
	_new_game_confirming = false
	SaveGame.delete(resolved_path)
	has_save = false
	resolved_path = default_path  # 「はじめから」は、最後に遊んだマップではなく、始まりの世界から
	_start()


func _start() -> void:
	start_requested.emit(resolved_path)
	if auto_change_scene:
		# ゲーム本体も同じ世界を読めるように、選んだ場所を引き継ぐ
		WorldLoader.selected_path = resolved_path
		WorldLoader.arrival = {"path": resolved_path}  # 起動時の引数 (--world=) より先に、この世界を使う
		get_tree().change_scene_to_file(GAME_SCENE)


func _show_credits() -> void:
	menu.visible = false  # 後ろのタイトルが透けて、ごちゃつかないようにする
	credits_panel.visible = true
	back_button.grab_focus()


func _hide_credits() -> void:
	menu.visible = true
	credits_panel.visible = false
	credits_button.grab_focus()
