extends "res://tests/vehicle_test_base.gd"
## Phase 2 handling: skidpad, lane change (ESC on/off), lift-off, drift, jump.

const R := 60.0

## drive the R = 60 m circle with a speed ramp; returns a dictionary of results
func _skidpad(ramp: float, esc: bool = false, v0: float = 14.0, max_t: float = 70.0) -> Dictionary:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, v0)
	car.assists.esc_on = esc
	var centre := Vector3(-R, 0, 0)
	var t := 0.0
	var n := 0
	var avg_g := 0.0
	var peak_g := 0.0
	var v_at_peak := 0.0
	var max_beta := 0.0
	var max_roll := 0.0
	var max_pitch := 0.0
	var out_t := -1.0
	var hist_g: Array[float] = []
	var yaw_max_ratio := 0.0
	while t < max_t:
		var vt := v0 + ramp * t
		var sp := speed_control(car, vt, 0.5)
		var ld := maxf(6.0, 0.35 * car.speed)
		var steer := pursuit(car, circle_target(car, centre, R, ld, true))
		car.drive(sp.x, sp.y, steer)
		await tree.physics_frame
		n += 1
		t = n / 240.0
		var rad_err := (car.global_position - centre).length() - R
		avg_g = lerpf(avg_g, absf(car.g_lat), 1.0 - exp(-1.0 / 240.0 / 0.4))
		if avg_g > peak_g and t > 3.0:
			peak_g = avg_g
			v_at_peak = car.speed
		var beta := atan2(absf(car.lat_speed), maxf(car.fwd_speed, 1.0))
		max_beta = maxf(max_beta, beta)
		max_roll = maxf(max_roll, absf(asin(clampf(car.global_basis.x.y, -1.0, 1.0))))
		max_pitch = maxf(max_pitch, absf(asin(clampf(car.global_basis.z.y, -1.0, 1.0))))
		if car.speed > 8.0:
			yaw_max_ratio = maxf(yaw_max_ratio, absf(car.yaw_rate) / (car.speed / R))
		if absf(rad_err) > 12.0 and out_t < 0.0:
			out_t = t
			break
	var res := {"peak_g": peak_g, "v_at_peak": v_at_peak, "max_beta_deg": rad_to_deg(max_beta), "max_roll_deg": rad_to_deg(max_roll),
		"max_pitch_deg": rad_to_deg(max_pitch), "left_circle_t": out_t, "yaw_ratio": yaw_max_ratio, "t": t,
		"final_beta_deg": rad_to_deg(atan2(absf(car.lat_speed), maxf(car.fwd_speed, 1.0)))}
	cleanup()
	return res

func test_skidpad_r60() -> void:
	var r := await _skidpad(0.45)
	metric("peak_lateral_g", r["peak_g"])
	metric("speed_at_peak_kmh", r["v_at_peak"] * 3.6)
	metric("max_body_slip_deg", r["max_beta_deg"])
	metric("max_roll_deg", r["max_roll_deg"])
	metric("max_pitch_deg", r["max_pitch_deg"])
	metric("yaw_rate_over_nominal_max", r["yaw_ratio"])
	check(r["peak_g"] > 1.1 and r["peak_g"] < 1.4, "R=60 m skidpad: 1.1..1.4 g (got %.3f)" % r["peak_g"])
	check(r["max_beta_deg"] < 22.0, "no sudden break-away: body slip stays < 22 deg (%.1f)" % r["max_beta_deg"])
	check(r["yaw_ratio"] < 1.6, "yaw rate never runs away (x%.2f of nominal)" % r["yaw_ratio"])
	check(r["max_roll_deg"] < 4.0, "body roll < 4 deg (%.2f)" % r["max_roll_deg"])

# ---- lane change at 120 km/h --------------------------------------------------------------------------------

## lateral offset (towards -X = left) of a double lane change as a function of distance travelled along -Z
static func _dlc_offset(s: float, amp: float, len_: float) -> float:
	# out at s in [30, 30+len], hold 20 m, back at [80+len, 80+2 len]
	var a := 30.0
	var b := a + len_
	var c := b + 20.0
	var d := c + len_
	if s < a or s > d:
		return 0.0
	if s < b:
		var u := (s - a) / len_
		return amp * (0.5 - 0.5 * cos(PI * u))
	if s < c:
		return amp
	var u2 := (s - c) / len_
	return amp * (0.5 + 0.5 * cos(PI * u2))

