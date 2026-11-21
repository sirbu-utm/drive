class_name PlayerController
extends Node
## Reads keyboard / gamepad input and drives a Vehicle through the InputFilter.
## W/S/A/D or arrows, Space = handbrake, E/Q or Shift/Ctrl = gear up/down (manual box), R = reset,
## F1 telemetry, F2 ABS, F3 TCS, F4 ESC, F5 auto/manual gearbox, F6 counter-steer helper.

signal reset_requested
signal telemetry_toggled
signal assist_changed(name: String, on: bool)

@export var vehicle: Vehicle
var filter: InputFilter
var manual_gearbox := false
var use_keyboard := true
var enabled := true


func _ready() -> void:
	InputSetup.ensure()
	if vehicle != null:
		filter = InputFilter.new(vehicle.params)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		use_keyboard = true
	elif event is InputEventJoypadButton:
		use_keyboard = false
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) > 0.3:
			use_keyboard = false


func _physics_process(dt: float) -> void:
	if vehicle == null or not enabled:
		return
	if filter == null:
		filter = InputFilter.new(vehicle.params)
	var thr := Input.get_action_strength("throttle")
	var brk := Input.get_action_strength("brake")
	var steer := Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left")
	filter.analog_steer = not use_keyboard
	filter.update(dt, thr, brk, steer, use_keyboard, vehicle.fwd_speed)
	var extra := 0.0
	vehicle.set_reverse(filter.reverse)
	var angle := filter.steer_angle(vehicle.fwd_speed, extra)
	vehicle.drive(filter.throttle, filter.brake, angle, Input.get_action_strength("handbrake"))
	if manual_gearbox:
		if Input.is_action_just_pressed("shift_up"):
			vehicle.shift_up()
		if Input.is_action_just_pressed("shift_down"):
			vehicle.shift_down()
	if Input.is_action_just_pressed("reset_car"):
		reset_requested.emit()
	if Input.is_action_just_pressed("telemetry"):
		telemetry_toggled.emit()
	if Input.is_action_just_pressed("toggle_abs"):
		vehicle.assists.abs_on = not vehicle.assists.abs_on
		assist_changed.emit("ABS", vehicle.assists.abs_on)
	if Input.is_action_just_pressed("toggle_tcs"):
		vehicle.assists.tcs_on = not vehicle.assists.tcs_on
		assist_changed.emit("TCS", vehicle.assists.tcs_on)
	if Input.is_action_just_pressed("toggle_esc"):
		vehicle.assists.esc_on = not vehicle.assists.esc_on
		assist_changed.emit("ESC", vehicle.assists.esc_on)
	if Input.is_action_just_pressed("toggle_countersteer"):
		vehicle.assists.countersteer_on = not vehicle.assists.countersteer_on
		assist_changed.emit("Countersteer", vehicle.assists.countersteer_on)
	if Input.is_action_just_pressed("toggle_gearbox"):
		manual_gearbox = not manual_gearbox
		vehicle.set_auto_gearbox(not manual_gearbox)
		assist_changed.emit("Manual gearbox", manual_gearbox)
