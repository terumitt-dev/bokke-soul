class_name DamageNumber
extends Label3D
# ダメージの数字。当たった所の上に出て、浮きながら消える (的も、敵も、同じ)


# parent の上、height (m) の高さに、amount を出す
static func spawn(parent: Node3D, amount: float, height := 2.0) -> void:
	var label := DamageNumber.new()
	label.text = str(int(round(amount)))
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 64
	label.outline_size = 12
	label.no_depth_test = true
	label.position = Vector3(0.0, height, 0.0)
	parent.add_child(label)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", height + 0.8, 0.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.8)
	tween.chain().tween_callback(label.queue_free)
