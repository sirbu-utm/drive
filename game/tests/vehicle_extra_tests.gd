extends "res://tests/vehicle_test_base.gd"
## Phase 2 extras: surfaces, ABS, reverse, shifting, slalom, bumps.

func _brake_run(v0_kmh: float, surface: String, abs_on: bool) -> Dictionary:
	make_world()
	if surface != "asphalt":
		TestWorld.add_surface_patch(world, Vector2(0, -150), Vector2(40, 400), surface, Color(0.3, 0.4, 0.2), false)
	spawn(Vector3(0, 0.02, 0), 0.0, v0_kmh / 3.6)
	car.assists.abs_on = abs_on
	for i in 24:
		car.drive(0, 0, 0)
		await tree.physics_frame
	var start := car.global_position
	var t := 0.0
	var n := 0
	var kmax := 0.0
	var lock_t := 0.0
	var max_dev := 0.0
	while car.fwd_speed > 0.2 and t < 12.0:
		car.drive(0, 1.0, 0.0)
		await tree.physics_frame
		n += 1
		t = n / 240.0
		max_dev = maxf(max_dev, absf(car.global_position.x))
		if t > 0.3 and car.fwd_speed > 6.0:
			for w in car.wheels:
				if w.omega < 1.0:
					lock_t += 1.0 / 240.0 / 4.0
				kmax = maxf(kmax, -w.kappa)
	var res := {"dist": start.distance_to(car.global_position), "kmax": kmax, "lock_s": lock_t, "dev": max_dev, "abs": car.assists.abs_active}
	cleanup()
	return res

func test_braking_surfaces_and_abs() -> void:
	var dry := await _brake_run(100.0, "asphalt", true)
	var wet := await _brake_run(100.0, "wet", true)
	var grass := await _brake_run(80.0, "grass", true)
	var dry80 := await _brake_run(80.0, "asphalt", true)
	var no_abs := await _brake_run(100.0, "wet", false)
	metric("dry_100_0_m", dry["dist"])
	metric("wet_100_0_m", wet["dist"])
	metric("grass_80_0_m", grass["dist"])
	metric("dry_80_0_m", dry80["dist"])
	metric("wet_abs_max_slip", wet["kmax"])
	metric("wet_no_abs_max_slip", no_abs["kmax"])
	metric("wet_no_abs_dist_m", no_abs["dist"])
	check(wet["dist"] > dry["dist"] * 1.15, "wet surface lengthens braking (%.1f vs %.1f m)" % [wet["dist"], dry["dist"]])
	check(grass["dist"] > dry80["dist"] * 1.3, "grass much longer than asphalt (%.1f vs %.1f m)" % [grass["dist"], dry80["dist"]])
	check(wet["kmax"] < 0.45, "ABS keeps the wheels from locking on wet (max slip %.2f)" % wet["kmax"])
	check(wet["dev"] < 0.6, "stays straight on wet with ABS (%.2f m)" % wet["dev"])
	check(no_abs["lock_s"] > 0.2 and no_abs["kmax"] > 0.8, "without ABS the wheels lock (slip %.2f)" % no_abs["kmax"])
	check(no_abs["dist"] > wet["dist"] * 1.03, "ABS is shorter than locked wheels (%.1f vs %.1f m)" % [wet["dist"], no_abs["dist"]])

func test_reverse_gear() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0))
	await settle(1.0)
	car.set_reverse(true)
	check_eq(car.drivetrain.gear, -1, "reverse engaged at standstill")
	for i in 240 * 4:
		car.drive(0.6, 0.0, 0.0)
		await tree.physics_frame
	var v_rev := car.fwd_speed
	metric("reverse_speed_ms", v_rev)
	check(v_rev < -5.0, "car reverses (%.1f m/s)" % v_rev)
	for i in 240 * 4:
		car.drive(0.0, 1.0, 0.0)
		await tree.physics_frame
	check(absf(car.fwd_speed) < 0.3, "and stops again (%.2f)" % car.fwd_speed)
	car.set_reverse(false)
	check_eq(car.drivetrain.gear, 1, "back to first gear")
	cleanup()

