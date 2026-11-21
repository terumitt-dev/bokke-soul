extends SceneTree

# 実行: godot --headless --path game --script res://tests/player_test.gd
# 三人称のプレイヤー (操作の名前、カメラ基準の移動、体の向き、カメラの壁よけ、視点操作) を確かめる

const START := Vector3(0, 0.05, 4)

var failures: Array[String] = []
var scene: Node
var player: CharacterBody3D


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


# 立ち位置と視点を戻して、動きを止める
func _reset(yaw: float = 0.0) -> void:
	for action: String in InputActions.ACTIONS:
		Input.action_release(action)
	player.global_position = START
	player.velocity = Vector3.ZERO
	player.pivot.rotation = Vector3(-0.15, yaw, 0.0)
	player.model.rotation = Vector3.ZERO
	await _frames(15)


func _horizontal(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _initialize() -> void:
	_test_actions()
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	player = scene.get_node("Player")
	await _frames(30)

	await _test_camera_rig()
	await _test_move_relative_to_camera()
	await _test_speed()
	await _test_facing()
	await _test_look()
	await _test_camera_collision()
	await _test_shoulder_collision()
	await _test_model_hide_hysteresis()
	await _test_run_fov()
	await _test_jump()
	await _test_rest_action()
	for action: String in InputActions.ACTIONS:
		Input.action_release(action)
	quit(1 if failures.size() > 0 else 0)


func _test_actions() -> void:
	InputActions.ensure()
	var all_exist := true
	for action: String in InputActions.ACTIONS:
		all_exist = all_exist and InputMap.has_action(action)
	check(all_exist, "操作の名前が全て登録される")

	var keyboard_ok := true
	var gamepad_ok := true
	for action: String in InputActions.ACTIONS:
		var events := InputMap.action_get_events(action)
		var spec: Dictionary = InputActions.ACTIONS[action]
		var keys := events.filter(func(e: InputEvent) -> bool: return e is InputEventKey)
		var pads := events.filter(func(e: InputEvent) -> bool: return e is InputEventJoypadMotion or e is InputEventJoypadButton)
		keyboard_ok = keyboard_ok and keys.size() == spec.keys.size()
		gamepad_ok = gamepad_ok and pads.size() == spec.axes.size() + spec.buttons.size() and pads.size() > 0
	check(keyboard_ok, "キーボードの割り当てが、定義どおりに入る")
	check(gamepad_ok, "コントローラー (スティック、ボタン) の割り当てが、全ての操作にある")

	var before := InputMap.action_get_events("move_forward").size()
	InputActions.ensure()
	check(InputMap.action_get_events("move_forward").size() == before, "登録は何度呼んでも、割り当てが増えない")
	check(InputMap.action_get_deadzone("move_forward") > 0.0, "スティックの遊び (デッドゾーン) がある")


func _test_camera_rig() -> void:
	await _reset()
	check(player.camera.current, "プレイヤーのカメラが、現在のカメラになる")
	var behind: Vector3 = player.camera.global_position - player.global_position
	check(behind.z > 2.5 and absf(behind.x) < 1.0, "カメラは、プレイヤーの後ろ (向いている側の反対) にある")
	check(player.arm.get_hit_length() > 3.9, "開けた場所では、カメラは自分の体に邪魔されず、離れている")
	check(player.arm.position.x > 0.3, "カメラは、肩越しに右へずれている (%.2f)" % player.arm.position.x)


func _test_move_relative_to_camera() -> void:
	# カメラが北 (-Z) を向いている時: 前へ進むと -Z
	await _reset(0.0)
	Input.action_press("move_forward")
	await _frames(40)
	Input.action_release("move_forward")
	var moved := _horizontal(player.global_position - START)
	check(moved.z < -1.5 and absf(moved.x) < 0.3, "カメラが前を向いていれば、前進で奥へ進む")

	# 止まる (急には止まらないが、すぐ止まる)
	await _frames(20)
	check(_horizontal(player.velocity).length() < 0.1, "入力をやめると、止まる")

	# カメラを 90 度回すと、前進の向きも回る (移動は、カメラが基準)
	await _reset(PI / 2.0)
	var forward := Basis(Vector3.UP, PI / 2.0) * Vector3(0, 0, -1)
	Input.action_press("move_forward")
	await _frames(40)
	Input.action_release("move_forward")
	moved = _horizontal(player.global_position - START)
	check(moved.dot(forward) > 1.5 and absf(moved.cross(forward).y) < 0.3, "カメラを 90 度回すと、前進の向きも回る")

	# 後ろ向き (カメラ 180 度) で「前」を押すと、カメラの向く手前側へ進む
	await _reset(PI)
	Input.action_press("move_forward")
	await _frames(30)
	Input.action_release("move_forward")
	check(player.global_position.z - START.z > 1.0, "カメラが奥から手前を向いていれば、前進で手前 (+Z) へ進む")


func _test_speed() -> void:
	await _reset()
	Input.action_press("move_forward")
	await _frames(40)
	var walk := _horizontal(player.velocity).length()
	Input.action_press("run")
	await _frames(40)
	var run := _horizontal(player.velocity).length()
	Input.action_release("run")
	Input.action_release("move_forward")
	check(absf(walk - player.WALK_SPEED) < 0.3, "歩く速さは WALK_SPEED (%.2f)" % walk)
	check(run > walk * 1.5 and absf(run - player.RUN_SPEED) < 0.4, "走ると速い (%.2f → %.2f)" % [walk, run])

	# アナログスティック: 軽く倒すと、ゆっくり進む
	await _reset()
	Input.action_press("move_forward", 0.5)
	await _frames(40)
	var soft := _horizontal(player.velocity).length()
	Input.action_release("move_forward")
	check(soft > 0.3 and soft < walk * 0.8, "スティックを軽く倒すと、ゆっくり進む (%.2f)" % soft)


func _test_facing() -> void:
	await _reset()
	Input.action_press("move_forward")
	await _frames(40)
	var facing: Vector3 = -player.model.global_transform.basis.z
	check(facing.dot(Vector3(0, 0, -1)) > 0.95, "前へ進むと、体は前を向く")
	Input.action_release("move_forward")

	Input.action_press("move_right")
	await _frames(40)
	facing = -player.model.global_transform.basis.z
	check(facing.dot(Vector3(1, 0, 0)) > 0.9, "右へ進むと、体は右を向く")
	Input.action_release("move_right")

	# 立ち止まっても、向きを保つ
	await _frames(30)
	var after: Vector3 = -player.model.global_transform.basis.z
	check(after.dot(facing) > 0.99, "立ち止まっている間は、向きを保つ")


func _test_look() -> void:
	await _reset()
	var yaw: float = player.pivot.rotation.y
	player.look(0.5, 0.0)
	check(absf(player.pivot.rotation.y - (yaw + 0.5)) < 0.001, "視点を左右に回せる")
	player.look(0.0, 10.0)
	check(is_equal_approx(player.pivot.rotation.x, player.PITCH_MAX), "見上げるのには、上限がある")
	player.look(0.0, -10.0)
	check(is_equal_approx(player.pivot.rotation.x, player.PITCH_MIN), "見下ろすのにも、上限がある")

	# コントローラーの右スティック
	await _reset()
	yaw = player.pivot.rotation.y
	Input.action_press("look_right", 1.0)
	await _frames(20)
	Input.action_release("look_right")
	check(player.pivot.rotation.y < yaw - 0.3, "右スティックを右へ倒すと、視点が右へ回る")
	var pitch: float = player.pivot.rotation.x
	Input.action_press("look_up", 1.0)
	await _frames(20)
	Input.action_release("look_up")
	check(player.pivot.rotation.x > pitch + 0.2, "右スティックを上へ倒すと、見上げる")

	# 視点を動かしても、体は動かない (移動と視点は別)
	await _reset()
	var position := player.global_position
	player.look(1.0, 0.0)
	await _frames(10)
	check(player.global_position.distance_to(position) < 0.05, "視点を回しても、体は動かない")


func _test_camera_collision() -> void:
	# 北の壁 (z = -7.5 の面) の手前に立ち、カメラを壁の側へ向ける
	await _reset(PI)
	player.global_position = Vector3(0, 0.05, -6.8)
	await _frames(10)
	var hit: float = player.arm.get_hit_length()
	check(hit < 1.6, "壁が背中にあると、カメラが寄る (%.2f)" % hit)
	check(player.camera.global_position.z > -7.5, "カメラは壁の中に入らない")
	check(not player.model.visible, "カメラが体に近すぎる時は、体を隠す (視界を塞がない)")

	# 壁から離れると、元の距離に戻る
	player.global_position = START
	await _frames(15)
	check(player.arm.get_hit_length() > 3.9, "壁から離れると、カメラは元の距離に戻る")
	check(player.model.visible, "壁から離れると、体がまた見える")


func _test_shoulder_collision() -> void:
	# 右側 (東) に壁がある時、肩越しのずれが壁に入り込まないよう縮む。
	# 東の壁は、内側の面が x = 7.5。ずれを縮めないと、映る視点は x = 7.6 付近になって壁の中に入る
	await _reset(0.0)
	player.global_position = Vector3(7.0, 0.05, 0.0)
	await _frames(30)
	check(player.arm.position.x < player.SHOULDER_OFFSET - 0.2, "右に壁があると、肩越しのずれが縮む (%.2f)" % player.arm.position.x)
	check(player.camera.global_position.x < 7.5, "映る視点 (カメラの位置) は、右の壁の中に入らない (%.2f)" % player.camera.global_position.x)

	# 壁から離れると、ずれが元に戻る
	player.global_position = START
	await _frames(40)
	check(absf(player.arm.position.x - player.SHOULDER_OFFSET) < 0.05, "壁から離れると、肩越しのずれが元に戻る")

	# 視点を素早く壁の側へ回した直後でも、壁の中が映らない (壁へ向けて縮める時は、すぐに適用する)。
	# カメラが壁と反対を向いている状態から、1 フレームで壁の側へ回す
	await _reset(PI)
	player.global_position = Vector3(7.0, 0.05, 0.0)
	await _frames(40)  # 反対側を向いていて、ずれは元の大きさ
	player.pivot.rotation.y = 0.0  # 右 (カメラの右) が、東の壁の側になる
	await physics_frame
	check(player.camera.global_position.x < 7.5, "視点を壁の側へ回した直後の 1 フレームでも、映る視点は壁の中に入らない (%.2f)" % player.camera.global_position.x)

	# 左側 (西) に壁があっても、右へずれるだけなので、縮まない (西には壁がない部屋だが、体の左右で比べる)
	await _reset(PI)  # カメラを反対向きにすると、「右」は西になる
	player.global_position = Vector3(7.0, 0.05, 0.0)
	await _frames(30)
	check(absf(player.arm.position.x - player.SHOULDER_OFFSET) < 0.05, "壁が反対側 (左) にある時は、ずれは縮まない")


func _test_model_hide_hysteresis() -> void:
	# 隠すのは 0.9m 未満、戻すのは 1.1m 以上。その間は、直前の状態を保つ (ちらつかない)
	await _reset(PI)
	player.global_position = Vector3(0, 0.05, -6.8)
	await _frames(15)
	check(not player.model.visible, "壁に近い (0.9m 未満) と、体を隠す")
	player.global_position = Vector3(0, 0.05, -6.2)  # カメラの距離が、隠す 0.9 と戻す 1.1 の間 (約 1.0)
	await _frames(15)
	var hit: float = player.arm.get_hit_length()
	check(hit > 0.9 and hit < 1.1, "カメラの距離が、閾値の間にある (%.2f)" % hit)
	check(not player.model.visible, "閾値の間では、隠れていたら、隠れたまま")

	await _reset(PI)
	player.global_position = START
	await _frames(15)
	player.global_position = Vector3(0, 0.05, -6.2)
	await _frames(15)
	check(player.model.visible, "閾値の間では、見えていたら、見えたまま (ちらつかない)")


func _test_run_fov() -> void:
	await _reset()
	var walk_fov: float = player.camera.fov
	Input.action_press("move_forward")
	Input.action_press("run")
	await _frames(40)
	var run_fov: float = player.camera.fov
	Input.action_release("run")
	Input.action_release("move_forward")
	await _frames(60)
	check(run_fov > walk_fov + 4.0, "走ると、視野が広がって、速さを感じやすい (%.1f → %.1f)" % [walk_fov, run_fov])
	check(absf(player.camera.fov - walk_fov) < 0.5, "止まると、視野が元に戻る")


# hold_frames フレームのあいだの最高点を、base_y (床の高さ。省略すると今の高さ) からの高さで返す
func _jump_peak(hold_frames: int = 60, base_y: float = NAN) -> float:
	var start_y := player.global_position.y if is_nan(base_y) else base_y
	var peak := player.global_position.y
	for i in hold_frames:
		await physics_frame
		peak = maxf(peak, player.global_position.y)
	return peak - start_y


func _test_jump() -> void:
	# ジャンプの高さは、JUMP_HEIGHT (1.2m) 付近。もう一度押しても、空中では跳べない (二段ジャンプなし)
	await _reset()
	var floor_y := player.global_position.y
	Input.action_press("jump")
	var height: float = await _jump_peak(10, floor_y)
	Input.action_release("jump")
	check(player.velocity.y > 0.0 or height > 0.3, "ジャンプで、体が浮く")
	Input.action_press("jump")  # 空中でもう一度
	height = maxf(height, await _jump_peak(50, floor_y))
	Input.action_release("jump")
	check(absf(height - player.JUMP_HEIGHT) < 0.2, "ジャンプの高さは JUMP_HEIGHT 付近 (%.2f m)" % height)
	await _frames(40)
	check(player.is_on_floor(), "ジャンプのあと、着地する")

	# 押しっぱなしでも、着地するたびに跳ぶだけ (空中で勝手に伸びたりしない)
	await _reset()
	Input.action_press("jump")
	var held: float = await _jump_peak(30)
	Input.action_release("jump")
	check(held < player.JUMP_HEIGHT + 0.2, "押しっぱなしでも、1 回の高さを超えない (%.2f m)" % held)

	# 地面を離れた直後 (コヨーテタイム) は、まだ跳べる。時間が過ぎたら、跳べない
	await _reset()
	player.global_position = Vector3(0, 3.0, 4)  # 空中へ移す (直前まで床の上にいた扱い)
	player.velocity = Vector3.ZERO
	await _frames(3)
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	check(player.velocity.y > 0.0 or player.global_position.y > 3.0, "地面を離れた直後は、まだ跳べる (コヨーテタイム)")

	await _reset()
	player.global_position = Vector3(0, 6.0, 4)
	player.velocity = Vector3.ZERO
	await _frames(15)  # 0.25 秒たつ (猶予 0.12 秒を過ぎる)
	var fall_speed: float = player.velocity.y
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	check(player.velocity.y <= fall_speed, "時間が過ぎたあとの空中では、跳べない")

	# 着地の直前に押しても、着地した時に跳ぶ (先行入力)
	await _reset()
	player.global_position = Vector3(0, 0.30, 4)
	player.velocity = Vector3.ZERO
	await _frames(8)  # 着地の少し前
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	var buffered: float = await _jump_peak(40)
	check(buffered > 0.5, "着地の少し前に押すと、着地した時に跳ぶ (先行入力、%.2f m)" % buffered)

	# 着地よりずっと前 (コヨーテタイムが過ぎたあと、着地の猶予よりも前) に押しても、跳ばない。
	# 1.0m の高さから落とし、0.17 秒たってから押す。着地するのは約 0.45 秒後で、先行入力の猶予は約 0.29 秒まで
	await _reset()
	player.global_position = Vector3(0, 1.0, 4)
	player.velocity = Vector3.ZERO
	await _frames(10)
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	for i in 90:
		if player.is_on_floor():
			break
		await physics_frame
	var too_early: float = await _jump_peak(25)  # 着地してから、勝手に跳ばないか
	check(player.is_on_floor() and too_early < 0.3, "着地よりずっと前に押しても、着地で跳ばない (%.2f m)" % too_early)

	# 空中では、地上より向きを変えにくい。走りジャンプでは、勢いを保つ
	await _reset()
	Input.action_press("move_forward")
	Input.action_press("run")
	await _frames(40)
	Input.action_press("jump")
	await _frames(3)
	Input.action_release("jump")
	await _frames(10)
	var air_speed := _horizontal(player.velocity).length()
	Input.action_release("run")
	Input.action_release("move_forward")
	check(not player.is_on_floor() and air_speed > player.RUN_SPEED * 0.8, "走りジャンプでは、空中でも勢いを保つ (%.2f)" % air_speed)

	await _reset()
	player.global_position = Vector3(0, 3.0, 4)
	player.velocity = Vector3.ZERO
	await _frames(2)
	Input.action_press("move_forward")
	await _frames(10)
	var air_control := _horizontal(player.velocity).length()
	Input.action_release("move_forward")
	check(air_control < player.WALK_SPEED * 0.7, "空中では、地上ほど急には向きや速さを変えられない (%.2f)" % air_control)


func _test_rest_action() -> void:
	# 篝火の近くで「休む」の操作 (E キーやコントローラーの A) を受けると、復帰地点が変わる
	await _reset()
	var fire: Node3D = scene.get_node("BonfireFar")
	player.global_position = fire.rest_position()
	await _frames(10)
	var event := InputEventAction.new()
	event.action = "rest"
	event.pressed = true
	player._unhandled_input(event)
	check(player.spawn_position.distance_to(fire.rest_position()) < 0.1, "「休む」の操作で、篝火が復帰地点になる")
