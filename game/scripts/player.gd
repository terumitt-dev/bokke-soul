extends CharacterBody3D
# 三人称のプレイヤー。カメラは肩越しの追従で、マウス (またはコントローラーの右スティック) で回す。
# 壁の手前では、カメラが寄って、めり込まない (SpringArm3D)。肩越しのずれも、壁に入らないよう縮む。
# 移動はカメラの向きが基準で、キャラクターは進む向きへ体を向ける。ジャンプができる

const WALK_SPEED := 4.0
const RUN_SPEED := 7.0
const ACCELERATION := 30.0  # 地上で、速度が目標に近づく速さ (m/s^2)。小さいほど、動き出しと止まりが緩やか
const AIR_ACCELERATION := 8.0  # 空中では、向きや速さを変えにくい
const TURN_SPEED := 12.0  # 体が進む向きへ回る速さ
const JUMP_HEIGHT := 1.2  # ジャンプの高さ (m)
const COYOTE_TIME := 0.12  # 地面を離れてから、まだ跳べる時間 (秒)
const JUMP_BUFFER := 0.12  # 着地の少し前に押しても、着地した時に跳べる時間 (秒)
const MOUSE_SENSITIVITY := 0.002
const STICK_LOOK_SPEED := 2.6  # 右スティックを倒しきった時の、視点の回る速さ (ラジアン/秒)
const PITCH_MIN := deg_to_rad(-60.0)  # 見下ろす向き
const PITCH_MAX := deg_to_rad(30.0)  # 見上げる向き
const SHOULDER_OFFSET := 0.6  # カメラを肩越しに右へずらす量 (m)
const SHOULDER_MARGIN := 0.3  # 右に壁がある時、壁との間に空ける余白 (m)
const SHOULDER_SPEED := 12.0  # ずれが縮む、元に戻る速さ
const HIDE_MODEL_DISTANCE := 0.9  # カメラがこれより体に近づいたら、体を隠す (視界を塞がないように)
const SHOW_MODEL_DISTANCE := 1.1  # 隠したあと、これより離れたら、また見せる (境目でちらつかないように)
const RUN_FOV_BOOST := 8.0  # 走っている間、視野を広げる量 (度)。速さを感じやすくする
const FOV_SPEED := 6.0
const FALL_LIMIT := -20.0
const RESCAN_SECONDS := 1.5
const DEATH_SECONDS := 3.0  # 倒れてから、復活の演出に入るまで (「DECEASED」を見せる時間)
const REST_DISTANCE := 2.5
const NOTICE_SECONDS := 1.5

# 篝火で休んだ時 (position は篝火の位置)。セーブなどが聞く
signal rested(position: Vector3)
signal revived  # 倒れてから、最後に休んだ篝火で復活した
signal travel_requested(bonfire: Node3D)  # 火を灯した篝火の近くで、移動の操作をした

# 入力を受け付けない (移動の一覧を開いている間)。重力だけが効く
var input_blocked := false
# マウスを、ゲームが握っているか (視点を回す。外れている時の左クリックは、握り直すだけで、攻撃しない)。
# Input.mouse_mode と同じに保つ。ヘッドレス (テスト) では、Input.mouse_mode が動かないので、この印で判断する
var mouse_captured := true
var spawn_position: Vector3
# これより低い所へ落ちたら、位置を見失う (床の下へ落ちた、と見なす)。地域で、標高の低いタイルを並べる時は、
# 地域でいちばん低い地面より、下に決める (World が、タイルの位置から決めて、渡す)
var fall_limit := FALL_LIMIT
var has_rested := false  # 篝火で休んだことがあるか (休んだことがなければ、復帰地点は、最初の地点)
var rescanning := false
var nearby_bonfire: Node3D
var message_id := 0
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var jump_velocity: float = sqrt(2.0 * gravity * JUMP_HEIGHT)

var _coyote := 0.0
var _buffer := 0.0
var _model_hidden := false
var _base_fov := 75.0