func test_shift_timing() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 20.0)
	var d := car.drivetrain
	var shifts := 0
	var durations: Array[float] = []
	var cur := 0.0
	var was := false
	var min_g := 99.0
	var max_g := 0.0
	var cut_seen := false
	for i in 240 * 8:
		car.drive(1.0, 0.0, 0.0)
		await tree.physics_frame
		wrap_z()
		if d.shifting:
			cur += 1.0 / 240.0
			cut_seen = cut_seen or d.engine_torque < 1.0
		elif was:
			durations.append(cur)
			shifts += 1
			cur = 0.0
		was = d.shifting
	var avg := 0.0
	for x in durations:
		avg += x
	avg /= maxf(durations.size(), 1)
	metric("shifts", shifts)
	metric("avg_shift_s", avg)
	check(shifts >= 2, "several automatic up-shifts happened (%d)" % shifts)
	check(avg > 0.05 and avg < 0.09, "shift time 60-80 ms (got %.0f ms)" % (avg * 1000.0))
	check(cut_seen, "torque is cut during the shift")
	cleanup()

func test_manual_gearbox() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 25.0)
	car.set_auto_gearbox(false)
	var g0 := car.drivetrain.gear
	car.shift_up()
	for i in 60:
		car.drive(0.7, 0.0, 0.0)
		await tree.physics_frame
	check_eq(car.drivetrain.gear, g0 + 1, "shift_up moves one gear up")
	car.shift_down()
	for i in 60:
		car.drive(0.7, 0.0, 0.0)
		await tree.physics_frame
	check_eq(car.drivetrain.gear, g0, "shift_down moves one gear down")
	for i in 240 * 2:
		car.drive(1.0, 0.0, 0.0)
		await tree.physics_frame
		wrap_z()
	check_eq(car.drivetrain.gear, g0, "manual mode does not shift by itself")
	check(car.drivetrain.rpm <= car.params.rev_limit_rpm + 100.0, "rev limiter holds (%.0f rpm)" % car.drivetrain.rpm)
	cleanup()

func test_slalom_80() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 80.0 / 3.6)
	car.assists.esc_on = true
	var max_beta := 0.0
	var max_g := 0.0
	var t := 0.0
	var n := 0
	var pitch := 25.0
	while -car.global_position.z < 320.0 and t < 25.0:
		var s := -car.global_position.z
		var tz := s + 13.0
		var off := 3.0 * sin(TAU * tz / (2.0 * pitch))
		var sp := speed_control(car, 80.0 / 3.6, 0.4)
		car.drive(sp.x, sp.y, pursuit(car, Vector3(-off, 0, -tz)))
		await tree.physics_frame
		n += 1
		t = n / 240.0
		max_beta = maxf(max_beta, atan2(absf(car.lat_speed), maxf(car.fwd_speed, 1.0)))
		max_g = maxf(max_g, absf(car.g_lat))
	metric("max_slip_deg", rad_to_deg(max_beta))
	metric("max_lat_g", max_g)
	metric("time_s", t)
	check(-car.global_position.z >= 320.0, "slalom completed")
	check(rad_to_deg(max_beta) < 10.0, "no spin in the slalom (slip %.1f deg)" % rad_to_deg(max_beta))
	check(max_g > 0.5, "the slalom actually loads the car (%.2f g)" % max_g)
	cleanup()

func test_speed_bump_and_curb() -> void:
	make_world()
	TestWorld.add_box(world, Vector3(12.0, 0.06, 0.8), Vector3(0, 0.0, -60.0), Vector3.ZERO, "asphalt", Color.YELLOW, false)
	TestWorld.add_box(world, Vector3(1.0, 0.07, 3.0), Vector3(-0.9, 0.035, -110.0), Vector3.ZERO, "curb", Color.WHITE, false)
	spawn(Vector3(0, 0.02, 0), 0.0, 50.0 / 3.6)
	var max_w := 0.0
	var air := 0.0
	var max_az := 0.0
	var prev_vy := 0.0
	for i in 240 * 7:
		car.drive(0.15, 0.0, 0.0)
		await tree.physics_frame
		max_w = maxf(max_w, car.angular_velocity.length())
		if car.airborne:
			air += 1.0 / 240.0
		max_az = maxf(max_az, absf(car.linear_velocity.y - prev_vy) * 240.0 / 9.81)
		prev_vy = car.linear_velocity.y
	metric("max_angular_vel", max_w)
	metric("airborne_s", air)
	metric("max_vertical_accel_g", max_az)
	check(max_w < 3.0, "bumps do not throw the car around (%.2f rad/s)" % max_w)
	check(air < 0.25, "no big air over a 6 cm bump (%.2f s)" % air)
	check(max_az < 8.0, "bounded vertical acceleration (%.1f g)" % max_az)
	cleanup()
