class_name Drivetrain
extends RefCounted
## Engine (torque curve, flywheel inertia, rev limiter, engine braking), friction clutch with auto-clutch/launch,
## 6 speed sequential gearbox (auto or manual, ~70 ms shifts with torque cut and rev-match), limited slip diff.
## The clutch + both rear wheels are solved together with an implicit step so that lock-up is exact and stiff
## tyre/wheel coupling stays stable at 240 Hz.

var p: VehicleParams
var omega_e := 0.0              # engine angular speed, rad/s
var gear := 1                   # -1 = reverse, 0 = neutral, 1..6
var auto := true
var clutch_locked := false
var clutch_torque := 0.0        # torque through the clutch (Nm, engine -> driveline)
var engage_cmd := 0.0           # commanded clutch engagement 0..1 after auto-clutch
var engine_torque := 0.0        # net engine torque of the last step
var wheel_torque := 0.0         # total torque delivered to the rear wheels (after ratio)
var limiter := false
var launching := false
var launch_ready := false
var brake_pedal := 0.0
var throttle := 0.0             # throttle after assists (0..1)
var throttle_pedal := 0.0

# shifting
var shifting := false
var _shift_t := 0.0
var _shift_target := 1
var _shift_cool := 0.0
var _diff_in := 0.0

var rpm: float:
	get: return omega_e * 30.0 / PI


func _init(params: VehicleParams) -> void:
	p = params
	omega_e = p.idle_rpm * PI / 30.0


func ratio() -> float:
	return 0.0 if shifting and _shift_t < p.shift_time * 0.45 else p.total_ratio(gear)


func request_shift(dir: int) -> bool:
	if shifting or _shift_cool > 0.0:
		return false
	var target := gear + dir
	if gear == 0:
		target = 1 if dir > 0 else -1
	if target > p.gear_ratios.size() or target < -1:
		return false
	if gear == -1 and dir > 0:
		target = 1
	# do not over-rev on downshifts
	if dir < 0 and target >= 1 and gear >= 1:
		var pred := rpm * p.total_ratio(target) / p.total_ratio(gear)
		if pred > p.rev_limit_rpm + 200.0:
			return false
	_begin_shift(target)
	return true


func _begin_shift(target: int) -> void:
	shifting = true
	_shift_t = 0.0
	_shift_target = target


## Automatic gear selection (call every step).
func auto_shift(dt: float, pedal: float, speed: float, brake: float) -> void:
	_shift_cool = maxf(_shift_cool - dt, 0.0)
	if not auto or shifting or gear <= 0 or _shift_cool > 0.0:
		return
	var up_rpm := lerpf(4200.0, p.upshift_rpm, clampf(pedal * 1.3, 0.0, 1.0))
	var cur_r := p.total_ratio(gear)
	if gear < p.gear_ratios.size() and rpm > up_rpm:
		_begin_shift(gear + 1)
		_shift_cool = 0.35
		return
	if gear > 1:
		var pred := rpm * p.total_ratio(gear - 1) / cur_r
		var down_rpm := lerpf(p.downshift_rpm * 0.6, p.downshift_rpm, clampf(pedal + brake * 0.8, 0.0, 1.0))
		if rpm < down_rpm and pred < p.upshift_rpm - 400.0:
			_begin_shift(gear - 1)
			_shift_cool = 0.35


func engine_torque_at(throttle_eff: float, w_e: float) -> float:
	var r := w_e * 30.0 / PI
	var wot := p.torque_at(r)
	var brake_t := p.engine_brake_a + p.engine_brake_b * r
	var t := wot * throttle_eff - brake_t * (1.0 - throttle_eff)
	if t > 0.0:
		t *= clampf((p.rev_limit_rpm - r) / p.rev_limit_soft, 0.0, 1.0)
		limiter = r > p.rev_limit_rpm - p.rev_limit_soft
	else:
		limiter = false
	# idle governor
	if r < p.idle_rpm:
		t += clampf((p.idle_rpm - r) * 0.35, 0.0, 180.0)
	return t


## Clutch engagement requested by the "auto clutch".
func auto_clutch(pedal: float, speed: float) -> float:
	if gear == 0:
		return 0.0
	if speed >= 6.0:
		return 1.0
	if pedal < 0.05:
		return 0.0 if speed < 3.5 else 1.0
	var r0 := 2400.0 + 600.0 * pedal
	return smoothstep(r0, r0 + 600.0, rpm)