func _lane_change(esc: bool, amp: float, len_: float) -> Dictionary:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 120.0 / 3.6)
	car.assists.esc_on = esc
	var v_target := 120.0 / 3.6
	var max_beta := 0.0
	var max_yaw := 0.0
	var max_err := 0.0
	var max_g := 0.0
	var t := 0.0
	var n := 0
	var total := 30.0 + 2.0 * len_ + 20.0 + 60.0
	var end_err := 0.0
	var end_yaw := 0.0
	var spun := false
	while -car.global_position.z < total and t < 12.0:
		var s := -car.global_position.z
		var ld := 14.0
		var tz := s + ld
		var target := Vector3(-_dlc_offset(tz, amp, len_), 0.0, -tz)
		var sp := speed_control(car, v_target, 0.4)
		car.drive(sp.x, sp.y, pursuit(car, target))
		await tree.physics_frame
		n += 1
		t = n / 240.0
		max_beta = maxf(max_beta, atan2(absf(car.lat_speed), maxf(car.fwd_speed, 1.0)))
		max_yaw = maxf(max_yaw, absf(car.yaw_rate))
		max_g = maxf(max_g, absf(car.g_lat))
		max_err = maxf(max_err, absf(car.global_position.x + _dlc_offset(-car.global_position.z, amp, len_)))
		if absf(yaw_of(car)) > deg_to_rad(60.0):
			spun = true
	end_err = absf(car.global_position.x)
	end_yaw = absf(car.yaw_rate)
	var res := {"max_beta_deg": rad_to_deg(max_beta), "max_yaw": max_yaw, "max_err": max_err, "max_g": max_g, "end_err": end_err,
		"end_yaw": end_yaw, "spun": spun, "done": -car.global_position.z >= total, "esc_active": car.assists.esc_active}
	cleanup()
	return res

func test_lane_change_120_closed_loop() -> void:
	# a driver following a 3.5 m lane change at 120 km/h: easy for the car, ESC stays quiet
	var r := await _lane_change(true, 3.5, 25.0)
	for k in r:
		metric("lc_" + k, r[k])
	check(r["done"], "lane change completed")
	check(not r["spun"], "car does not spin")
	check(r["max_beta_deg"] < 10.0, "body slip < 10 deg (%.1f)" % r["max_beta_deg"])
	check(r["end_err"] < 1.0, "back on the centre line (%.2f m)" % r["end_err"])

## open-loop sine-with-dwell steering at 120 km/h. recover = true: a driver (PD on heading and yaw rate) takes over after the input.
func _sine_dwell(amp_deg: float, esc: bool, recover: bool) -> Dictionary:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 120.0 / 3.6)
	car.assists.esc_on = esc
	var T := 1.0 / 0.7
	var max_beta := 0.0
	var max_yaw := 0.0
	var esc_seen := false
	for i in 240 * 7:
		var t := i / 240.0
		var st := 0.0
		if t < T:
			st = deg_to_rad(amp_deg) * sin(TAU * 0.7 * t)
		elif recover and t > T:
			var psi := yaw_of(car)
			var beta := atan2(car.lat_speed, maxf(car.fwd_speed, 3.0))
			st = clampf(-0.4 * psi - 0.15 * car.yaw_rate - 0.5 * beta, -0.30, 0.30)
		car.drive(0.25, 0.0, st)
		await tree.physics_frame
		wrap_z()
		max_beta = maxf(max_beta, atan2(absf(car.lat_speed), maxf(car.fwd_speed, 1.0)))
		max_yaw = maxf(max_yaw, absf(car.yaw_rate))
		esc_seen = esc_seen or car.assists.esc_active
	var res := {"max_beta_deg": rad_to_deg(max_beta), "max_yaw": max_yaw, "end_heading_deg": rad_to_deg(yaw_of(car)),
		"end_yaw_rate": car.yaw_rate, "end_speed_kmh": car.speed_kmh, "esc_seen": esc_seen}
	cleanup()
	return res

func test_esc_on_sine_dwell_no_spin() -> void:
	var r := await _sine_dwell(9.0, true, false)
	for k in r:
		metric("esc_on_" + k, r[k])
	check(absf(r["end_heading_deg"]) < 8.0, "ESC on: car is straight again, open loop (%.1f deg)" % r["end_heading_deg"])
	check(r["max_beta_deg"] < 9.0, "ESC on: body slip < 9 deg (%.1f)" % r["max_beta_deg"])
	check(r["esc_seen"], "ESC intervened")

func test_esc_off_sine_dwell_oversteer() -> void:
	var r := await _sine_dwell(9.0, false, false)
	for k in r:
		metric("esc_off_open_" + k, r[k])
	check(r["max_beta_deg"] > 9.0, "ESC off: oversteer shows (slip %.1f deg)" % r["max_beta_deg"])
	check(absf(r["end_heading_deg"]) > 25.0, "ESC off, no driver: car rotates away (%.1f deg)" % r["end_heading_deg"])

