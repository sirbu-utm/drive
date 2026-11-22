class_name InputSetup
extends RefCounted
## Registers the driving input actions in code (keyboard + gamepad), so project.godot stays free of serialized events.
## Call InputSetup.ensure() once (PlayerController does it).

static var _done := false

static func _key(code: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	return e

static func _axis(axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	return e

static func _btn(b: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = b
	return e

static func _add(action: String, events: Array, deadzone: float = 0.1) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, deadzone)
	for e in events:
		InputMap.action_add_event(action, e)

static func ensure() -> void:
	if _done:
		return
	_done = true
	_add("throttle", [_key(KEY_W), _key(KEY_UP), _axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)], 0.05)
	_add("brake", [_key(KEY_S), _key(KEY_DOWN), _axis(JOY_AXIS_TRIGGER_LEFT, 1.0)], 0.05)
	_add("steer_left", [_key(KEY_A), _key(KEY_LEFT), _axis(JOY_AXIS_LEFT_X, -1.0)], 0.0)
	_add("steer_right", [_key(KEY_D), _key(KEY_RIGHT), _axis(JOY_AXIS_LEFT_X, 1.0)], 0.0)
	_add("handbrake", [_key(KEY_SPACE), _btn(JOY_BUTTON_A)])
	_add("shift_up", [_key(KEY_E), _key(KEY_SHIFT), _btn(JOY_BUTTON_RIGHT_SHOULDER)])
	_add("shift_down", [_key(KEY_Q), _key(KEY_CTRL), _btn(JOY_BUTTON_LEFT_SHOULDER)])
	_add("camera_next", [_key(KEY_C), _btn(JOY_BUTTON_Y)])
	_add("reset_car", [_key(KEY_R), _btn(JOY_BUTTON_BACK)])
	_add("telemetry", [_key(KEY_F1)])
	_add("toggle_abs", [_key(KEY_F2)])
	_add("toggle_tcs", [_key(KEY_F3)])
	_add("toggle_esc", [_key(KEY_F4)])
	_add("toggle_gearbox", [_key(KEY_F5), _btn(JOY_BUTTON_X)])
	_add("toggle_countersteer", [_key(KEY_F6)])
	_add("toggle_headlights", [_key(KEY_L), _btn(JOY_BUTTON_DPAD_UP)])
