class_name TestTrack
extends Node3D
## Phase 2 proving ground: big flat plane, R=60 m skidpad, 12 m / 9 deg jump ramp, 15 deg slope, curbs, speed bumps,
## grass / gravel / sand patches, slalom cones. Drive with W/A/S/D (see PlayerController). R = reset.
##
## Demo modes for screenshots/movies (godot ... scene -- --demo=skidpad|drift|accel|slalom|jump  [--cam=chase|side|top|front34]).

const SKIDPAD_R := 60.0

@export var use_real_car := true
var car: Vehicle
var cam: ChaseCamera
var controller: PlayerController
var overlay: TelemetryOverlay
var demo := ""
var _t := 0.0
var _bstar := deg_to_rad(20.0)


func _ready() -> void:
	var cam_mode := "chase"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--demo="):
			demo = a.substr(7)
		elif a.begins_with("--cam="):
			cam_mode = a.substr(6)
	_build_world()
	_spawn_car()
	cam = ChaseCamera.new()
	cam.target = car
	cam.mode = cam_mode
	add_child(cam)
	overlay = TelemetryOverlay.new()
	overlay.vehicle = car
	add_child(overlay)
	if demo == "":
		controller = PlayerController.new()
		controller.vehicle = car
		controller.reset_requested.connect(_reset_car)
		controller.telemetry_toggled.connect(overlay.toggle)
		add_child(controller)


func _build_world() -> void:
	TestWorld.add_light_and_sky(self)
	TestWorld.add_ground(self, 1400.0, "asphalt", true)
	# skidpad ring (flat torus) centred 60 m to the left of the start
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = SKIDPAD_R - 0.12
	tm.outer_radius = SKIDPAD_R + 0.12
	tm.rings = 128
	tm.ring_segments = 4
	ring.mesh = tm
	ring.scale = Vector3(1, 0.02, 1)
	ring.position = Vector3(-SKIDPAD_R, 0.004, 0)
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.95, 0.95, 0.95)
	ring.material_override = rm
	add_child(ring)
	# start line
	var line := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(12, 0.01, 0.5)
	line.mesh = lb
	line.position = Vector3(-3, 0.006, 6)
	line.material_override = rm
	add_child(line)
	# jump ramp (same geometry as the unit test) straight ahead, 200 m
	TestWorld.add_incline(self, -200.0, 12.0, 9.0, 8.0, "asphalt", true, 0.0)
	# 15 degree slope to the right of the start
	TestWorld.add_incline(self, -20.0, 40.0, 15.0, 10.0, "asphalt", true, 40.0)
	# surface patches
	TestWorld.add_surface_patch(self, Vector2(-120, -230), Vector2(60, 90), "grass", Color(0.22, 0.42, 0.15))
	TestWorld.add_surface_patch(self, Vector2(-40, -230), Vector2(40, 90), "gravel", Color(0.55, 0.5, 0.42))
	TestWorld.add_surface_patch(self, Vector2(30, -230), Vector2(40, 90), "sand", Color(0.78, 0.68, 0.45))
	# curbs and speed bumps
	for i in 8:
		TestWorld.add_box(self, Vector3(1.2, 0.07, 3.0), Vector3(-14.0, 0.035, -60.0 - i * 8.0), Vector3.ZERO, "curb",
			Color(0.9, 0.9, 0.9) if i % 2 == 0 else Color(0.85, 0.1, 0.1))
	for i in 3:
		TestWorld.add_box(self, Vector3(12.0, 0.06, 0.8), Vector3(0.0, 0.0, -120.0 - i * 15.0), Vector3.ZERO, "asphalt", Color(0.9, 0.8, 0.1))
	# slalom cones along z = +60 .. +260 (driving towards +Z is not the default, they sit beside the start straight)
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(1.0, 0.45, 0.05)
	for i in 10:
		var c := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.02
		cyl.bottom_radius = 0.18
		cyl.height = 0.5
		c.mesh = cyl
		c.material_override = cm
		c.position = Vector3(10.0 if i % 2 == 0 else 14.0, 0.25, -30.0 - i * 25.0)
		add_child(c)


