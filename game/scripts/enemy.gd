class_name Enemy
extends CharacterBody3D
# 敵 (骸骨)。プレイヤーを見つけたら、近づき、近づいたら剣を振る。倒すと、消える。
# 的と同じ、take_damage を持つ (グループ "hurtbox")。見た目は、CharacterModel (骸骨のモデルと、剣)。
# いまは、1 種類の攻撃だけ。見つける範囲は、距離だけ (壁越しでも見つける。視線の判定は、あとで足す)

signal damaged(amount: float)
signal defeated

enum State { IDLE, CHASE, ATTACK, STAGGER, DEAD }

const MODEL_PATH := "res://assets/characters/kaykit_skeletons/Skeleton_Minion.glb"
const WEAPON_PATH := "res://assets/characters/kaykit_skeletons/weapons/Skeleton_Blade.gltf"
const WEAPON_SLOT := "handslot.r"  # 骸骨の骨の名前
const MAX_HEALTH := 40.0
const DETECT_RANGE := 14.0  # この距離に入ると、プレイヤーを見つける
const LOSE_RANGE := 24.0  # これより離れると、見失う
const ATTACK_RANGE := 1.9  # この距離で、振る
const SPEED := 3.4
const TURN_SPEED := 8.0
const ATTACK_DAMAGE := 12.0
const ATTACK_HIT_TIME := 0.5  # 振り始めてから、当たるまで (秒)。この間に、回避できる
const ATTACK_TIME := 1.0  # 1 回の攻撃の長さ (秒)
const ATTACK_COOLDOWN := 1.0  # 振り終わってから、次に振るまで (秒)
const STAGGER_TIME := 0.5  # ひるむ時間 (秒)
const KNOCKBACK := 3.0  # 当てられた時に、押される速さ (m/s)
const VANISH_SECONDS := 1.2  # 倒れてから、消えるまで (秒)

var health := MAX_HEALTH
var state := State.IDLE
var spawn_position := Vector3.ZERO  # 最初にいた場所 (見失ったら、ここへ戻る。復活の場所)

var character: CharacterModel
var _target: Node3D
var _timer := 0.0
var _cooldown := 0.0
var _hit_done := false
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	add_to_group("hurtbox")
	add_to_group("enemy")
	spawn_position = global_position
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.7
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.85, 0.0)
	add_child(shape)
	var body := Node3D.new()
	body.name = "Model"
	add_child(body)
	character = CharacterModel.new()
	character.name = "Character"
	character.model_path = MODEL_PATH
	character.weapon_path = WEAPON_PATH
	character.weapon_slot = WEAPON_SLOT
	character.height = 1.7
	character.weapon_parts = []
	body.add_child(character)
	character.load_model()


# 見つける相手 (プレイヤー)。グループ "player" の、最初のもの
func _find_target() -> Node3D:
	if is_instance_valid(_target):
		return _target
	_target = get_tree().get_first_node_in_group("player")
	return _target


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	if not is_on_floor():
		velocity.y -= _gravity * delta
	var target := _find_target()
	var to_target := Vector3.ZERO
	var distance := INF
	var target_alive: bool = target != null and not (target.get("combat") != null and target.combat.is_dead())
	if target != null:
		to_target = target.global_position - global_position
		to_target.y = 0.0
		distance = to_target.length()
	match state:
		State.IDLE:
			_stop(delta)
			character.play_state("idle")
			if target_alive and distance < DETECT_RANGE:
				state = State.CHASE
		State.CHASE:
			if not target_alive or distance > LOSE_RANGE:
				state = State.IDLE
			elif distance <= ATTACK_RANGE * 0.9 and _cooldown <= 0.0:
				_start_attack(to_target)
			else:
				_face(to_target, delta)
				var move := to_target.normalized() * SPEED if distance > ATTACK_RANGE * 0.7 else Vector3.ZERO
				velocity.x = move.x
				velocity.z = move.z
				character.play_state("run" if distance > ATTACK_RANGE * 0.7 else "idle")
		State.ATTACK:
			_stop(delta)
			_timer += delta
			if not _hit_done and _timer >= ATTACK_HIT_TIME:
				_hit_done = true
				_strike(target)
			if _timer >= ATTACK_TIME:
				_cooldown = ATTACK_COOLDOWN
				state = State.CHASE
		State.STAGGER:
			velocity.x = move_toward(velocity.x, 0.0, KNOCKBACK * 4.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, KNOCKBACK * 4.0 * delta)
			_timer += delta
			if _timer >= STAGGER_TIME:
				state = State.CHASE
	move_and_slide()


# ダメージを受ける。倒れている間は、受けない (false)。体力がなくなると、倒れて、消える。当てられたら、ひるんで、押される
func take_damage(amount: float, source: Node = null) -> bool:
	if state == State.DEAD:
		return false
	health = maxf(health - amount, 0.0)
	damaged.emit(amount)
	DamageNumber.spawn(self, amount, 2.0)
	if health <= 0.0:
		_die()
		return true
	if source is Node3D:
		var away: Vector3 = global_position - (source as Node3D).global_position
		away.y = 0.0
		if away.length() > 0.01:
			velocity.x = away.normalized().x * KNOCKBACK
			velocity.z = away.normalized().z * KNOCKBACK
		_target = source
	state = State.STAGGER
	_timer = 0.0
	character.play_action("hit")
	return true


# 最初の場所で、体力を満タンにして、立て直す (プレイヤーが休んだ、復活した時)
func reset() -> void:
	if state == State.DEAD:
		return
	health = MAX_HEALTH
	state = State.IDLE
	velocity = Vector3.ZERO
	global_position = spawn_position
	_cooldown = 0.0


func _start_attack(to_target: Vector3) -> void:
	state = State.ATTACK
	_timer = 0.0
	_hit_done = false
	_face(to_target, 1.0)
	character.play_action("attack_2", character.animation_player.get_animation(CharacterModel.ANIMATIONS["attack_2"]).length / ATTACK_TIME if character.animation_player != null else 1.0)


# 振る: 近く (少し余裕のある範囲) の、前にいるプレイヤーに、ダメージを与える。回避の最初の間は、受けられない
func _strike(target: Node3D) -> void:
	if target == null or not target.has_method("take_damage"):
		return
	var offset := target.global_position - global_position
	var flat := Vector3(offset.x, 0.0, offset.z)
	var facing := Basis(Vector3.UP, $Model.rotation.y) * Vector3(0.0, 0.0, -1.0)
	if flat.length() <= ATTACK_RANGE + 0.5 and absf(offset.y) < 2.0 and (flat.length() < 0.05 or facing.angle_to(flat.normalized()) < deg_to_rad(80.0)):
		target.take_damage(ATTACK_DAMAGE, self)


func _die() -> void:
	state = State.DEAD
	velocity = Vector3.ZERO
	character.end_action()
	character.play_action("death")
	defeated.emit()
	for child in get_children():
		if child is CollisionShape3D:
			child.disabled = true  # 倒れたら、通り抜けられる (邪魔にならない)
	remove_from_group("hurtbox")
	var tween := create_tween()
	tween.tween_interval(VANISH_SECONDS)
	tween.tween_property(self, "scale", Vector3.ONE * 0.01, 0.4)
	tween.tween_callback(queue_free)


func _stop(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, SPEED * 6.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, SPEED * 6.0 * delta)


# 体を、to の水平の向きへ、少しずつ向ける (正面は、-Z)
func _face(to: Vector3, delta: float) -> void:
	if to.length() < 0.05:
		return
	var yaw := atan2(-to.x, -to.z)
	$Model.rotation.y = lerp_angle($Model.rotation.y, yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))
