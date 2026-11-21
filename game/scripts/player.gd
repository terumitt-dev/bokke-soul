extends CharacterBody3D

const SPEED := 5.0
const MOUSE_SENSITIVITY := 0.002
const PITCH_LIMIT := deg_to_rad(85.0)
const FALL_LIMIT := -20.0
const RESCAN_SECONDS := 1.5

var spawn_position: Vector3
var rescanning := false
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var camera: Camera3D = $Camera3D
@onready var message: Label = get_node("../HUD/Message")


func _ready() -> void:
	spawn_position = global_position
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

	if global_position.y < FALL_LIMIT:
		_rescan()


# 床の下へ落ちたら、位置を見失った演出を出して最後の地点へ戻す
func _rescan() -> void:
	rescanning = true
	message.text = "位置を見失いました。再スキャン中…"
	message.visible = true
	await get_tree().create_timer(RESCAN_SECONDS).timeout
	global_position = spawn_position
	velocity = Vector3.ZERO
	message.visible = false
	rescanning = false