## One step of engine + clutch + rear axle. rw: [left, right] rear wheels (VehicleWheel).
## Writes the new omega of both rear wheels (before brakes) into `out_omega` (Array of 2 floats).
func step(dt: float, rw: Array, speed: float, tcs_scale: float, traction_torque: float, out_omega: Array) -> void:
	var g := ratio()
	var shift_cut := 1.0
	var capacity_scale := 1.0
	var A := p.shift_time * 0.45
	if shifting:
		_shift_t += dt
		if _shift_t >= p.shift_time:
			shifting = false
			gear = _shift_target
			g = p.total_ratio(gear)
		elif _shift_t >= A:
			if gear != _shift_target:
				gear = _shift_target
			g = p.total_ratio(gear)
			var u := (_shift_t - A) / (p.shift_time - A)
			shift_cut = u * u
			capacity_scale = u
		else:
			g = 0.0
			shift_cut = 0.0
			capacity_scale = 0.0
	var eng_cmd := auto_clutch(throttle_pedal, speed)
	# launch control: brake + full throttle at standstill pre-revs the engine with the clutch open
	launch_ready = brake_pedal > 0.3 and throttle_pedal > 0.85 and speed < 0.7 and gear == 1
	if launch_ready:
		eng_cmd = 0.0
	engage_cmd = eng_cmd
	var thr := throttle * (1.0 if not shifting else shift_cut)
	# launch (clutch slipping, low speed): throttle modulated so the engine holds the launch rpm
	launching = g != 0.0 and not clutch_locked and speed < 30.0 and throttle_pedal > 0.05 and (gear == 1 or gear == -1) and omega_e > absf(g) * 0.5 * (absf(rw[0].omega) + absf(rw[1].omega))
	if launching:
		var cap_t := traction_torque / (absf(g) * p.driveline_efficiency)
		var r_t := p.launch_rpm
		var wot := maxf(p.torque_at(rpm), 50.0)
		thr = minf(thr, clampf((cap_t * 1.05 + 25.0 + 0.30 * (r_t - rpm)) / wot, 0.0, 1.0))
	if launch_ready:
		var wot0 := maxf(p.torque_at(rpm), 50.0)
		thr = clampf((p.launch_rpm - rpm) / 400.0 + 0.25, 0.0, 1.0) if rpm < p.launch_rpm + 300.0 else 0.0
	var t_eng := engine_torque_at(thr, omega_e)
	if shifting and shift_cut < 1.0 and t_eng > 0.0:
		t_eng = 0.0 if shift_cut < 0.001 else t_eng
	t_eng *= tcs_scale if t_eng > 0.0 else 1.0
	engine_torque = t_eng

	var R := p.wheel_radius
	var wl: VehicleWheel = rw[0]
	var wr: VehicleWheel = rw[1]
	var a_l := dt / (wl.inertia + dt * wl.torque_k)
	var a_r := dt / (wr.inertia + dt * wr.torque_k)
	var t0_l := wl.torque_tire - rolling_torque(wl)
	var t0_r := wr.torque_tire - rolling_torque(wr)
	# limited slip differential: lock torque moves torque from the faster to the slower wheel
	var lock := p.diff_preload + (p.diff_power_lock if _diff_in >= 0.0 else p.diff_coast_lock) * absf(_diff_in)
	# implicit viscous coupling (stable at 240 Hz), torque limited by the lock capacity; uses last step's input torque
	var kd := p.diff_stiffness
	var dw_new := ((wl.omega - wr.omega) + a_l * (t0_l + 0.5 * _diff_in) - a_r * (t0_r + 0.5 * _diff_in)) / (1.0 + kd * (a_l + a_r))
	var dT := clampf(kd * dw_new, -lock, lock)

	var cap := p.clutch_capacity * clampf(engage_cmd, 0.0, 1.0) * capacity_scale
	if launching:
		# once the engine is revved, the clutch is fully available; it never pulls the engine down faster than the
		# engine can deliver, and never transmits more than the tyres can carry
		if throttle_pedal > 0.4 and rpm > 2700.0 and not launch_ready:
			cap = p.clutch_capacity * capacity_scale
		cap = minf(cap, traction_torque / (absf(g) * eta0()) * 1.05)
		cap = minf(cap, p.torque_at(rpm) * 0.97)
	cap *= clampf(tcs_scale * 1.15, 0.15, 1.0) if (g != 0.0 and absf(g) > 6.0) else 1.0
	var eta := p.driveline_efficiency
	var tc := 0.0
	clutch_locked = false
	if g != 0.0 and cap > 1e-3:
		var rhs := omega_e + dt * t_eng / p.engine_inertia \
			- 0.5 * g * (wl.omega + wr.omega + a_l * (t0_l - dT) + a_r * (t0_r + dT))
		var den := dt / p.engine_inertia + g * g * eta * (a_l + a_r) * 0.25
		var tc_lock := rhs / den
		if absf(tc_lock) <= cap:
			tc = tc_lock
			clutch_locked = true
		else:
			tc = cap * signf(tc_lock)
	clutch_torque = tc
	var tw := g * eta * tc          # total torque on the rear axle
	wheel_torque = tw
	_diff_in = tw
	var tl := 0.5 * tw - dT
	var tr := 0.5 * tw + dT
	out_omega[0] = wl.omega + a_l * (t0_l + tl)
	out_omega[1] = wr.omega + a_r * (t0_r + tr)
	if clutch_locked:
		omega_e = g * 0.5 * (float(out_omega[0]) + float(out_omega[1]))
	else:
		omega_e = maxf(omega_e + dt * (t_eng - tc) / p.engine_inertia, 20.0)
	# rev-match during the engagement phase of a shift (ECU blip / flat shift)
	if shifting and g != 0.0 and _shift_t >= A:
		var w_sync: float = g * 0.5 * (float(out_omega[0]) + float(out_omega[1]))
		if w_sync > 0.0:
			omega_e += (w_sync - omega_e) * minf(dt / 0.012, 1.0)


func rolling_torque(w: VehicleWheel) -> float:
	if not w.in_contact:
		return 0.0
	var crr: float = (p.rolling_resistance + p.rolling_resistance_speed * absf(w.vx)) * w.surface["crr"]
	return crr * w.fz * p.wheel_radius * clampf(w.omega * p.wheel_radius / 0.6, -1.0, 1.0)


func eta0() -> float:
	return p.driveline_efficiency


## Pick a sensible gear + engine speed for a given road speed (used when the car is placed in motion).
func sync_to_speed(speed_ms: float) -> void:
	shifting = false
	_shift_cool = 0.0
	if speed_ms < 1.0:
		gear = 1 if gear != -1 else -1
		omega_e = maxf(omega_e, p.idle_rpm * PI / 30.0)
		return
	var w := speed_ms / p.wheel_radius
	var g := 1
	for i in range(1, p.gear_ratios.size() + 1):
		g = i
		if w * p.total_ratio(i) * 30.0 / PI < 7200.0:
			break
	gear = g
	omega_e = maxf(w * p.total_ratio(g), p.idle_rpm * PI / 30.0)