func _spawn_car() -> void:
	car = Vehicle.new()
	if use_real_car:
		car.car_scene = load("res://assets/cars/ccgt/ccgt_visual.tscn")
		car.meta_path = "res://assets/cars/ccgt/ccgt_meta.json"
		car.hull_path = "res://assets/cars/ccgt/ccgt_hull.res"
	add_child(car)
	_reset_car()


func _reset_car() -> void:
	car.reset_to(Transform3D(Basis(), Vector3(0, 0.05, 0)))
	car.drive(0, 0, 0, 0)


func _physics_process(dt: float) -> void:
	if demo == "":
		return
	_t += dt
	match demo:
		"skidpad":
			_demo_skidpad()
		"drift":
			_demo_drift()
		"accel":
			_demo_accel()
		"slalom":
			_demo_slalom()
		"jump":
			_demo_jump()


func _pursuit(target: Vector3) -> float:
	var local := car.global_transform.affine_inverse() * target
	var ld := maxf(Vector2(local.x, local.z).length(), 0.5)
	var alpha := atan2(-local.x, -local.z)
	return atan2(2.0 * car.params.wheelbase * sin(alpha), ld)


func _demo_skidpad() -> void:
	if _t < 0.02:
		car.reset_to(Transform3D(Basis(), Vector3(0, 0.05, 0)), Vector3(0, 0, -16.0))
	var centre := Vector3(-SKIDPAD_R, 0, 0)
	var vt := minf(16.0 + 0.8 * _t, 27.5)
	var rel := car.global_position - centre
	var th := atan2(rel.z, rel.x) - maxf(6.0, 0.35 * car.speed) / SKIDPAD_R
	var target := centre + Vector3(cos(th), 0, sin(th)) * SKIDPAD_R
	var e := vt - car.fwd_speed
	car.drive(clampf(0.5 * e, 0.0, 1.0), clampf(-0.3 * e, 0.0, 1.0), _pursuit(target))


func _demo_accel() -> void:
	if _t < 1.0:
		car.drive(1.0, 1.0, 0.0)         # launch control
	else:
		car.drive(1.0, 0.0, 0.0)


func _demo_slalom() -> void:
	if _t < 0.02:
		car.reset_to(Transform3D(Basis(), Vector3(12, 0.05, 0)), Vector3(0, 0, -22.0))
	var s := -car.global_position.z
	var idx := int(floor((s + 10.0) / 25.0))
	var tz := s + 14.0
	var k := (tz + 30.0) / 25.0
	var off := 12.0 + 3.0 * cos(PI * (tz - 30.0) / 25.0) if tz > 30.0 else 12.0
	car.drive(clampf(0.4 * (22.0 - car.fwd_speed), 0.0, 1.0), clampf(0.3 * (car.fwd_speed - 22.0), 0.0, 1.0), _pursuit(Vector3(off, 0, -tz)))


func _demo_jump() -> void:
	if _t < 0.02:
		car.reset_to(Transform3D(Basis(), Vector3(0, 0.05, -180.0)), Vector3(0, 0, -27.8))
	car.drive(0.3 if not car.airborne else 0.0, 0.0, 0.0)


func _demo_drift() -> void:
	if _t < 0.02:
		car.assists.tcs_on = false
		car.assists.esc_on = false
		car.set_auto_gearbox(false)
		car.drivetrain.gear = 2
		car.reset_to(Transform3D(Basis(), Vector3(0, 0.05, 0)), Vector3(0, 0, -17.0))
		car.drivetrain.gear = 2
	var beta := atan2(car.lat_speed, maxf(absf(car.fwd_speed), 3.0))
	var thr := 0.0
	var st := 0.0
	if _t < 0.5:
		st = deg_to_rad(-6.0)
		thr = 0.2
	elif _t < 1.1:
		st = deg_to_rad(12.0)
		thr = 1.0
	else:
		st = clampf(-beta - 1.0 * (beta - _bstar), -0.5, 0.5)
		thr = clampf(0.8 + 0.12 * (40.0 - car.speed), 0.3, 1.0)
	car.drive(thr, 0.0, st)