func test_esc_off_sine_dwell_controllable() -> void:
	var r := await _sine_dwell(9.0, false, true)
	for k in r:
		metric("esc_off_driver_" + k, r[k])
	check(absf(r["end_heading_deg"]) < 8.0, "ESC off: a driver countersteering catches it (%.1f deg)" % r["end_heading_deg"])
	check(absf(r["end_yaw_rate"]) < 0.1, "ESC off: and the yaw rate dies (%.3f)" % r["end_yaw_rate"])
	check(r["max_beta_deg"] < 35.0, "ESC off: slip stays catchable (%.1f deg)" % r["max_beta_deg"])

func test_lift_off_in_corner() -> void:
	# steady skidpad at ~90 % of the limit speed, then the throttle is lifted completely
	make_world()
	var v := 26.0
	spawn(Vector3(0, 0.02, 0), 0.0, v)
	var centre := Vector3(-R, 0, 0)
	var t := 0.0
	var n := 0
	var lift_t := 8.0
	var yaw_before := 0.0
	var yaw_peak_after := 0.0
	var max_beta_after := 0.0
	var rad_err_end := 0.0
	var psi_dot_nom := v / R
	var seen_sample := false
	while t < lift_t + 4.0:
		var sp := speed_control(car, v, 0.5)
		var thr := sp.x
		var brk := sp.y
		if t >= lift_t:
			thr = 0.0
			brk = 0.0
		var ld := maxf(6.0, 0.35 * car.speed)
		car.drive(thr, brk, pursuit(car, circle_target(car, centre, R, ld, true)))
		await tree.physics_frame
		n += 1
		t = n / 240.0
		if t > lift_t - 0.2 and t < lift_t and not seen_sample:
			yaw_before = absf(car.yaw_rate)
			seen_sample = true
		if t >= lift_t:
			yaw_peak_after = maxf(yaw_peak_after, absf(car.yaw_rate))
			max_beta_after = maxf(max_beta_after, atan2(absf(car.lat_speed), maxf(car.fwd_speed, 1.0)))
	rad_err_end = absf((car.global_position - centre).length() - R)
	var ratio := yaw_peak_after / maxf(yaw_before, 0.01)
	metric("steady_yaw_rate", yaw_before)
	metric("yaw_rate_peak_after_lift", yaw_peak_after)
	metric("yaw_gain_ratio", ratio)
	metric("max_body_slip_after_lift_deg", rad_to_deg(max_beta_after))
	metric("radius_error_m", rad_err_end)
	check(ratio > 1.02, "lift-off: car tightens its line, mild oversteer (yaw x%.3f)" % ratio)
	check(ratio < 1.6, "lift-off: no instant spin (yaw x%.3f)" % ratio)
	check(rad_to_deg(max_beta_after) < 15.0, "lift-off: body slip stays small (%.1f deg)" % rad_to_deg(max_beta_after))
	cleanup()

# ---- drift: TCS + ESC off, power oversteer in 2nd gear, sustained with counter-steer, then caught -----------------

func test_drift_sustained_and_caught() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 17.0)
	car.assists.esc_on = false
	car.assists.tcs_on = false
	car.set_auto_gearbox(false)
	car.drivetrain.gear = 2
	var bstar := deg_to_rad(20.0)
	var sustained := 0.0
	var max_beta := 0.0
	var beta_sum := 0.0
	var samples := 0
	var yaw_min := 99.0
	var spun := false
	var n := 0
	var t := 0.0
	var drift_end := 9.0
	while t < drift_end + 4.5:
		var beta := atan2(car.lat_speed, maxf(absf(car.fwd_speed), 3.0))
		var thr := 0.0
		var st := 0.0
		if t < 0.5:
			st = deg_to_rad(-6.0)
			thr = 0.2
		elif t < 1.1:
			st = deg_to_rad(12.0)
			thr = 1.0
		elif t < drift_end:
			st = clampf(-beta - 1.0 * (beta - bstar), -0.5, 0.5)
			thr = clampf(0.8 + 0.12 * (40.0 - car.speed), 0.3, 1.0)
		else:
			st = clampf(-1.0 * beta - 0.35 * car.yaw_rate, -0.5, 0.5)
			thr = 0.15
		car.drive(thr, 0.0, st)
		await tree.physics_frame
		n += 1
		t = n / 240.0
		if t > 2.0 and t < drift_end:
			if absf(rad_to_deg(beta)) > 12.0 and absf(car.yaw_rate) > 0.2:
				sustained += 1.0 / 240.0
			max_beta = maxf(max_beta, absf(beta))
			beta_sum += absf(beta)
			samples += 1
		if t >= drift_end:
			if car.speed < 8.0:
				spun = true
	var end_beta := absf(atan2(car.lat_speed, maxf(absf(car.fwd_speed), 3.0)))
	metric("drift_sustained_s", sustained)
	metric("drift_max_slip_deg", rad_to_deg(max_beta))
	metric("drift_mean_slip_deg", rad_to_deg(beta_sum / maxf(samples, 1)))
	metric("recovered_end_slip_deg", rad_to_deg(end_beta))
	metric("recovered_end_yaw_rate", car.yaw_rate)
	metric("recovered_end_speed_kmh", car.speed_kmh)
	check(sustained > 3.0, "stable drift: |slip| > 12 deg with yaw for > 3 s (%.1f s)" % sustained)
	check(rad_to_deg(max_beta) < 60.0, "drift stays catchable (max slip %.1f deg)" % rad_to_deg(max_beta))
	check(rad_to_deg(end_beta) < 5.0 and absf(car.yaw_rate) < 0.12, "counter-steer + lift catches the car (slip %.1f deg, yaw %.3f)" % [rad_to_deg(end_beta), car.yaw_rate])
	check(not spun, "no spin-out / stop while recovering")
	cleanup()

