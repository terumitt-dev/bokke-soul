extends CharacterBody3D
# 三人称のプレイヤー。カメラは肩越しの追従で、マウス (またはコントローラーの右スティック) で回す。
# 壁の手前では、カメラが寄って、めり込まない (SpringArm3D)。
# 移動はカメラの向きが基準で、キャラクターは進む向きへ体を向ける

const WALK_SPEED := 4.0
const RUN_SPEED := 7.0
const ACCELERATION := 30.0  # 速度が目標に近づく速さ (m/s^2)。小さいほど、動き出しと止まりが緩やか
const TURN_SPEED := 12.0  # 体が進む向きへ回る速さ
const MOUSE_SENSITIVITY := 0.002
const STICK_LOOK_SPEED := 2.6  # 右スティックを倒しきった時の、視点の回る速さ (ラジアン/秒)
const PITCH_MIN := deg_to_rad(-60.0)  # 見下ろす向き
const PITCH_MAX := deg_to_rad(30.0)  # 見上げる向き
const HIDE_MODEL_DISTANCE := 0.9  # カメラがこれより体に近い時は、体を隠す (視界を塞がないように)
const FALL_LIMIT := -20.0
const RESCAN_SECONDS := 1.5
const REST_DISTANCE := 2.5
const NOTICE_SECONDS := 1.5

var spawn_position: Vector3
var rescanning := false
var nearby_bonfire: Node3D
var message_id := 0
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var model: Node3D = $Model
@onready var pivot: Node3D = $CameraPivot
@onready var arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var message: Label = get_node("../HUD/Message")
@onready var prompt: Label = get_node("../HUD/Prompt")


func _ready() -> void:
	InputActions.ensure()
	spawn_position = global_position
	arm.add_excluded_object(get_rid())  # カメラが、自分の体にぶつからないようにする
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
		look(-event.relative.x * MOUSE_SENSITIVITY, -event.relative.y * MOUSE_SENSITIVITY)
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("rest"):
		rest()


func _physics_process(delta: float) -> void:
	if rescanning:
		return

	# コントローラーの右スティックで視点を回す (マウスは _unhandled_input で扱う)
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if stick != Vector2.ZERO:
		look(-stick.x * STICK_LOOK_SPEED * delta, -stick.y * STICK_LOOK_SPEED * delta)

	if not is_on_floor():
		velocity.y -= gravity * delta

	# 移動はカメラの向き (左右の回転だけ) が基準。アナログスティックは、倒した量が速さになる
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := Basis(Vector3.UP, pivot.rotation.y) * Vector3(input.x, 0.0, input.y)
	var speed := RUN_SPEED if Input.is_action_pressed("run") else WALK_SPEED
	var target := direction * speed
	velocity.x = move_toward(velocity.x, target.x, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, target.z, ACCELERATION * delta)

	# 体を進む向きへ回す。立ち止まっている間は、向きを保つ
	if direction.length() > 0.1:
		var yaw := atan2(-direction.x, -direction.z)  # モデルの正面は -Z
		model.rotation.y = lerp_angle(model.rotation.y, yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))

	move_and_slide()

	model.visible = arm.get_hit_length() > HIDE_MODEL_DISTANCE
	_update_nearby_bonfire()

	if global_position.y < FALL_LIMIT:
		_rescan()


# 視点を回す。yaw は左右、pitch は上下 (ラジアン)。見上げ、見下ろしには上限がある
func look(yaw: float, pitch: float) -> void:
	pivot.rotation.y += yaw
	pivot.rotation.x = clampf(pivot.rotation.x + pitch, PITCH_MIN, PITCH_MAX)


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
