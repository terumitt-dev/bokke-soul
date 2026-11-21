class_name RevealMap
extends RefCounted
# 世界を真上から見た地図に、「歩いて確かめた所」を書き込む。
# 値は 0 (まだ) 〜 1 (確かめた)。シェーダーが、この地図を見て、点やメッシュの見え方を決める。
# 一度確かめた所は、消えない (値は大きくなる方へしか変わらない)

const MAX_PIXELS := 4_000_000

var origin := Vector2.ZERO  # 世界の水平座標 (x, z) の最小値
var size := Vector2.ONE  # 世界の水平方向の大きさ (m)
var cell := 0.5  # 1 画素が表す長さ (m)
var texture: ImageTexture

var _image: Image
var _dirty := false


# bounds は、世界全体の範囲。cell は、1 画素の長さ (世界が大きすぎる時は、自動で粗くする)
func _init(bounds: AABB, cell_size: float = 0.5) -> void:
	origin = Vector2(bounds.position.x, bounds.position.z)
	size = Vector2(maxf(bounds.size.x, 0.001), maxf(bounds.size.z, 0.001))
	cell = maxf(cell_size, 0.01)
	var pixels := (size.x / cell) * (size.y / cell)
	if pixels > MAX_PIXELS:
		cell *= sqrt(pixels / MAX_PIXELS)
	_image = Image.create(maxi(ceili(size.x / cell), 1), maxi(ceili(size.y / cell), 1), false, Image.FORMAT_R8)
	texture = ImageTexture.create_from_image(_image)


func width() -> int:
	return _image.get_width()


func height() -> int:
	return _image.get_height()


# 世界の位置 (x, z) の画素。範囲の外は、範囲の中へ丸める
func pixel_of(world_position: Vector3) -> Vector2i:
	var p := (Vector2(world_position.x, world_position.z) - origin) / cell
	return Vector2i(clampi(int(floor(p.x)), 0, width() - 1), clampi(int(floor(p.y)), 0, height() - 1))


# 世界の位置 (x, z) の周り、radius (m) を確かめた所にする。中心に近い所は 1、縁へ向けてなめらかに 0 になる。
# すでに大きい値の所は、そのまま (消えない)
func paint(world_position: Vector3, radius: float) -> void:
	var center := (Vector2(world_position.x, world_position.z) - origin) / cell
	var reach := radius / cell
	var x0 := maxi(int(floor(center.x - reach)), 0)
	var x1 := mini(int(ceil(center.x + reach)), width() - 1)
	var y0 := maxi(int(floor(center.y - reach)), 0)
	var y1 := mini(int(ceil(center.y + reach)), height() - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(center) / reach
			if distance >= 1.0:
				continue
			var value := 1.0 - smoothstep(0.55, 1.0, distance)
			if value > _image.get_pixel(x, y).r:
				_image.set_pixel(x, y, Color(value, 0.0, 0.0))
				_dirty = true


# 世界の位置 (x, z) が、どれだけ確かめられているか (0〜1)
func sample(world_position: Vector3) -> float:
	var pixel := pixel_of(world_position)
	return _image.get_pixel(pixel.x, pixel.y).r


# 確かめた所 (0.5 以上) が、世界全体のどれだけを占めるか (0〜1)
func coverage() -> float:
	var count := 0
	for y in height():
		for x in width():
			if _image.get_pixel(x, y).r >= 0.5:
				count += 1
	return float(count) / float(width() * height())


# 書き込みがあれば、シェーダーが見るテクスチャへ反映する (毎フレームではなく、間引いて呼ぶ)
func update_texture() -> bool:
	if not _dirty:
		return false
	texture.update(_image)
	_dirty = false
	return true
