class_name DeathBanner
extends CanvasLayer
# 倒れた時の、画面全体の表示。暗くなり、中央に、死を意味する英単語 (TEXT) が、ゆっくり浮かぶ。
# 復活する時に、消える

const TEXT := "DECEASED"  # 死亡を意味する語。変えたければ、ここだけ
const FADE_SECONDS := 0.9

var label: Label
var shade: ColorRect


func _init() -> void:
	name = "DeathBanner"
	layer = 40
	visible = false
	shade = ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.0)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	label = Label.new()
	label.text = TEXT
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 84)
	label.add_theme_color_override("font_color", Color(0.62, 0.10, 0.08))
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("outline_size", 10)
	var font_path := "res://assets/fonts/Cinzel.ttf"
	if ResourceLoader.exists(font_path):
		label.add_theme_font_override("font", load(font_path))
	label.modulate.a = 0.0
	add_child(label)


# 暗くして、文字を浮かべる
func show_banner() -> void:
	visible = true
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(shade, "color:a", 0.55, FADE_SECONDS)
	tween.tween_property(label, "modulate:a", 1.0, FADE_SECONDS)


# すぐ消す
func hide_banner() -> void:
	visible = false
	shade.color.a = 0.0
	label.modulate.a = 0.0
