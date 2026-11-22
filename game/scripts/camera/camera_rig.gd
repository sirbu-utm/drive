class_name CameraRig
extends Node3D
## Driving camera system. C cycles: chase near, chase far, hood, bumper, cockpit.
## Hold the right mouse button (or push the right stick) to orbit freely around the car; the view springs back on release.
## Works from the INTERPOLATED vehicle transform so it is smooth at any render rate (physics runs at 240 Hz).
##   Chase: spring follow, FOV grows with speed, speed/road shake, looks into the slide direction while drifting.
##   Mounted cameras (hood / bumper / cockpit): rigid on the body, cockpit adds a little head movement from g forces.

signal mode_changed(mode_name: String)

enum Mode { CHASE_NEAR, CHASE_FAR, HOOD, BUMPER, COCKPIT }
const MODE_NAMES := ["Погоня (ближняя)", "Погоня (дальняя)", "Капот", "Бампер", "Кабина"]

## mounted camera positions in the CAR frame (forward -Z, up +Y), eye / look pitch (rad), fov
const MOUNTS := {
	Mode.HOOD: {"pos": Vector3(0.0, 0.93, -0.95), "pitch": -0.03, "fov": 70.0},
	Mode.BUMPER: {"pos": Vector3(0.0, 0.42, -2.18), "pitch": 0.0, "fov": 78.0},
	Mode.COCKPIT: {"pos": Vector3(-0.30, 0.90, -0.12), "pitch": 0.0, "fov": 72.0},
}
## chase parameters: distance behind, height, look-at height, base fov, extra fov at top speed
const CHASE := {
	Mode.CHASE_NEAR: {"dist": 5.6, "height": 1.55, "look_h": 0.75, "fov": 62.0, "fov_gain": 20.0},
	Mode.CHASE_FAR: {"dist": 9.5, "height": 2.7, "look_h": 0.9, "fov": 58.0, "fov_gain": 18.0},
}

@export var vehicle: Vehicle
@export var shake_scale := 1.0
@export var mouse_sensitivity := 0.004
@export var stick_orbit_speed := 2.6
var camera: Camera3D
var mode: int = Mode.CHASE_NEAR
var orbit_yaw := 0.0
var orbit_pitch := 0.0
var _orbit_held := false
var _noise := FastNoiseLite.new()
var _t := 0.0
var _dir_yaw := 0.0                  # smoothed heading used by the chase cameras
var _pos := Vector3.ZERO
var _have_pos := false
var _clip := 1.0                     # fraction of the chase boom that is free (physics ray, updated in _physics_process)
var _fov := 62.0
var _head := Vector3.ZERO
var _shake_vel := 0.0
var _dist_extra := 0.0               # boom stretch with speed / acceleration (spring feel)
var _attr_chase: CameraAttributesPractical
var _attr_mounted: CameraAttributesPractical


func _ready() -> void:
	top_level = true
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.far = 12000.0
	camera.near = 0.08
	camera.fov = 62.0
	_attr_chase = CameraAttributesPractical.new()
	_attr_chase.auto_exposure_enabled = true
	_attr_chase.auto_exposure_scale = 0.45
	_attr_chase.auto_exposure_speed = 20.0
	# mounted cameras look out of a dark cabin: a tight exposure range keeps the cabin dark and the exterior through the glass correct
	_attr_mounted = CameraAttributesPractical.new()
	_attr_mounted.auto_exposure_enabled = true
	_attr_mounted.auto_exposure_min_sensitivity = 100.0
	_attr_mounted.auto_exposure_max_sensitivity = 400.0
	_attr_mounted.auto_exposure_scale = 0.35
	_attr_mounted.auto_exposure_speed = 20.0
	camera.attributes = _attr_chase
	add_child(camera)
	camera.current = true
	_noise.seed = 7
	_noise.frequency = 1.0
	InputSetup.ensure()
	set_process_unhandled_input(true)


## true when the camera sits inside the cabin (hood / cockpit): used for the interior audio mix
func is_interior() -> bool:
	return mode == Mode.HOOD or mode == Mode.COCKPIT


