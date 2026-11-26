class_name CharacterModel
extends Node3D
# プレイヤーの見た目 (人型のモデルと、その動き)。モデルは、1 つのファイル (GLB) を差し替えれば、変えられる。
# 読み込めなければ、親の、仮のカプセルを、そのまま見せる (Body、Facing)。
#
# 動きの名前は、モデルに入っている動き (AnimationPlayer) の名前。KayKit の動きの名前が、いまの既定。
# モデルを変えたら、ANIMATIONS の対応を、そのモデルの名前に直す

const MODEL_PATH := "res://assets/characters/kaykit/Rogue_Hooded.glb"
const WEAPON_PATH := "res://assets/characters/kaykit/weapons/sword_1handed.gltf"  # 右手に持つ武器
const HAND_SLOT := "handslot_r"  # モデルの、右手の武器の付け根
const HEIGHT := 1.8  # 立った時の背の高さ (m)。モデルを、この高さに合わせる (既定)
const BLEND := 0.15  # 動きの切り替えで、混ぜる時間 (秒)

# 状態 → 動きの名前
const ANIMATIONS := {
	"idle": "Idle",
	"walk": "Walking_A",
	"run": "Running_A",
	"air": "Jump_Idle",
	"rest": "Interact",
	# 戦闘の動き (1 回だけ)
	"attack_1": "1H_Melee_Attack_Slice_Diagonal",
	"attack_2": "1H_Melee_Attack_Chop",
	"attack_3": "1H_Melee_Attack_Slice_Horizontal",
	"dodge_forward": "Dodge_Forward",
	"dodge_backward": "Dodge_Backward",
	"dodge_left": "Dodge_Left",
	"dodge_right": "Dodge_Right",
	"roll": "Sit_Floor_Idle",  # 転がる時の、体を丸めた姿 (モデルに、転がる動きはない。体全体を、前へ 1 回転させて、転がって見せる)
	"hit": "Hit_A",
	"death": "Death_A",
}
# 手に持つ武器 (手のスロットに付いている)。いまは持たせないので、隠す。戦闘の土台で、持たせる
const WEAPON_PARTS: Array[String] = ["Knife_Offhand", "1H_Crossbow", "2H_Crossbow", "Knife", "Throwable"]
const LOOPING := ["idle", "walk", "run", "air"]  # くり返す動き。ほかは、1 回だけ

# このノードごとの設定 (既定は、プレイヤー)。敵は、別のモデルと武器を設定する
@export var model_path := MODEL_PATH
@export var weapon_path := WEAPON_PATH
@export var weapon_slot := HAND_SLOT  # 武器の付け根。モデルのノードの名前、または、骨の名前
@export var height := HEIGHT
@export var weapon_parts: Array[String] = WEAPON_PARTS  # 最初から付いている武器の部品 (隠す)

var model: Node3D  # 読み込んだモデル。なければ null
var animation_player: AnimationPlayer
var state := ""  # いま流している状態

var weapon: Node3D  # 右手に持っている武器。なければ null
var _action_until := 0.0  # 戦闘の動き (攻撃、回避など) を流している間は、状態の切り替えを待つ。この時刻 (ミリ秒) まで
var _once_until := 0.0  # 1 回だけの動き (休むなど) を、流している間は、状態の切り替えを待つ。この時刻 (ミリ秒) まで


# path のモデルを読み込んで、背の高さを合わせ、正面を -Z (このゲームの前) に向ける。成功したら true
func load_model(path: String = "") -> bool:
	if path.is_empty():
		path = model_path
	if not ResourceLoader.exists(path):
		return false
	var scene: PackedScene = load(path)
	if scene == null:
		return false
	model = scene.instantiate()
	add_child(model)
	# glTF のモデルは、正面が +Z。このゲームの前は -Z なので、半回転させる
	model.rotation.y = PI
	_fit_height()
	var players := model.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		animation_player = players[0]
		for key: String in ANIMATIONS:
			var animation := animation_player.get_animation(ANIMATIONS[key]) if animation_player.has_animation(ANIMATIONS[key]) else null
			if animation != null:
				animation.loop_mode = Animation.LOOP_LINEAR if key in LOOPING else Animation.LOOP_NONE
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mesh.name in weapon_parts:
			mesh.visible = false
	attach_weapon()
	for fallback in get_parent().find_children("Body", "MeshInstance3D", false, false) + get_parent().find_children("Facing", "MeshInstance3D", false, false):
		fallback.visible = false  # 仮のカプセルは、隠す
	return true


