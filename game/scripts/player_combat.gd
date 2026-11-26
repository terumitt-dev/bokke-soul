class_name PlayerCombat
extends Node
# プレイヤーの戦闘: 攻撃 (弱攻撃を、続けて 3 回まで)、回避、スタミナ、体力。
# 攻撃と回避は、スタミナを使う。回避の最初の間は、攻撃を受けない。敵に当てるのは、前方の、近くの的 (グループ "hurtbox")。
# 動きは、CharacterModel の動き (攻撃、回避) を流す。Player が、毎フレーム tick を呼び、移動の速さを、move_factor で決める

signal changed  # 体力か、スタミナが変わった
signal attacked(index: int)  # 攻撃を始めた (何撃目か。0 から)
signal dodged
signal hit_landed(target: Node, damage: float)  # 的に当てた
signal died

const MAX_HEALTH := 100.0
const MAX_STAMINA := 100.0
const ATTACK_COST := 18.0
const DODGE_COST := 25.0
const STAMINA_REGEN := 35.0  # 1 秒に、回復する量
const REGEN_DELAY := 0.7  # 使ってから、回復が始まるまでの時間 (秒)
const ATTACK_SPEED := 1.3  # 攻撃の動きの速さ (倍)
const COMBO_WINDOW := 0.5  # 攻撃が終わってから、続けて 2 撃目に入れる時間 (秒)
const ATTACK_MOVE := 0.2  # 攻撃の間の、歩く速さの割合 (ほとんど動けない)
const ATTACKS := [
	{"state": "attack_1", "damage": 12.0, "hit_start": 0.30, "hit_end": 0.60},
	{"state": "attack_2", "damage": 14.0, "hit_start": 0.30, "hit_end": 0.60},
	{"state": "attack_3", "damage": 22.0, "hit_start": 0.35, "hit_end": 0.65},  # 3 撃目は、重い
]
const HIT_RANGE := 1.9  # 当たる距離 (m)
const HIT_ANGLE := deg_to_rad(80.0)  # 当たる範囲の、正面からの角度
const DODGE_TIME := 0.5  # 回避の長さ (秒)
const DODGE_SPEED := 8.0  # 回避で進む速さ (m/s)
const DODGE_INVULNERABLE := 0.3  # 回避の最初の、攻撃を受けない時間 (秒)

var health := MAX_HEALTH
var stamina := MAX_STAMINA
var dodge_velocity := Vector2.ZERO  # 回避の間の、水平の速さ。回避していなければ、ゼロ

var _player: CharacterBody3D
var _character: CharacterModel
var _action := ""  # "" (何もしていない)、"attack"、"dodge"
var _action_time := 0.0
var _action_length := 0.0
var _index := 0  # いまの攻撃が、何撃目か
var _next_index := 0  # 続けて攻撃した時の、何撃目か
var _combo_left := 0.0  # 続けて 2 撃目に入れる残り時間
var _queued := false  # 攻撃の最中に、もう一度押した (終わったら、続けて攻撃する)
var _regen_wait := 0.0
var _invulnerable_left := 0.0
var _hit_done := {}  # この攻撃で、すでに当てた的


func setup(player: CharacterBody3D, character: CharacterModel) -> void:
	_player = player
	_character = character


func is_busy() -> bool:
	return _action != ""


func is_dodging() -> bool:
	return _action == "dodge"


func is_invulnerable() -> bool:
	return _invulnerable_left > 0.0


# 移動の速さの割合 (1 が、いつも通り)。攻撃の間は、ほとんど動けない
func move_factor() -> float:
	return ATTACK_MOVE if _action == "attack" else 1.0


# 攻撃する。始められたら (攻撃の最中なら、続けて攻撃する予約をして) true。スタミナがなければ false
func try_attack(aim: Vector3 = Vector3.ZERO) -> bool:
	if _action == "dodge" or stamina <= 0.0 or health <= 0.0:
		return false
	if _action == "attack":
		_queued = _index < ATTACKS.size() - 1  # 3 撃目の最中は、続けられない
		return _queued
	_start_attack(_next_index if _combo_left > 0.0 else 0, aim)
	return true


