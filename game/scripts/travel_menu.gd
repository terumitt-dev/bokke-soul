class_name TravelMenu
extends CanvasLayer
# 篝火の移動の一覧。火を灯した篝火の名前を並べ、選ぶと移る。上下 (十字キー、矢印) で選び、決定 (Enter、A) で移り、
# 取り消し (Esc、B) で閉じる。マウスでも選べる。開いている間は、マウスの指を見せる

signal chosen(index: int)  # 一覧の何番目を選んだか
signal closed  # 選ばずに閉じた

const MAX_HEIGHT_RATIO := 0.6  # 一覧の枠の高さの上限 (画面の高さに対する割合)

var buttons: Array[Button] = []
var scroll: ScrollContainer  # 行き先を並べる、スクロールできる枠
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
	# 行き先は、スクロールできる枠に並べる (多くても、画面の外へはみ出さない。選んだ行まで、枠が追う)。「やめる」は、枠の外 (いつも見える)
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	box.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	for i in names.size():
		var button := Button.new()
		button.text = names[i]
		button.custom_minimum_size = Vector2(320, 0)
		button.pressed.connect(func() -> void: _choose(i))
		rows.add_child(button)
		buttons.append(button)
	var cancel := Button.new()
	cancel.text = "やめる"
	cancel.pressed.connect(close)
	box.add_child(cancel)
	buttons.append(cancel)
	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 枠の高さは、行の合計と、画面の高さの上限の、小さい方 (行が少なければ、そのまま。多ければ、スクロールする)
	var rows_height := float(names.size()) * (buttons[0].get_combined_minimum_size().y + 8.0)
	var limit := get_viewport().get_visible_rect().size.y * MAX_HEIGHT_RATIO
	scroll.custom_minimum_size = Vector2(340.0, minf(rows_height, limit))
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