@onready var model: Node3D = $Model
@onready var character: CharacterModel = $Model/Character
var combat: PlayerCombat  # 戦闘 (攻撃、回避、スタミナ、体力)
var immune := false  # 場面を移っている間 (暗転から、切り替えまで) は、ダメージを受けない。倒れて、移動を迂回しないように
var dead := false  # 倒れている (体力がなくなってから、復活するまで)
var death_banner: DeathBanner
var vitals: Vitals  # 体力とスタミナの棒
@onready var pivot: Node3D = $CameraPivot
@onready var arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var message: Label = get_node("../HUD/Message")
@onready var prompt: Label = get_node("../HUD/Prompt")


func _ready() -> void:
	InputActions.ensure()
	spawn_position = global_position
	arm.add_excluded_object(get_rid())  # カメラが、自分の体にぶつからないようにする
	arm.position.x = SHOULDER_OFFSET
	_base_fov = camera.fov
	prompt.text = "E: 休む"
	prompt.visible = false
	mouse_captured = true
	character.load_model()  # 人型のモデル。読み込めなければ、仮のカプセルのまま
	combat = PlayerCombat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(self, character)
	combat.died.connect(_on_died)
	death_banner = DeathBanner.new()
	get_node("../HUD").add_child(death_banner)
	add_to_group("player")  # 敵が、見つける
	vitals = Vitals.new()
	get_node("../HUD").add_child(vitals)
	vitals.bind(combat)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	# ウィンドウから離れる時 (Cmd+Tab など) はマウスを解放する
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		mouse_captured = false


func _input(event: InputEvent) -> void:
	# Esc は他の入力処理より先に拾って、確実にマウスを解放する
	if input_blocked:
		return  # 一覧を開いている間は、Esc を、一覧が受け取る (一覧を閉じる)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		mouse_captured = false
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if input_blocked:
		return
	if event is InputEventMouseMotion and mouse_captured:
		look(-event.relative.x * MOUSE_SENSITIVITY, -event.relative.y * MOUSE_SENSITIVITY)
	elif event is InputEventMouseButton and event.pressed and not mouse_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED  # マウスを戻すだけ (その時の左クリックでは、攻撃しない)
		mouse_captured = true
	elif event.is_action_pressed("attack"):
		if not rescanning:
			combat.try_attack(_input_direction())
	elif event.is_action_pressed("dodge"):
		if not rescanning:
			combat.try_dodge(_input_direction())
	elif event.is_action_pressed("rest"):
		rest()
	elif event.is_action_pressed("travel"):
		if not rescanning and not dead and nearby_bonfire != null and "lit" in nearby_bonfire and nearby_bonfire.lit:
			travel_requested.emit(nearby_bonfire)


func _physics_process(delta: float) -> void:
	if rescanning:
		return
	combat.tick(delta)
	if dead:
		# 倒れている間は、動けない (重力だけ)
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		return
	if input_blocked:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		return

	# コントローラーの右スティックで視点を回す (マウスは _unhandled_input で扱う)
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if stick != Vector2.ZERO:
		look(-stick.x * STICK_LOOK_SPEED * delta, -stick.y * STICK_LOOK_SPEED * delta)

	# 重力とジャンプ。地面を離れた直後 (コヨーテタイム) と、着地の直前 (先行入力) でも跳べる
	var on_floor := is_on_floor()
	_coyote = COYOTE_TIME if on_floor else _coyote - delta
	_buffer = JUMP_BUFFER if Input.is_action_just_pressed("jump") else _buffer - delta
	if not on_floor:
		velocity.y -= gravity * delta
	if _buffer > 0.0 and _coyote > 0.0 and not combat.is_busy():  # 攻撃や回避の最中は、跳べない
		velocity.y = jump_velocity
		_buffer = 0.0
		_coyote = 0.0

	# 移動はカメラの向き (左右の回転だけ) が基準。アナログスティックは、倒した量が速さになる。
	# 水平の速度は、1 つのベクトルとして目標へ近づける (向きを急に変えても、軌道が曲がらない)
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := Basis(Vector3.UP, pivot.rotation.y) * Vector3(input.x, 0.0, input.y)
	var run_pressed := Input.is_action_pressed("run")
	var running := run_pressed and direction.length() > 0.1  # 視野を広げるのは、実際に動いている間だけ
	var target := Vector2(direction.x, direction.z) * (RUN_SPEED if run_pressed else WALK_SPEED) * combat.move_factor()
	var accel := ACCELERATION if on_floor else AIR_ACCELERATION
	var horizontal := Vector2(velocity.x, velocity.z).move_toward(target, accel * delta)
	if combat.is_dodging():
		horizontal = combat.dodge_velocity  # 回避の間は、回避の向きと速さ
	velocity.x = horizontal.x
	velocity.z = horizontal.y

	# 体を進む向きへ回す。立ち止まっている間は、向きを保つ。攻撃と回避の間は、向きを変えない
	if direction.length() > 0.1 and not combat.is_busy():
		var yaw := atan2(-direction.x, -direction.z)  # モデルの正面は -Z
		model.rotation.y = lerp_angle(model.rotation.y, yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))

	move_and_slide()

	_update_camera(delta, running)
	_update_nearby_bonfire()
	_update_animation(on_floor)

	if global_position.y < fall_limit:
		_rescan()


