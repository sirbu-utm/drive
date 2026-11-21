extends "res://tests/vehicle_test_base.gd"
## Phase 2 basics: static behaviour, tyre curve sanity, ride height, handbrake on a slope.

func test_tire_curve_shape() -> void:
	var p := VehicleParams.new()
	var tm := TireModel.new(p)
	var fz := p.nominal_load
	# pure lateral: peak force coefficient and peak slip angle
	var best := 0.0
	var best_a := 0.0
	for i in range(1, 400):
		var a := float(i) * 0.0005
		var f := tm.combined(0.0, a, fz, 1.0)
		if f.y > best:
			best = f.y
			best_a = a
	metric("lat_mu_peak", best / fz)
	metric("lat_peak_slip_deg", rad_to_deg(best_a))
	check(best / fz > 1.2 and best / fz < 1.6, "peak lateral mu at nominal load in 1.2..1.6")
	check(rad_to_deg(best_a) > 5.0 and rad_to_deg(best_a) < 10.0, "peak slip angle 5..10 deg")
	# load sensitivity: mu at double load is lower
	var f2 := tm.combined(0.0, best_a, 2.0 * fz, 1.0)
	check(f2.y / (2.0 * fz) < best / fz, "mu falls with load")
	# combined slip: lateral force shrinks when a lot of longitudinal slip is added
	var fc := tm.combined(0.12, best_a, fz, 1.0)
	check(fc.y < 0.85 * best, "friction ellipse: Fy reduced under braking/traction slip")
	# long: peak position
	var bx := 0.0
	var bk := 0.0
	for i in range(1, 400):
		var k := float(i) * 0.001
		var f := tm.combined(k, 0.0, fz, 1.0)
		if f.x > bx:
			bx = f.x
			bk = k
	metric("long_mu_peak", bx / fz)
	metric("long_peak_slip", bk)
	check(bk > 0.06 and bk < 0.16, "peak slip ratio 0.06..0.16")

func test_static_ride_height_and_loads() -> void:
	make_world()
	spawn(Vector3(0, 0.03, 0))
	await settle(2.0)
	var total := 0.0
	var front := 0.0
	for i in 4:
		var w := car.wheels[i]
		check(absf(w.comp) < 0.003, "wheel %d static compression ~0 (%f)" % [i, w.comp])
		total += w.fz
		if i < 2:
			front += w.fz
	check_near(total, car.params.mass * 9.81, 60.0, "sum of wheel loads equals weight")
	check_near(front / total, car.params.front_weight_fraction, 0.01, "front weight share")
	check(absf(car.global_position.y) < 0.004, "chassis origin sits on the ground at static ride height")
	metric("front_weight_pct", front / total * 100.0)
	cleanup()

func test_standing_flat_10s() -> void:
	make_world()
	spawn(Vector3(0, 0.03, 0))
	await settle(2.0)
	var p0 := car.global_position
	var max_ang := 0.0
	var ymin := 1e9
	var ymax := -1e9
	for i in 2400:
		car.drive(0, 0, 0, 0)
		await tree.physics_frame
		max_ang = maxf(max_ang, car.angular_velocity.length())
		ymin = minf(ymin, car.global_position.y)
		ymax = maxf(ymax, car.global_position.y)
	var drift := (car.global_position - p0).length()
	metric("drift_m", drift)
	metric("max_angular_vel", max_ang)
	metric("y_range_mm", (ymax - ymin) * 1000.0)
	check(drift < 0.02, "standing 10 s on flat ground: drift %.4f m < 2 cm" % drift)
	check(max_ang < 0.01, "no jitter: angular velocity < 0.01 rad/s (%f)" % max_ang)
	check(ymax - ymin < 0.0005, "no vertical jitter (%f m)" % (ymax - ymin))
	cleanup()

func _slope_test(pitch_deg: float, face_up: bool, label: String) -> void:
	# a 15 deg ramp that starts at z = -5 and rises towards -Z; the car sits on it
	make_world()
	TestWorld.add_incline(world, -5.0, 60.0, pitch_deg)
	var a := deg_to_rad(pitch_deg)
	# position on the incline surface 20 m up the ramp
	var d := 20.0
	var pos := Vector3(0.0, sin(a) * d + 0.03 / cos(a), -5.0 - cos(a) * d)
	var basis := Basis(Vector3.RIGHT, a)               # nose-up pitch about +X for travelling towards -Z
	if not face_up:
		basis = Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, -a)
	spawn(pos, 0.0)
	car.reset_to(Transform3D(basis, pos))
	await run_seconds(3.0, func(_t): car.drive(0, 0, 0, 1.0))
	var p0 := car.global_position
	var max_v := 0.0
	for i in 2400:
		car.drive(0, 0, 0, 1.0)
		await tree.physics_frame
		max_v = maxf(max_v, car.linear_velocity.length())
	var drift := (car.global_position - p0).length()
	metric(label + "_drift_m", drift)
	metric(label + "_max_speed", max_v)
	check(drift < 0.02, "%s: standing 10 s on a %.0f deg slope with handbrake drifts %.4f m (< 2 cm)" % [label, pitch_deg, drift])
	cleanup()

func test_standing_slope_15deg_nose_up() -> void:
	await _slope_test(15.0, true, "slope_up")

func test_standing_slope_15deg_nose_down() -> void:
	await _slope_test(15.0, false, "slope_down")