## hood / bumper / cockpit: rigidly mounted on the car
func is_mounted() -> bool:
	return mode == Mode.HOOD or mode == Mode.BUMPER or mode == Mode.COCKPIT


func set_mode(m: int) -> void:
	mode = posmod(m, MODE_NAMES.size())
	_have_pos = false
	if camera != null:
		camera.attributes = _attr_mounted if is_mounted() else _attr_chase
	mode_changed.emit(MODE_NAMES[mode])


func next_mode() -> void:
	set_mode(mode + 1)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("camera_next"):
		next_mode()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		_orbit_held = event.pressed
	elif event is InputEventMouseMotion and _orbit_held:
		var mm := event as InputEventMouseMotion
		orbit_yaw -= mm.relative.x * mouse_sensitivity
		orbit_pitch = clampf(orbit_pitch - mm.relative.y * mouse_sensitivity, -1.2, 1.3)


func _physics_process(_dt: float) -> void:
	# chase boom collision with the world (ray from the car to the wanted camera position)
	if vehicle == null or (mode != Mode.CHASE_NEAR and mode != Mode.CHASE_FAR):
		_clip = 1.0
		return
	var space := get_world_3d().direct_space_state
	var from := vehicle.global_position + Vector3(0, 1.2, 0)
	var want := _chase_target_position(vehicle.global_position)
	var q := PhysicsRayQueryParameters3D.create(from, want)
	q.exclude = [vehicle.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		_clip = minf(_clip + 0.1, 1.0)
	else:
		var f := from.distance_to(hit["position"]) / maxf(from.distance_to(want), 0.01)
		_clip = clampf(f - 0.08, 0.15, 1.0)


func _look_dir() -> Vector3:
	# horizontal direction the chase camera looks along: smoothed heading + free-orbit yaw
	return Basis(Vector3.UP, _dir_yaw + orbit_yaw) * Vector3(0.0, 0.0, -1.0)


func _chase_target_position(car_origin: Vector3) -> Vector3:
	var p: Dictionary = CHASE[Mode.CHASE_NEAR if mode == Mode.CHASE_NEAR else Mode.CHASE_FAR]
	var back: Vector3 = -_look_dir() * (float(p["dist"]) + _dist_extra)
	var pitch_up := sin(orbit_pitch) * float(p["dist"])
	return car_origin + back + Vector3(0.0, float(p["height"]) + pitch_up, 0.0)


func _process(dt: float) -> void:
	if vehicle == null or not is_instance_valid(vehicle):
		return
	_t += dt
	# right stick orbit
	var rs := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if rs.length() > 0.25:
		orbit_yaw -= rs.x * stick_orbit_speed * dt
		orbit_pitch = clampf(orbit_pitch - rs.y * stick_orbit_speed * dt, -1.2, 1.3)
	elif not _orbit_held:
		var k := 1.0 - exp(-dt * 3.0)
		orbit_yaw = lerp_angle(orbit_yaw, 0.0, k)
		orbit_pitch = lerpf(orbit_pitch, 0.0, k)
	var xf := vehicle.get_global_transform_interpolated()
	var speed := vehicle.linear_velocity.length()
	var sp01 := smoothstep(0.0, 85.0, speed)
	if mode == Mode.CHASE_NEAR or mode == Mode.CHASE_FAR:
		_update_chase(xf, dt, speed, sp01)
	else:
		_update_mounted(xf, dt, speed, sp01)


func _heading_yaw(xf: Transform3D, vel: Vector3) -> float:
	# camera "look" direction = car forward blended towards the velocity direction (looks into the slide)
	var fwd := -xf.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return _dir_yaw
	fwd = fwd.normalized()
	var v := Vector3(vel.x, 0.0, vel.z)
	var d := fwd
	if v.length() > 6.0 and vel.dot(-xf.basis.z) > 0.0:
		var w := clampf((v.length() - 6.0) / 10.0, 0.0, 1.0) * 0.45
		d = fwd.lerp(v.normalized(), w).normalized()
	return atan2(-d.x, -d.z)


func _update_chase(xf: Transform3D, dt: float, speed: float, sp01: float) -> void:
	var p: Dictionary = CHASE[Mode.CHASE_NEAR if mode == Mode.CHASE_NEAR else Mode.CHASE_FAR]
	var want_yaw := _heading_yaw(xf, vehicle.linear_velocity)
	if not _have_pos:
		_dir_yaw = want_yaw
	else:
		_dir_yaw = lerp_angle(_dir_yaw, want_yaw, 1.0 - exp(-dt * 5.0))
	var target := _chase_target_position(xf.origin)
	# collision-limited boom
	var from := xf.origin + Vector3(0, 1.2, 0)
	target = from.lerp(target, _clip)
	# horizontal: rigid on the (smoothed-heading) boom, so the camera never lags behind the car; the "spring" is the
	# heading smoothing, the boom stretching with speed / acceleration, and the vertical follow below
	if not _have_pos:
		_pos = target
		_have_pos = true
	else:
		var kv := 1.0 - exp(-dt * 5.5)
		_pos.x = target.x
		_pos.z = target.z
		_pos.y = lerpf(_pos.y, target.y, kv)
	var stretch := float(p["dist"]) * 0.22 * smoothstep(0.0, 70.0, speed) - clampf(vehicle.g_long, -1.2, 1.0) * 0.9
	_dist_extra = lerpf(_dist_extra, stretch, 1.0 - exp(-dt * 2.5))
	var look_at_p := xf.origin + Vector3(0, p["look_h"], 0)
	var cam_xf := Transform3D(Basis(), _pos).looking_at(look_at_p, Vector3.UP)
	# shake: speed + road roughness
	var sh := _shake(speed)
	cam_xf.origin += cam_xf.basis * Vector3(sh.x, sh.y, 0.0) * 0.02
	cam_xf.basis = cam_xf.basis * Basis.from_euler(Vector3(sh.y * 0.004, sh.x * 0.004, 0.0))
	global_transform = cam_xf
	_apply_fov(p["fov"] + p["fov_gain"] * sp01, dt)


func _update_mounted(xf: Transform3D, dt: float, speed: float, sp01: float) -> void:
	var m: Dictionary = MOUNTS[mode]
	var pos: Vector3 = m["pos"]
	# head movement in the cockpit from the car's accelerations
	if mode == Mode.COCKPIT:
		var target := Vector3(clampf(vehicle.g_lat * 0.03, -0.05, 0.05), clampf(-absf(vehicle.g_long) * 0.01, -0.02, 0.0), clampf(vehicle.g_long * 0.04, -0.06, 0.06))
		_head = _head.lerp(target, 1.0 - exp(-dt * 6.0))
		pos += Vector3(_head.x, _head.y, -_head.z)
	var basis_local := Basis.from_euler(Vector3(m["pitch"] + orbit_pitch, orbit_yaw, 0.0))
	var cam_xf := xf * Transform3D(basis_local, pos)
	var sh := _shake(speed) * (0.45 if mode == Mode.COCKPIT else 0.8)
	cam_xf.basis = cam_xf.basis * Basis.from_euler(Vector3(sh.y * 0.004, sh.x * 0.004, 0.0))
	global_transform = cam_xf
	var fov_extra := 6.0 * sp01 if mode != Mode.COCKPIT else 3.0 * sp01
	_apply_fov(m["fov"] + fov_extra, dt)
	_have_pos = true


func _apply_fov(target_fov: float, dt: float) -> void:
	_fov = lerpf(_fov, target_fov, 1.0 - exp(-dt * 4.0))
	camera.fov = _fov
	camera.near = 0.05 if mode == Mode.COCKPIT else 0.1


## smooth 2D shake, noise in [-1, 1] scaled by an amplitude 0..1 from speed and the wheels' suspension activity
func _shake(speed: float) -> Vector2:
	var rough := 0.0
	for w in vehicle.wheels:
		rough += absf(w.comp_vel)
	_shake_vel = lerpf(_shake_vel, clampf(rough * 0.12, 0.0, 1.0), 0.1)
	var amp := (clampf(speed / 90.0, 0.0, 1.0) * 0.3 + _shake_vel * 0.8) * shake_scale
	return Vector2(_noise.get_noise_2d(_t * 9.0, 0.0), _noise.get_noise_2d(_t * 11.0, 77.0)) * amp