# 回避する。direction は、世界の向き (ゼロなら、後ろへ)。始められたら true
func try_dodge(direction: Vector3 = Vector3.ZERO) -> bool:
	if _action == "dodge" or stamina <= 0.0 or health <= 0.0:
		return false
	_spend(DODGE_COST)
	_queued = false
	var facing := _facing()
	var along := direction
	along.y = 0.0
	if along.length() < 0.1:
		along = -facing  # 向きの入力がなければ、後ろへ
	along = along.normalized()
	# 体の向きから見て、前、後ろ、左、右のどれか
	var forward_amount := along.dot(facing)
	var side_amount := along.dot(facing.cross(Vector3.UP))
	var name := "dodge_forward" if forward_amount > 0.7 else ("dodge_backward" if forward_amount < -0.7 else ("dodge_right" if side_amount > 0.0 else "dodge_left"))
	_action = "dodge"
	_action_time = 0.0
	_action_length = DODGE_TIME
	_invulnerable_left = DODGE_INVULNERABLE
	dodge_velocity = Vector2(along.x, along.z) * DODGE_SPEED
	_character.end_action()
	_character.play_action(name, _character_length_speed(name))
	dodged.emit()
	return true


# ダメージを受ける。回避の最初の間は、受けない (false)。体力がなくなったら、died を出す
func take_damage(amount: float, _source: Node = null) -> bool:
	if is_invulnerable() or health <= 0.0:
		return false
	health = maxf(health - amount, 0.0)
	changed.emit()
	if health <= 0.0:
		_action = ""
		dodge_velocity = Vector2.ZERO
		_character.end_action()
		_character.play_action("death")
		died.emit()
	elif _action == "":
		_character.end_action()
		_character.play_action("hit")
	return true


# 毎フレーム (Player が呼ぶ): 動きを進め、当たりを調べ、スタミナを回復する
func tick(delta: float) -> void:
	_invulnerable_left = maxf(_invulnerable_left - delta, 0.0)
	if _action == "":
		_combo_left = maxf(_combo_left - delta, 0.0)
		_regen_wait = maxf(_regen_wait - delta, 0.0)
		if _regen_wait <= 0.0 and stamina < MAX_STAMINA:
			stamina = minf(stamina + STAMINA_REGEN * delta, MAX_STAMINA)
			changed.emit()
		return
	_action_time += delta
	if _action == "attack":
		var progress := _action_time / _action_length
		if progress >= ATTACKS[_index].hit_start and progress <= ATTACKS[_index].hit_end:
			_apply_hits(ATTACKS[_index])
		if _action_time >= _action_length:
			_finish_attack()
	elif _action_time >= _action_length:
		_action = ""
		dodge_velocity = Vector2.ZERO
		_regen_wait = REGEN_DELAY


func _start_attack(index: int, aim: Vector3) -> void:
	_spend(ATTACK_COST)
	_action = "attack"
	_index = index
	_action_time = 0.0
	_queued = false
	_hit_done.clear()
	if aim.length() > 0.1:
		# 入力の向きへ、体を向けてから、振る
		_player.model.rotation.y = atan2(-aim.x, -aim.z)
	_character.end_action()
	_action_length = _character.play_action(ATTACKS[index].state, ATTACK_SPEED)
	attacked.emit(index)


func _finish_attack() -> void:
	if _queued and stamina > 0.0 and _index < ATTACKS.size() - 1:
		_start_attack(_index + 1, Vector3.ZERO)  # 続けて、次の攻撃
		return
	_next_index = (_index + 1) % ATTACKS.size()
	_combo_left = COMBO_WINDOW
	_action = ""
	_regen_wait = REGEN_DELAY


# 前方の、近くの的に、まだ当てていなければ、当てる
func _apply_hits(attack: Dictionary) -> void:
	var facing := _facing()
	for target: Node3D in get_tree().get_nodes_in_group("hurtbox"):
		if _hit_done.has(target) or not target.has_method("take_damage"):
			continue
		var offset: Vector3 = target.global_position - _player.global_position
		var flat := Vector3(offset.x, 0.0, offset.z)
		if flat.length() > HIT_RANGE or absf(offset.y) > 2.0:
			continue
		if flat.length() > 0.05 and facing.angle_to(flat.normalized()) > HIT_ANGLE:
			continue
		_hit_done[target] = true
		target.take_damage(attack.damage, _player)
		hit_landed.emit(target, attack.damage)


func _spend(cost: float) -> void:
	stamina = maxf(stamina - cost, 0.0)
	_regen_wait = REGEN_DELAY
	changed.emit()


# 体が向いている、水平の向き (正面は、-Z を、体の向きの分だけ回したもの)
func _facing() -> Vector3:
	return Basis(Vector3.UP, _player.model.rotation.y) * Vector3(0.0, 0.0, -1.0)


# 回避の動きの速さ (倍)。動きの長さが DODGE_TIME に合うようにする
func _character_length_speed(name: String) -> float:
	var animation_name: String = CharacterModel.ANIMATIONS.get(name, "")
	if _character.animation_player == null or not _character.animation_player.has_animation(animation_name):
		return 1.0
	return _character.animation_player.get_animation(animation_name).length / DODGE_TIME
