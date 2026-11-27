class_name TrainingDummy
extends StaticBody3D
# 的 (案山子)。当てると、ダメージの数字が浮き、体力がなくなると倒れて、しばらくして起き上がる。
# 戦闘を試すための仮のもの。敵 (動く、攻撃してくる) は、あとで足す。置き方は、配置の仕組みができたら、そちらへ移す

signal damaged(amount: float)
signal defeated

const MAX_HEALTH := 60.0
const RESPAWN_SECONDS := 4.0

var health := MAX_HEALTH
var is_defeated := false
var last_damage := 0.0

var _body: Node3D
var _material: StandardMaterial3D
var _flash_tween: Tween


func _ready() -> void:
	add_to_group("hurtbox")
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.55, 0.45, 0.32)
	_material.roughness = 1.0
	_material.emission_enabled = true
	_material.emission = Color(1.0, 0.3, 0.2)
	_material.emission_energy_multiplier = 0.0
	_body = Node3D.new()
	add_child(_body)
	_add_part(CylinderMesh.new(), Vector3(0.0, 0.7, 0.0), Vector3(0.24, 1.4, 0.24))  # 柱
	_add_part(BoxMesh.new(), Vector3(0.0, 1.15, 0.0), Vector3(0.9, 0.12, 0.12))  # 横木
	_add_part(SphereMesh.new(), Vector3(0.0, 1.55, 0.0), Vector3(0.32, 0.32, 0.32))  # 頭
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.7
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.85, 0.0)
	add_child(shape)


# ダメージを受ける。倒れている間は、受けない (false)
func take_damage(amount: float, _source: Node = null) -> bool:
	if is_defeated:
		return false
	health = maxf(health - amount, 0.0)
	last_damage = amount
	damaged.emit(amount)
	_show_number(amount)
	_flash()
	if health <= 0.0:
		_fall()
	return true


# 見た目の部品を足す (mesh は、size の大きさで、position に置く。円柱と球は、size の x と y で、半径と高さを決める)
func _add_part(mesh: Mesh, position: Vector3, size: Vector3) -> void:
	if mesh is CylinderMesh:
		mesh.top_radius = size.x / 2.0
		mesh.bottom_radius = size.x / 2.0
		mesh.height = size.y
	elif mesh is SphereMesh:
		mesh.radius = size.x / 2.0
		mesh.height = size.x
	elif mesh is BoxMesh:
		mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material
	instance.position = position
	_body.add_child(instance)


# 当たった時に、一瞬、赤く光る
func _flash() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()  # 連続で当たった時に、光り方が重ならないように
	_material.emission_energy_multiplier = 2.5
	_flash_tween = create_tween()
	_flash_tween.tween_property(_material, "emission_energy_multiplier", 0.0, 0.25)


# ダメージの数字を、頭の上に出す
func _show_number(amount: float) -> void:
	DamageNumber.spawn(self, amount, 2.0)


# 倒れて、しばらくしたら、起き上がる
func _fall() -> void:
	is_defeated = true
	defeated.emit()
	var tween := create_tween()
	tween.tween_property(_body, "rotation:x", deg_to_rad(-80.0), 0.35)
	tween.tween_interval(RESPAWN_SECONDS)
	tween.tween_callback(_get_up)


func _get_up() -> void:
	health = MAX_HEALTH
	is_defeated = false
	var tween := create_tween()
	tween.tween_property(_body, "rotation:x", 0.0, 0.3)
