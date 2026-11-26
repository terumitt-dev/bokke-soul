class_name CharacterModel
extends Node3D
# プレイヤーの見た目 (人型のモデルと、その動き)。モデルは、1 つのファイル (GLB) を差し替えれば、変えられる。
# 読み込めなければ、親の、仮のカプセルを、そのまま見せる (Body、Facing)。
#
# 動きの名前は、モデルに入っている動き (AnimationPlayer) の名前。KayKit の動きの名前が、いまの既定。
# モデルを変えたら、ANIMATIONS の対応を、そのモデルの名前に直す

const MODEL_PATH := "res://assets/characters/kaykit/Rogue_Hooded.glb"
const HEIGHT := 1.8  # 立った時の背の高さ (m)。モデルを、この高さに合わせる
const BLEND := 0.15  # 動きの切り替えで、混ぜる時間 (秒)

# 状態 → 動きの名前
const ANIMATIONS := {
	"idle": "Idle",
	"walk": "Walking_A",
	"run": "Running_A",
	"air": "Jump_Idle",
	"rest": "Interact",
}
# 手に持つ武器 (手のスロットに付いている)。いまは持たせないので、隠す。戦闘の土台で、持たせる
const WEAPON_PARTS := ["Knife_Offhand", "1H_Crossbow", "2H_Crossbow", "Knife", "Throwable"]
const LOOPING := ["idle", "walk", "run", "air"]  # くり返す動き。ほかは、1 回だけ

var model: Node3D  # 読み込んだモデル。なければ null
var animation_player: AnimationPlayer
var state := ""  # いま流している状態

var _once_until := 0.0  # 1 回だけの動き (休むなど) を、流している間は、状態の切り替えを待つ。この時刻 (ミリ秒) まで


# path のモデルを読み込んで、背の高さを合わせ、正面を -Z (このゲームの前) に向ける。成功したら true
func load_model(path: String = MODEL_PATH) -> bool:
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
		if mesh.name in WEAPON_PARTS:
			mesh.visible = false
	for fallback in get_parent().find_children("Body", "MeshInstance3D", false, false) + get_parent().find_children("Facing", "MeshInstance3D", false, false):
		fallback.visible = false  # 仮のカプセルは、隠す
	return true


# 状態 (idle、walk、run、air) の動きを流す。同じ状態なら、何もしない。rest などの 1 回だけの動きの間は、待つ
func play_state(new_state: String) -> void:
	if animation_player == null or new_state == state:
		return
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


# モデルの高さ (頭のてっぺんと足の差) を HEIGHT に合わせ、足を地面 (y = 0) に置く
func _fit_height() -> void:
	var low := INF
	var high := -INF
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mesh.name in WEAPON_PARTS:
			continue  # 武器は、背の高さに入れない
		var box: AABB = mesh.global_transform * mesh.get_aabb() if mesh.is_inside_tree() else (model.transform * mesh.transform) * mesh.get_aabb()
		low = minf(low, box.position.y)
		high = maxf(high, box.end.y)
	if high <= low:
		return
	var scale_factor := HEIGHT / (high - low)
	model.scale = Vector3.ONE * scale_factor
	model.position.y = -low * scale_factor
