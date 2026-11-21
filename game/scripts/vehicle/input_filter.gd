class_name InputFilter
extends RefCounted
## Turns raw driver input (keyboard keys or analogue stick/trigger values) into the signals the vehicle uses:
## smoothed pedals and steering, speed-sensitive steering limit, dead zone + response curve for gamepads.

var p: VehicleParams
## analogue (gamepad) steering uses a gentler speed limiter
var analog_steer := false
var deadzone := 0.08
var linearity := 1.4           # response exponent for gamepad steering (1 = linear)
var key_attack := 3.2          # keyboard steering ramp towards the key (1/s)
var key_release := 5.0         # ramp back to centre
var pedal_attack := 8.0
var pedal_release := 14.0

var steer := 0.0               # normalised -1..1 (+ = right), before the speed limiter
var throttle := 0.0
var brake := 0.0
var reverse := false
var _rev_timer := 0.0


func _init(params: VehicleParams) -> void:
	p = params


## raw_* in 0..1 (pedals) / -1..1 (steer). keyboard = true: keys are binary and get ramped.
func update(dt: float, raw_throttle: float, raw_brake: float, raw_steer: float, keyboard: bool, fwd_speed: float) -> void:
	# pedals (W/S style): reverse logic - brake key held at standstill selects reverse and swaps the pedals
	var thr_in := raw_throttle
	var brk_in := raw_brake
	if reverse:
		thr_in = raw_brake
		brk_in = raw_throttle
		if raw_throttle > 0.5 and fwd_speed > -1.0 and raw_brake < 0.1 and absf(fwd_speed) < 1.0:
			_rev_timer += dt
			if _rev_timer > 0.25:
				reverse = false
				_rev_timer = 0.0
		else:
			_rev_timer = 0.0
	else:
		if raw_brake > 0.5 and raw_throttle < 0.1 and absf(fwd_speed) < 0.8:
			_rev_timer += dt
			if _rev_timer > 0.35:
				reverse = true
				_rev_timer = 0.0
		else:
			_rev_timer = 0.0
	throttle = _approach(throttle, thr_in, pedal_attack if thr_in > throttle else pedal_release, dt)
	brake = _approach(brake, brk_in, pedal_attack if brk_in > brake else pedal_release, dt)
	if keyboard:
		var rate := key_attack if absf(raw_steer) > 0.01 and signf(raw_steer) == signf(steer) or absf(steer) < 0.001 else key_release
		if absf(raw_steer) > 0.01 and signf(raw_steer) != signf(steer) and absf(steer) > 0.001:
			rate = key_release * 1.5
		# slower build-up at speed
		if absf(raw_steer) > 0.01:
			rate /= (1.0 + absf(fwd_speed) / 35.0)
		steer = _approach(steer, raw_steer, rate, dt)
	else:
		var s := absf(raw_steer)
		if s < deadzone:
			steer = _approach(steer, 0.0, 12.0, dt)
		else:
			var n := (s - deadzone) / (1.0 - deadzone)
			steer = _approach(steer, signf(raw_steer) * pow(n, linearity), 14.0, dt)


## steering wheel angle (rad of the front wheels, + = left) after the speed limiter
func steer_angle(fwd_speed: float, extra: float = 0.0) -> float:
	var lock := deg_to_rad(p.max_steer_angle_deg)
	var v := absf(fwd_speed)
	var ref := p.steer_speed_ref * (1.8 if analog_steer else 1.0)
	var lim := lock / (1.0 + pow(v / ref, p.steer_speed_exp))
	return -clampf(steer + extra, -1.0, 1.0) * lim


static func _approach(cur: float, target: float, rate: float, dt: float) -> float:
	var d := target - cur
	var m := rate * dt
	return target if absf(d) <= m else cur + signf(d) * m
