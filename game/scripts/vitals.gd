class_name Vitals
extends Control
# 体力 (赤) とスタミナ (緑) の、細い棒。画面の左上、時計の下。PlayerCombat の値を映す

const BAR_WIDTH := 240.0
const BAR_HEIGHT := 8.0

var health_bar: ColorRect
var stamina_bar: ColorRect
var _combat: PlayerCombat


func _init() -> void:
	name = "Vitals"
	position = Vector2(30.0, 56.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	health_bar = _make_bar(Color(0.72, 0.16, 0.14), 0.0)
	stamina_bar = _make_bar(Color(0.36, 0.62, 0.30), BAR_HEIGHT + 6.0)


func bind(combat: PlayerCombat) -> void:
	_combat = combat
	combat.changed.connect(_refresh)
	_refresh()


# 体力とスタミナを、棒の長さに映す
func _refresh() -> void:
	health_bar.size.x = BAR_WIDTH * clampf(_combat.health / PlayerCombat.MAX_HEALTH, 0.0, 1.0)
	stamina_bar.size.x = BAR_WIDTH * clampf(_combat.stamina / PlayerCombat.MAX_STAMINA, 0.0, 1.0)


# 暗い背景の上に、色つきの棒を重ねる。色つきの棒を返す
func _make_bar(color: Color, top: float) -> ColorRect:
	var back := ColorRect.new()
	back.color = Color(0.0, 0.0, 0.0, 0.55)
	back.position = Vector2(0.0, top)
	back.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(back)
	var bar := ColorRect.new()
	bar.color = color
	bar.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.add_child(bar)
	return bar
