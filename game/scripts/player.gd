extends CharacterBody3D

const SPEED := 5.0
const MOUSE_SENSITIVITY := 0.002
const PITCH_LIMIT := deg_to_rad(85.0)
const FALL_LIMIT := -20.0
const RESCAN_SECONDS := 1.5
const REST_DISTANCE := 2.5
const NOTICE_SECONDS := 1.5

var spawn_position: Vector3
var rescanning := false
var nearby_bonfire: Node3D
var message_id := 0
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var camera: Camera3D = $Camera3D
@onready var message: Label = get_node("../HUD/Message")
@onready var prompt: Label = get_node("../HUD/Prompt")


func _ready() -> void:
	spawn_position = global_position
	prompt.text = "E: 休む"
	prompt.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	# ウィンドウから離れる時 (Cmd+Tab など) はマウスを解放する
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _input(event: InputEvent) -> void:
	# Esc は他の入力処理より先に拾って、確実にマウスを解放する
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		rest()


func _physics_process(delta: float) -> void:
	if rescanning:
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)),
	)
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
	velocity.x = direction.x * SPEED
	velocity.z = direction.z * SPEED

	move_and_slide()

	_update_nearby_bonfire()

	if global_position.y < FALL_LIMIT:
		_rescan()


# 近くにある一番近い篝火を探して、「休む」の案内を出す
func _update_nearby_bonfire() -> void:
	nearby_bonfire = null
	var nearest := REST_DISTANCE
	for bonfire: Node3D in get_tree().get_nodes_in_group("bonfire"):
		var distance := global_position.distance_to(bonfire.global_position)
		if distance <= nearest:
			nearest = distance
			nearby_bonfire = bonfire
	prompt.visible = nearby_bonfire != null


# 篝火の近くで休むと、ここが復帰地点になる
func rest() -> void:
	if rescanning or nearby_bonfire == null:
		return
	spawn_position = nearby_bonfire.rest_position()
	_show_message("基準点を確定しました", NOTICE_SECONDS)


# 床の下へ落ちたら、位置を見失った演出を出して最後に休んだ篝火へ戻す
func _rescan() -> void:
	rescanning = true
	prompt.visible = false
	await _show_message("位置を見失いました。再スキャン中…", RESCAN_SECONDS)
	global_position = spawn_position
	velocity = Vector3.ZERO
	rescanning = false


# 一定時間メッセージを出す。後から別のメッセージが出ていたら、消さない
func _show_message(text: String, seconds: float) -> void:
	message_id += 1
	var id := message_id
	message.text = text
	message.visible = true
	await get_tree().create_timer(seconds).timeout
	if id == message_id:
		message.visible = false
