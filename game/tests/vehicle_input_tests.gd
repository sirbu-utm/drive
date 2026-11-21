extends "res://tests/vehicle_test_base.gd"
## Input filter, steering limiter, surface provider.

class FakeTerrain:
	extends RefCounted
	func surface_at(p: Vector3) -> String:
		return "grass" if p.x > 0.0 else "rock"

func test_steering_limiter_and_ratio() -> void:
	var p := VehicleParams.new()
	var f := InputFilter.new(p)
	f.steer = 1.0
	var lock := deg_to_rad(p.max_steer_angle_deg)
	check_near(absf(f.steer_angle(0.0)), lock, 0.001, "full lock at standstill (32 deg)")
	var a50 := absf(f.steer_angle(50.0 / 3.6))
	var a100 := absf(f.steer_angle(100.0 / 3.6))
	var a250 := absf(f.steer_angle(250.0 / 3.6))
	metric("limit_50_kmh_deg", rad_to_deg(a50))
	metric("limit_100_kmh_deg", rad_to_deg(a100))
	metric("limit_250_kmh_deg", rad_to_deg(a250))
	check(a50 > a100 and a100 > a250, "steering angle shrinks with speed")
	check(rad_to_deg(a100) > 8.0 and rad_to_deg(a100) < 16.0, "enough angle at 100 km/h to reach the limit (%.1f deg)" % rad_to_deg(a100))
	f.analog_steer = true
	check(absf(f.steer_angle(100.0 / 3.6)) > a100, "gamepad gets a gentler limiter")

func test_keyboard_ramp_and_deadzone() -> void:
	var p := VehicleParams.new()
	var f := InputFilter.new(p)
	for i in 6:
		f.update(1.0 / 60.0, 0.0, 0.0, 1.0, true, 0.0)
	check(f.steer > 0.2 and f.steer < 0.5, "keyboard steering ramps up, not instant (%.2f after 0.1 s)" % f.steer)
	for i in 60:
		f.update(1.0 / 60.0, 0.0, 0.0, 1.0, true, 0.0)
	check_near(f.steer, 1.0, 0.001, "and reaches full deflection")
	for i in 120:
		f.update(1.0 / 60.0, 0.0, 0.0, 0.0, true, 0.0)
	check(absf(f.steer) < 0.01, "and returns to centre")
	f.steer = 0.0
	f.update(1.0 / 60.0, 0.0, 0.0, 0.05, false, 0.0)
	for i in 30:
		f.update(1.0 / 60.0, 0.0, 0.0, 0.05, false, 0.0)
	check(absf(f.steer) < 0.001, "gamepad dead zone swallows 5 % stick")
	for i in 60:
		f.update(1.0 / 60.0, 0.0, 0.0, 0.5, false, 0.0)
	var expected := pow((0.5 - f.deadzone) / (1.0 - f.deadzone), f.linearity)
	check_near(f.steer, expected, 0.02, "gamepad response curve")

func test_reverse_pedal_logic() -> void:
	var p := VehicleParams.new()
	var f := InputFilter.new(p)
	# holding the brake key at standstill for a while selects reverse and swaps pedals
	for i in 60:
		f.update(1.0 / 60.0, 0.0, 1.0, 0.0, true, 0.0)
	check(f.reverse, "brake held at standstill -> reverse")
	for i in 30:
		f.update(1.0 / 60.0, 0.0, 1.0, 0.0, true, 0.0)
	check(f.throttle > 0.9 and f.brake < 0.1, "S drives backwards")
	for i in 60:
		f.update(1.0 / 60.0, 1.0, 0.0, 0.0, true, 0.0)
	check(not f.reverse, "throttle key held at standstill -> forward again")

func test_surface_provider_position_dependent() -> void:
	make_world()
	var prov := FakeTerrain.new()
	world.get_child(0).set_meta("surface_provider", prov)        # the ground body
	spawn(Vector3(0, 0.02, 0))
	car.reset_to(Transform3D(Basis(), Vector3(0.0, 0.02, 0)))
	await run_seconds(1.0, func(_t): car.drive(0, 0, 0))
	# the car straddles x = 0: left wheels on rock, right wheels on grass
	check_eq(car.wheels[0].surface_key, "rock", "front left on rock")
	check_eq(car.wheels[1].surface_key, "grass", "front right on grass")
	check_eq(car.wheels[2].surface_key, "rock", "rear left on rock")
	check_eq(car.wheels[3].surface_key, "grass", "rear right on grass")
	check(car.wheels[0].is_grounded and car.wheels[1].load > 1000.0, "grounded + load exposed")
	check(car.speed_kmh < 0.5 and car.gear == 1, "read-outs: speed_kmh, gear")
	cleanup()
