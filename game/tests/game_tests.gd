extends "res://tests/vehicle_test_base.gd"
## Phase 2.5: road network helper, respawn on the nearest road, camera rig, HUD objects.

func test_road_net_lane_pose() -> void:
	var net := RoadNet.new()
	var ring := net.get_road("ring")
	check(not ring.is_empty() and ring["closed"], "ring road loaded and closed")
	check(net.roads.size() >= 4, "all roads loaded (%d)" % net.roads.size())
	var k := 1200
	var pose := net.lane_pose(ring, k, 1, 0.5)
	var c: Vector3 = ring["pts"][k]
	# right lane: offset to the right of the travel direction
	var fwd := -pose.basis.z
	var right := fwd.cross(Vector3.UP)
	var d := pose.origin - c
	check(d.dot(right) > 0.25 * float(ring["width"][k]) * 0.9, "lane point is right of the centreline (%.2f m)" % d.dot(right))
	var pose_back := net.lane_pose(ring, k, -1, 0.5)
	check((-pose_back.basis.z).dot(fwd) < -0.9, "reverse direction faces the other way")
	var n := net.nearest(c + right * 3.0 + Vector3(0, 5, 0), fwd)
	check(n["road"]["name"] == "ring" and absi(int(n["i"]) - k) <= 2, "nearest sample found (idx %d vs %d)" % [n["i"], k])
	check_eq(n["dir"], 1, "direction follows the heading")
	var n2 := net.nearest(c, -fwd)
	check_eq(n2["dir"], -1, "opposite heading gives the opposite direction")

func test_respawn_nearest_road() -> void:
	var g := (load("res://scenes/game.tscn") as PackedScene).instantiate() as Game
	tree.root.add_child(g)
	await tree.physics_frame
	await tree.physics_frame
	var car := g.car
	# throw the car far from any road, facing some direction, then press R
	car.reset_to(Transform3D(Basis(Vector3.UP, deg_to_rad(40.0)), Vector3(300.0, 150.0, 300.0)), Vector3(0, 0, -10))
	await tree.physics_frame
	g.respawn()
	await run_seconds(1.0, func(_t): car.drive(0, 0, 0))
	var n := g.net.nearest(car.global_position)
	var dist: float = n["dist"]
	var road: Dictionary = n["road"]
	var half: float = float(road["width"][n["i"]]) * 0.5
	metric("respawn_dist_to_centreline_m", dist)
	check(dist < half, "respawned on the road (%.1f m from the centreline, half width %.1f)" % [dist, half])
	check(car.speed < 3.0, "respawn stops the car (%.1f m/s)" % car.speed)
	check(car.global_basis.y.y > 0.9, "upright after respawn")
	var wheels_on := 0
	for w in car.wheels:
		if w.is_grounded:
			wheels_on += 1
	check_eq(wheels_on, 4, "all four wheels grounded after respawn")
	g.queue_free()
	await tree.physics_frame
	await tree.physics_frame

func test_camera_rig_modes_fov_and_orbit() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 60.0)
	var rig := CameraRig.new()
	rig.vehicle = car
	tree.root.add_child(rig)
	await tree.process_frame
	rig.set_mode(CameraRig.Mode.CHASE_NEAR)
	for i in 200:
		car.drive(0.5, 0, 0)
		await tree.physics_frame
		await tree.process_frame
	var fov_fast := rig.camera.fov
	check(fov_fast > CameraRig.CHASE[CameraRig.Mode.CHASE_NEAR]["fov"] + 8.0, "FOV grows with speed (%.1f)" % fov_fast)
	var behind := rig.camera.global_position - car.global_position
	check(behind.dot(-car.global_basis.z) < -3.0, "chase camera sits behind the car (%.1f m)" % behind.dot(-car.global_basis.z))
	check(behind.y > 0.8, "and above it (%.1f m)" % behind.y)
	# cycle through all five modes
	var names: Array[String] = []
	rig.mode_changed.connect(func(n: String): names.append(n))
	for i in 5:
		rig.next_mode()
		await tree.process_frame
	check_eq(names.size(), 5, "five mode changes")
	check_eq(rig.mode, CameraRig.Mode.CHASE_NEAR, "C cycles back to the start")
	# cockpit: eye inside the car, left of centre
	rig.set_mode(CameraRig.Mode.COCKPIT)
	await tree.process_frame
	await tree.process_frame
	var eye := car.global_transform.affine_inverse() * rig.camera.global_position
	check(absf(eye.x + 0.30) < 0.1 and eye.y > 0.8 and eye.y < 1.1, "cockpit eye is where the driver sits %s" % str(eye))
	# orbit: yaw swings the chase camera around the car
	rig.set_mode(CameraRig.Mode.CHASE_NEAR)
	rig.orbit_yaw = PI * 0.5
	for i in 40:
		await tree.process_frame
	rig.orbit_yaw = PI * 0.5
	await tree.process_frame
	rig.queue_free()
	cleanup()

func test_hud_builds_and_reads_vehicle() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 30.0)
	var hud := HUD.new()
	hud.vehicle = car
	tree.root.add_child(hud)
	for i in 20:
		car.drive(0.8, 0, 0)
		await tree.physics_frame
		await tree.process_frame
	check(hud.dial != null and hud.minimap != null and hud.indicators != null, "dial, minimap and indicators exist")
	check(hud.dial.rpm_shown > 1500.0, "needle follows the engine (%.0f)" % hud.dial.rpm_shown)
	hud.show_toast("тест")
	await tree.process_frame
	hud.queue_free()
	cleanup()

func test_vehicle_with_real_hull_and_meta() -> void:
	make_world()
	car = Vehicle.new()
	car.build_visual = false
	car.meta_path = "res://assets/cars/ccgt/ccgt_meta.json"
	car.hull_path = "res://assets/cars/ccgt/ccgt_hull.res"
	car.contact_monitor = true
	car.max_contacts_reported = 8
	world.add_child(car)
	car.reset_to(Transform3D(Basis(), Vector3(0, 0.05, 0)))
	await settle(2.5)
	var hull := car.get_node_or_null("CollisionHull")
	check(hull != null, "the supplied convex hull is used (no boxes)")
	check(car.get_node_or_null("CollisionLow") == null, "box colliders are not built when a hull exists")
	for w in car.wheels:
		check(absf(w.comp) < 0.004, "wheel %d static compression ~0 with the real meta (%f)" % [w.index, w.comp])
	check(car.get_colliding_bodies().is_empty(), "the hull does not touch the ground at ride height")
	var total := 0.0
	for w in car.wheels:
		total += w.fz
	check_near(total, car.params.mass * 9.81, 80.0, "weight carried by the wheels")
	check_near(car.params.wheelbase, 2.6867, 0.01, "wheelbase from the car meta")
	metric("hull_shape", hull.shape.get_class() if hull != null else "none")
	metric("wheelbase_from_meta", car.params.wheelbase)
	cleanup()
