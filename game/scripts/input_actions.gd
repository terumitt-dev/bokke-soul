class_name InputActions
extends RefCounted
# 操作の名前と、キーボード・コントローラーの割り当て。
# ゲームの処理は、キーではなく操作の名前 (move_forward など) を見る。
# 割り当ては、ここに足せば、どの処理も変えずに増やせる (コントローラーも同じ)

const DEADZONE := 0.2

# 操作ごとに、キーボードのキー (物理キー)、コントローラーの軸 [軸, 向き]、ボタンを並べる。
# 視点 (look_*) のキーボード側は、マウスの動きで扱うので、キーはない
const ACTIONS := {
	"move_forward": {"keys": [KEY_W], "axes": [[JOY_AXIS_LEFT_Y, -1.0]], "buttons": []},
	"move_back": {"keys": [KEY_S], "axes": [[JOY_AXIS_LEFT_Y, 1.0]], "buttons": []},
	"move_left": {"keys": [KEY_A], "axes": [[JOY_AXIS_LEFT_X, -1.0]], "buttons": []},
	"move_right": {"keys": [KEY_D], "axes": [[JOY_AXIS_LEFT_X, 1.0]], "buttons": []},
	"look_up": {"keys": [], "axes": [[JOY_AXIS_RIGHT_Y, -1.0]], "buttons": []},
	"look_down": {"keys": [], "axes": [[JOY_AXIS_RIGHT_Y, 1.0]], "buttons": []},
	"look_left": {"keys": [], "axes": [[JOY_AXIS_RIGHT_X, -1.0]], "buttons": []},
	"look_right": {"keys": [], "axes": [[JOY_AXIS_RIGHT_X, 1.0]], "buttons": []},
	"run": {"keys": [KEY_SHIFT], "axes": [], "buttons": [JOY_BUTTON_B]},
	"rest": {"keys": [KEY_E], "axes": [], "buttons": [JOY_BUTTON_A]},
}


# 操作を登録する。何度呼んでも、すでにある操作は触らない
static func ensure() -> void:
	for action: String in ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, DEADZONE)
		var spec: Dictionary = ACTIONS[action]
		for key: int in spec.keys:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)
		for axis: Array in spec.axes:
			var event := InputEventJoypadMotion.new()
			event.axis = axis[0]
			event.axis_value = axis[1]
			InputMap.action_add_event(action, event)
		for button: int in spec.buttons:
			var event := InputEventJoypadButton.new()
			event.button_index = button
			InputMap.action_add_event(action, event)
