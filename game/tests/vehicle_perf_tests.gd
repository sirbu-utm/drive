extends "res://tests/vehicle_test_base.gd"
## Phase 2 performance numbers: acceleration, top speed, braking.

func test_accel_0_100_0_200() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0))
	await settle(1.0)
	# launch control: hold the brake with full throttle for a second (engine pre-revs), then release
	for i in 240:
		car.drive(1.0, 1.0, 0.0)
		await tree.physics_frame
	var t := 0.0
	var t100 := -1.0
	var t200 := -1.0
	var d100 := 0.0
	var max_yaw := 0.0
	var max_slip := 0.0
	var start := car.global_position
	var n := 0
	while t < 20.0 and t200 < 0.0:
		car.drive(1.0, 0.0, 0.0)
		await tree.physics_frame
		wrap_z()
		n += 1
		t = n / 240.0
		var kmh := car.fwd_speed * 3.6
		if t100 < 0.0 and kmh >= 100.0:
			t100 = t
		if t200 < 0.0 and kmh >= 200.0:
			t200 = t
		max_yaw = maxf(max_yaw, absf(car.yaw_rate))
		max_slip = maxf(max_slip, maxf(absf(car.wheels[2].kappa), absf(car.wheels[3].kappa)))
	metric("t_0_100_s", t100)
	metric("t_0_200_s", t200)
	metric("max_yaw_rate", max_yaw)
	metric("max_rear_slip_ratio", max_slip)
	check(t100 > 3.0 and t100 < 3.6, "0-100 km/h in 3.0..3.6 s (got %.2f)" % t100)
	check(t200 > 9.0 and t200 < 12.0, "0-200 km/h in 9..12 s (got %.2f)" % t200)
	check(max_yaw < 0.08, "straight line launch: yaw rate stays small (%f)" % max_yaw)
	cleanup()

func test_top_speed() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 60.0)
	var t := 0.0
	var hist: Array[float] = []
	var vmax := 0.0
	var max_yaw := 0.0
	var max_lat := 0.0
	var ymin := 1e9
	var ymax := -1e9
	var steady_t := -1.0
	var n := 0
	while t < 120.0:
		car.drive(1.0, 0.0, 0.0)
		await tree.physics_frame
		wrap_z()
		n += 1
		t = n / 240.0
		vmax = maxf(vmax, car.fwd_speed)
		if n % 240 == 0:
			hist.append(car.fwd_speed)
			if hist.size() > 6 and absf(hist[-1] - hist[-6]) < 0.12 and steady_t < 0.0 and car.fwd_speed > 80.0:
				steady_t = t
		if steady_t > 0.0 and t > steady_t:
			max_yaw = maxf(max_yaw, absf(car.yaw_rate))
			max_lat = maxf(max_lat, absf(car.lat_speed))
			ymin = minf(ymin, car.global_position.y)
			ymax = maxf(ymax, car.global_position.y)
			if t > steady_t + 6.0:
				break
	var top_kmh := car.fwd_speed * 3.6
	metric("top_speed_kmh", top_kmh)
	metric("time_to_steady_s", steady_t)
	metric("steady_max_yaw_rate", max_yaw)
	metric("steady_max_lat_speed", max_lat)
	metric("steady_y_range_mm", (ymax - ymin) * 1000.0)
	metric("final_gear", car.drivetrain.gear)
	metric("final_rpm", car.drivetrain.rpm)
	check(steady_t > 0.0, "reaches a steady top speed")
	check(top_kmh > 310.0 and top_kmh < 330.0, "top speed 310..330 km/h (got %.1f)" % top_kmh)
	check(max_yaw < 0.01, "no yaw wobble at top speed (%f rad/s)" % max_yaw)
	check(max_lat < 0.1, "no lateral drift at top speed (%f m/s)" % max_lat)
	check(ymax - ymin < 0.004, "no pumping at top speed (%f m)" % (ymax - ymin))
	cleanup()

func test_braking_100_0() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 100.0 / 3.6)
	for i in 24:
		car.drive(0, 0, 0)
		await tree.physics_frame
	var start := car.global_position
	var v0 := car.fwd_speed * 3.6
	var yaw0 := yaw_of(car)
	var t := 0.0
	var max_dev := 0.0
	var max_yaw := 0.0
	var abs_seen := false
	var n := 0
	while car.fwd_speed > 0.05 and t < 8.0:
		car.drive(0, 1.0, 0.0)
		await tree.physics_frame
		n += 1
		t = n / 240.0
		max_dev = maxf(max_dev, absf(car.global_position.x - start.x))
		max_yaw = maxf(max_yaw, absf(car.yaw_rate))
		abs_seen = abs_seen or car.assists.abs_active
	var dist := start.distance_to(car.global_position)
	metric("start_kmh", v0)
	metric("brake_distance_m", dist)
	metric("brake_time_s", t)
	metric("lateral_deviation_m", max_dev)
	metric("max_yaw_rate", max_yaw)
	metric("abs_active", abs_seen)
	check(v0 > 99.0 and v0 < 101.0, "started at 100 km/h (%.1f)" % v0)
	check(dist > 30.0 and dist < 35.0, "100-0 km/h in 30..35 m (got %.2f)" % dist)
	check(max_dev < 0.5, "keeps a straight line while braking (lateral %.3f m)" % max_dev)
	check(max_yaw < 0.05, "no yaw under braking (%f)" % max_yaw)
	cleanup()
