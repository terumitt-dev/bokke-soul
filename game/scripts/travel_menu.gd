class_name TravelMenu
extends CanvasLayer
# 篝火の移動の一覧。火を灯した篝火の名前を並べ、選ぶと移る。上下 (十字キー、矢印) で選び、決定 (Enter、A) で移り、
# 取り消し (Esc、B) で閉じる。マウスでも選べる。開いている間は、マウスの指を見せる

signal chosen(index: int)  # 一覧の何番目を選んだか
signal closed  # 選ばずに閉じた

var buttons: Array[Button] = []
var _previous_mouse_mode := Input.MOUSE_MODE_CAPTURED


# names の順に並べて、開く。先頭を選んだ状態にする
func open(names: Array[String]) -> void:
	if not buttons.is_empty():
		return  # すでに開いている
	layer = 50
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	center.add_child(box)
	var title := Label.new()
	title.text = "どの篝火へ移りますか"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	for i in names.size():
		var button := Button.new()
		button.text = names[i]
		button.custom_minimum_size = Vector2(320, 0)
		button.pressed.connect(func() -> void: _choose(i))
		box.add_child(button)
		buttons.append(button)
	var cancel := Button.new()
	cancel.text = "やめる"
	cancel.pressed.connect(close)
	box.add_child(cancel)
	buttons.append(cancel)
	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	buttons[0].grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if buttons.is_empty():
		return
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return not buttons.is_empty()


# 選んで、閉じる
func _choose(index: int) -> void:
	_dismiss()
	chosen.emit(index)


# 選ばずに、閉じる
func close() -> void:
	if buttons.is_empty():
		return
	_dismiss()
	closed.emit()


func _dismiss() -> void:
	buttons.clear()
	Input.mouse_mode = _previous_mouse_mode
	queue_free()