# ---- jump -------------------------------------------------------------------------------------------------------

func test_jump_from_ramp() -> void:
	make_world()
	TestWorld.add_incline(world, -40.0, 12.0, 9.0)          # 12 m long 9 deg ramp, ends ~1.9 m above the ground
	var v0 := 100.0 / 3.6
	spawn(Vector3(0, 0.02, -2.0), 0.0, v0)
	var t := 0.0
	var n := 0
	var air_t := 0.0
	var max_vy := 0.0
	var max_speed_after := 0.0
	var max_w := 0.0
	var max_roll := 0.0
	var max_pitch := 0.0
	var landed := false
	var max_alt := 0.0
	var max_fz := 0.0
	var nan_seen := false
	var min_comp_hit := 0
	var land_t := -1.0
	var yaw_at_end := 0.0
	while t < 7.0:
		car.drive(0.3 if not car.airborne else 0.0, 0.0, 0.0)
		await tree.physics_frame
		n += 1
		t = n / 240.0
		if is_nan(car.global_position.x) or is_nan(car.linear_velocity.x):
			nan_seen = true
			break
		if car.airborne:
			air_t += 1.0 / 240.0
			max_alt = maxf(max_alt, car.global_position.y)
		if air_t > 0.3 and not car.airborne and land_t < 0.0:
			land_t = t
		if land_t > 0.0:
			max_speed_after = maxf(max_speed_after, car.linear_velocity.length())
			max_vy = maxf(max_vy, absf(car.linear_velocity.y))
			max_w = maxf(max_w, car.angular_velocity.length())
			max_roll = maxf(max_roll, absf(asin(clampf(car.global_basis.x.y, -1.0, 1.0))))
			max_pitch = maxf(max_pitch, absf(asin(clampf(car.global_basis.z.y, -1.0, 1.0))))
			for w in car.wheels:
				max_fz = maxf(max_fz, w.fz)
	yaw_at_end = car.yaw_rate
	metric("air_time_s", air_t)
	metric("max_height_m", max_alt)
	metric("landing_max_speed_ms", max_speed_after)
	metric("landing_max_vertical_ms", max_vy)
	metric("landing_max_angular_vel", max_w)
	metric("landing_max_roll_deg", rad_to_deg(max_roll))
	metric("landing_max_pitch_deg", rad_to_deg(max_pitch))
	metric("landing_max_wheel_load_N", max_fz)
	metric("end_speed_kmh", car.speed_kmh)
	metric("end_yaw_rate", yaw_at_end)
	check(not nan_seen, "no NaN")
	check(air_t > 0.4, "the car actually flies (%.2f s)" % air_t)
	check(max_speed_after < v0 * 1.12, "landing does not add energy (|v| %.1f vs %.1f)" % [max_speed_after, v0])
	check(max_w < 8.0, "no violent spinning on landing (%.1f rad/s)" % max_w)
	check(rad_to_deg(max_roll) < 25.0 and rad_to_deg(max_pitch) < 40.0, "no flip: roll %.1f pitch %.1f deg" % [rad_to_deg(max_roll), rad_to_deg(max_pitch)])
	check(max_fz < 80000.0, "bounded wheel loads on touchdown, no physics explosion (%.0f N)" % max_fz)
	check(absf(yaw_at_end) < 0.1 and car.global_position.y < 0.05, "settled and straight afterwards (yaw %.3f)" % yaw_at_end)
	cleanup()
