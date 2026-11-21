class_name Assists
extends RefCounted
## ABS, TCS, ESC and the keyboard counter-steer helper. Each can be switched on/off (VehicleParams defaults:
## ABS on, TCS on, ESC off, counter-steer off).

var p: VehicleParams
var abs_on := true
var tcs_on := true
var esc_on := false
var countersteer_on := false

var tcs_scale := 1.0
var tcs_active := false
var abs_active := false
var esc_active := false
var esc_throttle_scale := 1.0
var esc_brake := [0.0, 0.0, 0.0, 0.0]    # extra brake torque per wheel index (FL, FR, RL, RR), Nm
var steer_assist := 0.0                  # normalised steering added by the counter-steer helper

const ABS_TARGET := 0.11
const TCS_TARGET := 0.13


func _init(params: VehicleParams) -> void:
	p = params
	abs_on = p.abs_enabled
	tcs_on = p.tcs_enabled
	esc_on = p.esc_enabled
	countersteer_on = p.countersteer_assist


func update_abs(dt: float, wheels: Array, speed: float) -> void:
	abs_active = false
	for w: VehicleWheel in wheels:
		if not abs_on or w.brake_cmd <= 1.0 or speed < 2.5 or not w.in_contact:
			w.abs_mod = minf(w.abs_mod + 20.0 * dt, 1.0)
			w.abs_active = false
			continue
		var err := -w.kappa - ABS_TARGET           # > 0 : too much slip -> release
		if err > 0.0:
			w.abs_mod = maxf(w.abs_mod - (3.0 + 60.0 * err) * dt, 0.06)
		else:
			w.abs_mod = minf(w.abs_mod + (2.0 + 25.0 * (-err)) * dt, 1.0)
		w.abs_active = w.abs_mod < 0.93
		abs_active = abs_active or w.abs_active


## Traction control: feed-forward torque limit from the tyre traction estimate (so the engine never asks for more
## than the rear tyres can transmit) plus a PI trim on the measured rear slip ratio.
var traction_torque := 1e9       # estimated wheel torque limit of the driven axle (Nm), used by launch control
var _tcs_i := 1.0
var _gain := 1.0
const TCS_MARGIN := 0.95

func update_tcs(dt: float, rear: Array, speed: float, tire: TireModel, dtrain: Drivetrain) -> void:
	var peak := 0.0
	var kmax := 0.0
	for w: VehicleWheel in rear:
		if not w.in_contact:
			continue
		peak += tire.peak_long(w.fz, w.surface["mu"])
		var s := w.omega * w.radius - w.vx
		kmax = maxf(kmax, s / maxf(absf(w.vx), 5.0))
	traction_torque = peak * p.wheel_radius * TCS_MARGIN
	if not tcs_on:
		tcs_scale = 1.0
		tcs_active = false
		_tcs_i = 1.0
		return
	# feed-forward upper bound: fraction of the engine torque the tyres can carry (x1.4 headroom for the engine inertia)
	var g := absf(dtrain.ratio())
	var ff := 1.0
	if g > 0.1 and not dtrain.shifting:
		var t_est := maxf(dtrain.engine_torque_at(dtrain.throttle_pedal, dtrain.omega_e), 30.0)
		ff = clampf(1.7 * traction_torque / (g * p.driveline_efficiency * t_est), 0.0, 1.0)
	# slip feedback (PI): integrates towards the slip target, proportional term reacts instantly
	var e := kmax - TCS_TARGET
	_tcs_i = clampf(_tcs_i - 14.0 * e * dt, 0.15, 1.0)
	var target := clampf(minf(ff, _tcs_i) - 5.0 * maxf(e, 0.0), 0.0, 1.0)
	tcs_scale = target if target < tcs_scale else minf(tcs_scale + 8.0 * dt, target)
	tcs_active = tcs_scale < 0.9 and dtrain.throttle_pedal > 0.3


## yaw_rate: rad/s about the body up axis (+ = left), steer_angle: average front wheel angle (+ = left),
## fwd_speed: m/s along the body, lat_speed: m/s to the right.
func update_esc(dt: float, yaw_rate: float, steer_angle: float, fwd_speed: float, lat_speed: float, wheels: Array) -> void:
	esc_brake = [0.0, 0.0, 0.0, 0.0]
	esc_throttle_scale = 1.0
	esc_active = false
	if not esc_on or absf(fwd_speed) < 8.0:
		return
	var v := absf(fwd_speed)
	var kus := 0.0012
	var target := v * steer_angle / (p.wheelbase + kus * v * v)
	var lim := 1.1 * 9.81 / v
	target = clampf(target, -lim, lim)
	var err := yaw_rate - target
	var beta := atan2(lat_speed, v)
	# oversteer: car rotates more than commanded (or slides): brake the outer front wheel
	var turn_dir := signf(yaw_rate) if absf(yaw_rate) > 0.05 else signf(target)
	var over := err * turn_dir if absf(target) < absf(yaw_rate) or turn_dir != signf(target) else 0.0
	if turn_dir == 0.0:
		return
	var over_amt := maxf(over - 0.10, 0.0) + maxf(absf(beta) - 0.07, 0.0) * 1.5
	if over_amt > 0.0:
		esc_active = true
		var outer_front := 1 if turn_dir > 0.0 else 0       # left turn (yaw > 0): outer = right front (index 1)
		esc_brake[outer_front] = minf(7000.0 * over_amt, 3500.0)
		var inner_rear := 2 if turn_dir > 0.0 else 3
		esc_brake[inner_rear] = minf(3000.0 * over_amt, 1500.0)
		esc_throttle_scale = clampf(1.0 - 3.0 * over_amt, 0.0, 1.0)
	else:
		# understeer: yaw lags the commanded value: brake the inner rear wheel
		var under := (absf(target) - absf(yaw_rate)) if signf(yaw_rate) == signf(target) or absf(yaw_rate) < 0.03 else absf(target)
		if absf(steer_angle) > 0.04 and under > 0.12:
			esc_active = true
			var inner := 2 if target > 0.0 else 3
			esc_brake[inner] = minf(4000.0 * (under - 0.12), 1800.0)
			esc_throttle_scale = clampf(1.0 - 1.2 * (under - 0.12), 0.5, 1.0)


## Keyboard counter-steer helper: returns a normalised steering correction (+ = right).
func compute_countersteer(fwd_speed: float, lat_speed: float, yaw_rate: float) -> float:
	steer_assist = 0.0
	if not countersteer_on or fwd_speed < 7.0:
		return 0.0
	var beta := atan2(lat_speed, fwd_speed)        # + = sliding to the right
	if absf(beta) > 0.05:
		steer_assist = clampf((beta - 0.05 * signf(beta)) * 2.5, -0.6, 0.6)
	return steer_assist