# いまの移動の入力の向き (カメラの向きが基準。世界の向き)。入力がなければ、ゼロ
func _input_direction() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	return Basis(Vector3.UP, pivot.rotation.y) * Vector3(input.x, 0.0, input.y)


# ダメージを受ける (敵の攻撃など)。回避の最初の間は、受けない。受けたら true
func take_damage(amount: float, source: Node = null) -> bool:
	if immune:
		return false
	return combat.take_damage(amount, source)


# 視点を回す。yaw は左右、pitch は上下 (ラジアン)。見上げ、見下ろしには上限がある
func look(yaw: float, pitch: float) -> void:
	pivot.rotation.y += yaw
	pivot.rotation.x = clampf(pivot.rotation.x + pitch, PITCH_MIN, PITCH_MAX)


# カメラまわりの更新: 肩越しのずれ、体を隠す、走っている時の視野
func _update_camera(delta: float, running: bool) -> void:
	# 肩越しのずれは、見た目だけでなく、壁よけの起点そのものをずらす (壁の中に視点が入らない)。
	# 右に壁があれば、そこまでの距離に合わせて縮める
	var origin := pivot.global_position
	var right := pivot.global_transform.basis.x
	var exclude: Array[RID] = [get_rid()]
	var query := PhysicsRayQueryParameters3D.create(origin, origin + right * (SHOULDER_OFFSET + SHOULDER_MARGIN), arm.collision_mask, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var offset := SHOULDER_OFFSET
	if not hit.is_empty():
		offset = clampf(origin.distance_to(hit.position) - SHOULDER_MARGIN, 0.0, SHOULDER_OFFSET)
	# 壁へ向けて縮める時は、すぐに適用する (ゆっくりだと、視点を壁の側へ素早く回した直後に、壁の中が映る)。
	# 壁から離れて元に戻す時だけ、なめらかに戻す
	if offset < arm.position.x:
		arm.position.x = offset
	else:
		arm.position.x = lerpf(arm.position.x, offset, clampf(SHOULDER_SPEED * delta, 0.0, 1.0))

	# カメラが体に近すぎる時は、体を隠す。隠す距離と戻す距離をずらして、境目でちらつかないようにする
	var distance := arm.get_hit_length()
	if _model_hidden and distance > SHOW_MODEL_DISTANCE:
		_model_hidden = false
	elif not _model_hidden and distance < HIDE_MODEL_DISTANCE:
		_model_hidden = true
	model.visible = not _model_hidden

	# 走っている間は、視野を広げて、速さを感じやすくする
	var fov := _base_fov + (RUN_FOV_BOOST if running else 0.0)
	camera.fov = lerpf(camera.fov, fov, clampf(FOV_SPEED * delta, 0.0, 1.0))


# 近くにある一番近い篝火を探して、「休む」の案内を出す
func _update_nearby_bonfire() -> void:
	nearby_bonfire = null
	var nearest := REST_DISTANCE
	for bonfire: Node3D in get_tree().get_nodes_in_group("bonfire"):
		var distance := global_position.distance_to(bonfire.global_position)
		if distance <= nearest:
			nearest = distance
			nearby_bonfire = bonfire
	prompt.visible = nearby_bonfire != null and not input_blocked
	# 火を灯した篝火では、移動もできる
	prompt.text = "E: 休む    F: 移動する" if nearby_bonfire != null and "lit" in nearby_bonfire and nearby_bonfire.lit else "E: 休む"


# 篝火の近くで休むと、ここが復帰地点になる
func rest() -> void:
	if rescanning or dead or nearby_bonfire == null or combat.is_busy():
		return
	var first_time: bool = not nearby_bonfire.lit if "lit" in nearby_bonfire else not has_rested
	spawn_position = nearby_bonfire.rest_position()
	has_rested = true
	if "lit" in nearby_bonfire:
		nearby_bonfire.lit = true
	# 先に、点の表現が、周囲を確かめた所にする。そのあとで知らせる (その時にセーブされる)。
	# 逆だと、休んで確かめた範囲が、セーブに入らない
	get_tree().call_group("point_world", "on_rest", nearby_bonfire.global_position)
	# 休んだ知らせを先に出す。保存に失敗した時の知らせが、そのあとで上に出て、残るように
	_show_message(_rest_message(nearby_bonfire, first_time), NOTICE_SECONDS)
	character.play_once("rest")
	rested.emit(nearby_bonfire.global_position)


# 休んだ時の知らせ。名前のある篝火は、その名前を出す (初めては「火を灯した」、2 度目からは「休んだ」)。名前がなければ、基準点
func _rest_message(bonfire: Node3D, first_time: bool) -> String:
	var bonfire_name: String = bonfire.display_name() if bonfire.has_method("display_name") else ""
	if bonfire_name.is_empty():
		return "基準点を確定しました"
	return "「%s」に火を灯した" % bonfire_name if first_time else "「%s」で休んだ" % bonfire_name


# 見た目の動き: 空中なら「空中」、地上で止まっていれば「待つ」、歩く速さなら「歩く」、それより速ければ「走る」。
# 動き出したり、跳んだりしたら、休む動き (1 回だけ) を、すぐ中断する
func _update_animation(on_floor: bool) -> void:
	if combat.is_dead():
		return  # 倒れている間は、倒れた姿のまま
	var speed := Vector2(velocity.x, velocity.z).length()
	var wanted := "air" if not on_floor else ("idle" if speed < 0.3 else ("walk" if speed < (WALK_SPEED + RUN_SPEED) / 2.0 else "run"))
	if wanted != "idle":
		character.interrupt_once()
	character.play_state(wanted)


# 画面に、しばらくメッセージを出す。あとから出した知らせが、前の知らせの上に出て、残る
# (保存の失敗など、プレイヤーに必ず伝えたい知らせは、休んだ知らせに上書きされない)
func notice(text: String, seconds: float) -> void:
	_show_message(text, seconds)


# 床の下へ落ちたら、位置を見失った演出を出して最後に休んだ篝火へ戻す
func _rescan(message := "位置を見失いました。再スキャン中…") -> void:
	rescanning = true
	prompt.visible = false
	get_tree().call_group("point_world", "on_lost")  # 世界が崩れ始める
	await _show_message(message, RESCAN_SECONDS)
	global_position = spawn_position
	velocity = Vector3.ZERO
	get_tree().call_group("point_world", "on_rescan", spawn_position)  # 篝火から、波が広がって、再構成される
	rescanning = false


# 体力がなくなった。「DECEASED」を見せたあと、最後に休んだ篝火へ戻って (再スキャンの演出)、体力とスタミナを戻して、復活する
func _on_died() -> void:
	dead = true
	prompt.visible = false
	death_banner.show_banner()
	await get_tree().create_timer(DEATH_SECONDS).timeout
	if not is_inside_tree():
		return
	death_banner.hide_banner()
	await _rescan("再スキャン中…")
	combat.revive()
	dead = false
	revived.emit()


# 一定時間メッセージを出す。後から別のメッセージが出ていたら、消さない
func _show_message(text: String, seconds: float) -> void:
	message_id += 1
	var id := message_id
	message.text = text
	message.visible = true
	await get_tree().create_timer(seconds).timeout
	if id == message_id:
		message.visible = false