# 右手の付け根 (HAND_SLOT) に、武器を持たせる。読み込めない、付け根がなければ、false
func attach_weapon(path: String = "") -> bool:
	if path.is_empty():
		path = weapon_path
	if model == null or path.is_empty() or not ResourceLoader.exists(path):
		return false
	var slot := _slot()
	var scene: PackedScene = load(path)
	if slot == null or scene == null:
		return false
	if weapon != null:
		weapon.queue_free()
	weapon = scene.instantiate()
	weapon.name = "Weapon"
	slot.add_child(weapon)
	return true


# 武器の付け根。モデルの中に、その名前のノードがあればそれ。なければ、その名前の骨に、付け根のノードを作る。なければ null
func _slot() -> Node3D:
	var node := model.find_child(weapon_slot, true, false)
	if node is Node3D:
		return node
	for skeleton: Skeleton3D in model.find_children("*", "Skeleton3D", true, false):
		if skeleton.find_bone(weapon_slot) >= 0:
			var attachment := BoneAttachment3D.new()
			attachment.name = "WeaponSlot"
			attachment.bone_name = weapon_slot
			skeleton.add_child(attachment)
			return attachment
	return null


# 戦闘の動き (攻撃、回避など。ANIMATIONS の名前) を、speed 倍の速さで、1 回流す。動きの長さ (秒) を返す。
# 流している間は、待つ・歩く・走るに切り替わらない。モデルがない、その動きがない時も、長さ (0.5 秒) は返す (戦闘の流れは、動かせる)
func play_action(new_state: String, speed := 1.0) -> float:
	var name: String = ANIMATIONS.get(new_state, "")
	if animation_player == null or name.is_empty() or not animation_player.has_animation(name):
		return 0.5 / maxf(speed, 0.01)
	var length := animation_player.get_animation(name).length / maxf(speed, 0.01)
	_action_until = Time.get_ticks_msec() + length * 1000.0
	state = new_state
	animation_player.play(name, BLEND, speed)
	return length


# 転がる: 体全体を、重心 (高さの半分) の周りに、前へ progress (0〜1) 回転させる。体は、このノードの正面 (-Z) の向きへ転がる
func set_roll(progress: float) -> void:
	var basis := Basis(Vector3.RIGHT, -TAU * clampf(progress, 0.0, 1.0))
	var center := Vector3(0.0, height / 2.0, 0.0)
	transform = Transform3D(basis, center - basis * center)


# 転がるのをやめて、体を元の向きに戻す
func end_roll() -> void:
	transform = Transform3D.IDENTITY


# 戦闘の動きを流しているか
func is_acting() -> bool:
	return Time.get_ticks_msec() < _action_until


# 戦闘の動きを、中断する (次の動きへ、すぐ移る時)
func end_action() -> void:
	_action_until = 0.0


# 状態 (idle、walk、run、air) の動きを流す。同じ状態なら、何もしない。rest などの 1 回だけの動きの間は、待つ
func play_state(new_state: String) -> void:
	if animation_player == null or new_state == state:
		return
	if is_acting():
		return  # 戦闘の動きの途中
	if Time.get_ticks_msec() < _once_until and new_state in ["idle", "walk", "run"]:
		return  # 休む動きの途中。動き出したら、すぐ戻る (下で)
	_play(new_state)


# 1 回だけの動き (休むなど) を流す。動き出す (walk、run、air) か、終わるまで、そのまま
func play_once(new_state: String) -> void:
	if animation_player == null or not ANIMATIONS.has(new_state) or not animation_player.has_animation(ANIMATIONS[new_state]):
		return
	_once_until = Time.get_ticks_msec() + animation_player.get_animation(ANIMATIONS[new_state]).length * 1000.0
	_play(new_state)


# 動きの切り替えで、1 回だけの動きを、中断してよいか (動き出した時)
func interrupt_once() -> void:
	_once_until = 0.0


func _play(new_state: String) -> void:
	var name: String = ANIMATIONS.get(new_state, "")
	if name.is_empty() or not animation_player.has_animation(name):
		return
	state = new_state
	animation_player.play(name, BLEND)


# モデルの高さ (頭のてっぺんと足の差) を HEIGHT に合わせ、足を地面 (y = 0) に置く。
# 高さは、このノードから見た座標で測る (プレイヤーが、場面のどこにいても、同じ結果になる)
func _fit_height() -> void:
	var low := INF
	var high := -INF
	var to_self := global_transform.affine_inverse()
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mesh.name in weapon_parts:
			continue  # 武器は、背の高さに入れない
		var box: AABB = (to_self * mesh.global_transform) * mesh.get_aabb()
		low = minf(low, box.position.y)
		high = maxf(high, box.end.y)
	if high <= low:
		return
	var scale_factor := height / (high - low)
	model.scale = Vector3.ONE * scale_factor
	model.position.y = -low * scale_factor
