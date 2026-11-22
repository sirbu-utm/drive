class_name Vehicle
extends RigidBody3D
## Custom car physics on top of a RigidBody3D (Jolt). The chassis is a plain rigid body with explicit centre of
## mass and inertia; everything else (suspension, tyres, drivetrain, aero, assists) is computed here every physics
## tick (240 Hz) in _integrate_forces and applied as forces. No VehicleBody3D.
##
## Frame: forward = -Z, right = +X, up = +Y. Wheel order everywhere: FL, FR, RL, RR (RWD: rear = driven).
##
## The visual model is swappable: `car_scene` (PackedScene with Body/Wheel_xx/Caliper_xx nodes) + `meta_path`
## (json, see game/scripts/vehicle/placeholder_meta.json). With neither set a box + 4 cylinders is built.

signal shifted(gear: int)

@export var params: VehicleParams = VehicleParams.new()
@export var car_scene: PackedScene
@export_file("*.json") var meta_path := "res://scripts/vehicle/placeholder_meta.json"
@export var build_visual := true
## optional simplified convex hull of the body (ConvexPolygonShape3D, car frame). Used when the file exists,
## otherwise two boxes from the meta bounding box are used.
@export var hull_path := ""

const WHEEL_NAMES := ["FL", "FR", "RL", "RR"]
const WORLD_MASK := 1

# ---- driver commands (set by player controller / tests) -------------------------------------------------
var throttle_pedal := 0.0       # 0..1
var brake_pedal := 0.0          # 0..1
var steer_angle_cmd := 0.0      # average front wheel angle, rad, + = left
var handbrake := 0.0            # 0..1
var steer_assist_extra := 0.0

# ---- modules ----------------------------------------------------------------------------------------------
var wheels: Array[VehicleWheel] = []
var drivetrain: Drivetrain
var aero: Aero
var assists: Assists
var tire: TireModel
var meta: Dictionary = {}

# ---- convenience read-outs for HUD / visual / audio layers
var speed_kmh: float:
	get: return fwd_speed * 3.6
var rpm: float:
	get: return drivetrain.rpm if drivetrain != null else 0.0
var gear: int:
	get: return drivetrain.gear if drivetrain != null else 0
var throttle: float:
	get: return throttle_pedal
var brake: float:
	get: return brake_pedal

# ---- derived state (updated every tick, read by HUD/camera/tests) -----------------------------------------
var speed := 0.0                # |v| m/s
var fwd_speed := 0.0            # m/s along the body (+ forward)
var lat_speed := 0.0            # m/s to the right
var yaw_rate := 0.0             # rad/s, + = turning left
var accel_local := Vector3.ZERO # m/s^2 in body axes (x right, y up, z back), from velocity differences
var g_lat := 0.0                # lateral acceleration in g (+ = to the right)
var g_long := 0.0               # longitudinal acceleration in g (+ = forward)
var wheel_steer := [0.0, 0.0]   # current front wheel angles (left, right)
var airborne := false

var _prev_v := Vector3.ZERO
var _first := true
var _cog_local := Vector3.ZERO
var _knuckles: Array[Node3D] = []
var _wheel_nodes: Array[Node3D] = []
var _caliper_nodes: Array[Node3D] = []
var _visual_root: Node3D
var _car_visual: Node
var _arb_front := 0.0
var _gear_prev := 1
var _steer_cur := 0.0
var _static_loads := [0.0, 0.0, 0.0, 0.0]
var _a_v_filter := Vector3.ZERO


func _ready() -> void:
	_load_meta()
	_setup_body()
	_setup_wheels()
	drivetrain = Drivetrain.new(params)
	aero = Aero.new(params)
	assists = Assists.new(params)
	tire = TireModel.new(params)
	if build_visual:
		_build_visual()
	_first = true


# ---- setup ----------------------------------------------------------------------------------------------------

func _load_meta() -> void:
	meta = {}
	if meta_path != "" and FileAccess.file_exists(meta_path):
		var f := FileAccess.open(meta_path, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			meta = parsed
	if meta.has("wheelbase"):
		params.wheelbase = float(meta["wheelbase"])
	if meta.has("track_front"):
		params.track_front = float(meta["track_front"])
	if meta.has("track_rear"):
		params.track_rear = float(meta["track_rear"])


func _meta_wheel(name: String) -> Dictionary:
	var ws: Dictionary = meta.get("wheels", {})
	return ws.get(name, {})


func _setup_body() -> void:
	mass = params.mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	# wheel positions decide the CoM position along the car
	var zf := -params.wheelbase * 0.5
	var zr := params.wheelbase * 0.5
	var fl := _meta_wheel("FL")
	var rl := _meta_wheel("RL")
	if not fl.is_empty() and not rl.is_empty():
		var pf := _vec3(fl.get("pos", fl.get("position", [0, 0, zf])))
		var pr := _vec3(rl.get("pos", rl.get("position", [0, 0, zr])))
		zf = pf.z
		zr = pr.z
	var l := zr - zf
	_cog_local = Vector3(0.0, params.cog_height, zf + (1.0 - params.front_weight_fraction) * l)
	center_of_mass = _cog_local
	inertia = params.inertia
	can_sleep = false
	continuous_cd = true
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	collision_layer = 2
	collision_mask = WORLD_MASK
	var pm := PhysicsMaterial.new()
	pm.friction = 0.25
	pm.bounce = 0.0
	physics_material_override = pm
	# collision: a supplied convex hull, else a low box + narrower cabin box from the bounding box
	if hull_path != "" and ResourceLoader.exists(hull_path):
		var hull := load(hull_path) as Shape3D
		if hull != null:
			var hc := CollisionShape3D.new()
			hc.shape = hull
			hc.name = "CollisionHull"
			add_child(hc)
			return
	var bb := _bbox()
	var bmin: Vector3 = bb[0]
	var bmax: Vector3 = bb[1]
	var low_top := lerpf(bmin.y, bmax.y, 0.55)
	var lo := CollisionShape3D.new()
	var b1 := BoxShape3D.new()
	b1.size = Vector3(bmax.x - bmin.x - 0.10, low_top - bmin.y, bmax.z - bmin.z - 0.10)
	lo.shape = b1
	lo.position = Vector3((bmin.x + bmax.x) * 0.5, (bmin.y + low_top) * 0.5, (bmin.z + bmax.z) * 0.5)
	lo.name = "CollisionLow"
	add_child(lo)
	var hi := CollisionShape3D.new()
	var b2 := BoxShape3D.new()
	b2.size = Vector3((bmax.x - bmin.x) * 0.6, bmax.y - low_top, (bmax.z - bmin.z) * 0.42)
	hi.shape = b2
	hi.position = Vector3((bmin.x + bmax.x) * 0.5, (low_top + bmax.y) * 0.5, lerpf(bmin.z, bmax.z, 0.52))
	hi.name = "CollisionCabin"
	add_child(hi)


## bounding box from the meta (componentwise min/max, so a swapped pair in the json is harmless)
func _bbox() -> Array:
	var a := _vec3(meta.get("bbox_min", [-1.0, 0.10, -2.15]))
	var b := _vec3(meta.get("bbox_max", [1.0, 1.08, 2.15]))
	return [a.min(b), a.max(b)]


static func _vec3(a: Variant) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func _setup_wheels() -> void:
	wheels.clear()
	var ex: Array[RID] = [get_rid()]
	var g := 9.81
	for i in 4:
		var name: String = WHEEL_NAMES[i]
		var w := VehicleWheel.new()
		w.index = i
		w.front = i < 2
		w.left = (i % 2) == 0
		var md := _meta_wheel(name)
		var pos := Vector3(
			(-1.0 if w.left else 1.0) * (params.track_front if w.front else params.track_rear) * 0.5,
			params.wheel_radius,
			(-1.0 if w.front else 1.0) * params.wheelbase * 0.5)
		if not md.is_empty():
			pos = _vec3(md.get("pos", md.get("position", [pos.x, pos.y, pos.z])))
			w.radius = float(md.get("radius", params.wheel_radius))
			w.width = float(md.get("width", params.wheel_width))
		else:
			w.radius = params.wheel_radius
			w.width = params.wheel_width
		w.rest_pos = pos
		w.inertia = params.wheel_inertia
		w.spring = params.spring_front if w.front else params.spring_rear
		w.bump_damp = params.bump_front if w.front else params.bump_rear
		w.rebound_damp = params.rebound_front if w.front else params.rebound_rear
		var axle_load := params.mass * g * (params.front_weight_fraction if w.front else 1.0 - params.front_weight_fraction)
		w.spring_preload = axle_load * 0.5
		_static_loads[i] = w.spring_preload
		w.setup(ex, WORLD_MASK)
		wheels.append(w)
	params.wheel_radius = wheels[0].radius


func _build_visual() -> void:
	_visual_root = Node3D.new()
	_visual_root.name = "Visual"
	add_child(_visual_root)
	var model: Node3D = null
	if car_scene != null:
		model = car_scene.instantiate() as Node3D
	if model == null:
		model = _placeholder_model()
	_visual_root.add_child(model)
	_car_visual = model if model.has_method("get_wheel") else null
	# knuckles: steering + suspension carrier, wheels spin inside
	_knuckles.clear()
	_wheel_nodes.clear()
	_caliper_nodes.clear()
	for i in 4:
		var name: String = WHEEL_NAMES[i]
		var k := Node3D.new()
		k.name = "Knuckle_" + name
		_visual_root.add_child(k)
		k.position = wheels[i].rest_pos
		_knuckles.append(k)
		var wn: Node3D = _car_visual.get_wheel(name) if _car_visual != null else model.find_child("Wheel_" + name, true, false) as Node3D
		if wn != null:
			wn.reparent(k, false)
			wn.position = Vector3.ZERO
		_wheel_nodes.append(wn)
		var cn: Node3D = _car_visual.get_caliper(name) if _car_visual != null else model.find_child("Caliper_" + name, true, false) as Node3D
		if cn != null:
			cn.reparent(k, false)
			cn.position = Vector3.ZERO
		_caliper_nodes.append(cn)


func _placeholder_model() -> Node3D:
	var root := Node3D.new()
	root.name = "PlaceholderCar"
	var bb := _bbox()
	var bmin: Vector3 = bb[0]
	var bmax: Vector3 = bb[1]
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	var low_top := lerpf(bmin.y, bmax.y, 0.55)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.08, 0.06)
	mat.metallic = 0.4
	mat.roughness = 0.35
	var m1 := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(bmax.x - bmin.x, low_top - bmin.y, bmax.z - bmin.z)
	m1.mesh = bm
	m1.material_override = mat
	m1.position = Vector3((bmin.x + bmax.x) * 0.5, (bmin.y + low_top) * 0.5, (bmin.z + bmax.z) * 0.5)
	body.add_child(m1)
	var m2 := MeshInstance3D.new()
	var bm2 := BoxMesh.new()
	bm2.size = Vector3((bmax.x - bmin.x) * 0.62, bmax.y - low_top, (bmax.z - bmin.z) * 0.4)
	m2.mesh = bm2
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.08, 0.1, 0.12, 0.7)
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m2.material_override = gm
	m2.position = Vector3((bmin.x + bmax.x) * 0.5, (low_top + bmax.y) * 0.5, lerpf(bmin.z, bmax.z, 0.52))
	body.add_child(m2)
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.04, 0.04, 0.04)
	tm.roughness = 0.9
	var stripe := StandardMaterial3D.new()
	stripe.albedo_color = Color(0.9, 0.9, 0.9)
	for i in 4:
		var w := wheels[i]
		var holder := Node3D.new()
		holder.name = "Wheel_" + WHEEL_NAMES[i]
		holder.position = w.rest_pos
		root.add_child(holder)
		var cyl := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = w.radius
		cm.bottom_radius = w.radius
		cm.height = w.width
		cyl.mesh = cm
		cyl.material_override = tm
		cyl.rotation = Vector3(0.0, 0.0, PI * 0.5)
		holder.add_child(cyl)
		# a stripe so the rotation is visible
		var st := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(w.width * 1.01, w.radius * 1.9, 0.05)
		st.mesh = sm
		st.material_override = stripe
		holder.add_child(st)
	return root


# ---- public API ---------------------------------------------------------------------------------------------

## Direct controls (used by tests and by the player controller after InputFilter).
func drive(throttle: float, brake: float, steer_angle: float, hand: float = 0.0) -> void:
	throttle_pedal = clampf(throttle, 0.0, 1.0)
	brake_pedal = clampf(brake, 0.0, 1.0)
	steer_angle_cmd = steer_angle
	handbrake = clampf(hand, 0.0, 1.0)


func shift_up() -> void:
	drivetrain.request_shift(1)


func shift_down() -> void:
	drivetrain.request_shift(-1)


func set_auto_gearbox(on: bool) -> void:
	drivetrain.auto = on


## Select reverse (only when nearly stopped) / back to first gear.
func set_reverse(on: bool) -> void:
	if drivetrain == null:
		return
	if on and drivetrain.gear >= 0 and absf(fwd_speed) < 1.5:
		drivetrain.gear = -1
		drivetrain.shifting = false
	elif not on and drivetrain.gear < 0 and fwd_speed > -1.5:
		drivetrain.gear = 1
		drivetrain.shifting = false


## Place the car (ground contact height is handled by the suspension: spawn slightly above the ground).
func reset_to(xf: Transform3D, vel: Vector3 = Vector3.ZERO) -> void:
	global_transform = xf
	linear_velocity = vel
	angular_velocity = Vector3.ZERO
	for w in wheels:
		w.comp = 0.0
		w.comp_prev = 0.0
		w.comp_vel = 0.0
		w.omega = (-xf.basis.z.dot(vel)) / w.radius
		w.bristle = Vector2.ZERO
		w.alpha_lag = 0.0
		w.abs_mod = 1.0
	if drivetrain != null:
		drivetrain.sync_to_speed(maxf(-xf.basis.z.dot(vel), 0.0))
	_first = true


func get_static_load(i: int) -> float:
	return _static_loads[i]


func get_telemetry() -> Dictionary:
	var ws := []
	for w in wheels:
		ws.append({"fz": w.fz, "fx": w.fx, "fy": w.fy, "kappa": w.kappa, "alpha": w.alpha, "comp": w.comp,
			"omega": w.omega, "contact": w.in_contact, "abs": w.abs_active, "surface_mu": w.surface["mu"]})
	return {"speed": speed, "fwd": fwd_speed, "rpm": drivetrain.rpm, "gear": drivetrain.gear, "wheels": ws,
		"g_lat": g_lat, "g_long": g_long, "tcs": assists.tcs_active, "abs": assists.abs_active,
		"esc": assists.esc_active, "yaw_rate": yaw_rate, "throttle": throttle_pedal, "brake": brake_pedal}


# ---- physics ------------------------------------------------------------------------------------------------

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if wheels.is_empty():
		return
	var dt := state.step
	var xf := state.transform
	var com := xf.origin + state.center_of_mass
	var v := state.linear_velocity
	var w_ang := state.angular_velocity
	var space := state.get_space_state()
	var up := xf.basis.y
	var fwd := -xf.basis.z
	var right := xf.basis.x

	fwd_speed = v.dot(fwd)
	lat_speed = v.dot(right)
	speed = v.length()
	yaw_rate = w_ang.dot(up)
	if not _first:
		var a := (v - _prev_v) / dt
		_a_v_filter = _a_v_filter.lerp(a, 1.0 - exp(-dt / 0.03))
		g_lat = _a_v_filter.dot(right) / 9.81
		g_long = _a_v_filter.dot(fwd) / 9.81
	_prev_v = v
	_first = false

	_update_controls(dt)

	# ---- suspension: cast + spring/damper
	var any_contact := false
	for w in wheels:
		w.cast(space, xf, params.travel_bump, params.travel_droop)
		w.compute_suspension(dt, params)
		any_contact = any_contact or w.in_contact
	airborne = not any_contact
	# anti-roll bars
	for pair in [[0, 1, params.arb_front], [2, 3, params.arb_rear]]:
		var a: VehicleWheel = wheels[pair[0]]
		var b: VehicleWheel = wheels[pair[1]]
		if a.in_contact and b.in_contact:
			var f: float = pair[2] * (a.comp - b.comp)
			a.arb_force = f
			b.arb_force = -f
		else:
			a.arb_force = 0.0
			b.arb_force = 0.0

	# ---- tyres, forces on the chassis
	for w in wheels:
		var hub := w.hub_world
		var v_hub := v + w_ang.cross(hub - com)
		w.compute_tire(dt, params, tire, xf, v_hub)
		if w.in_contact and w.fz > 0.0:
			var n := w.contact_normal
			var contact := hub - n * w.radius
			w.contact_world = contact
			state.apply_force(n * w.fz, contact - xf.origin)
			var horiz := w.f_fwd * w.fx + w.f_right * w.fy
			state.apply_force(horiz, contact + up * params.force_height - xf.origin)
	# ---- aero
	for fp in aero.compute(v, xf):
		state.apply_force(fp[0], fp[1] - xf.origin)

	# ---- assists + drivetrain
	_update_assists_and_drivetrain(dt, xf)

	# gear change signal
	if drivetrain.gear != _gear_prev:
		_gear_prev = drivetrain.gear
		shifted.emit(drivetrain.gear)


func _update_controls(dt: float) -> void:
	# steering with rate limit and optional counter-steer helper
	var extra := 0.0
	if assists.countersteer_on:
		extra = -assists.compute_countersteer(fwd_speed, lat_speed, yaw_rate) * deg_to_rad(params.max_steer_angle_deg) * 0.3
	var target := steer_angle_cmd + extra
	_steer_cur = move_toward(_steer_cur, target, params.steer_rate * dt)
	var delta_mean := _steer_cur
	# Ackermann
	var L := params.wheelbase
	var tf := params.track_front
	var ang_l := delta_mean
	var ang_r := delta_mean
	if absf(delta_mean) > 1e-4:
		var rc := L / tan(absf(delta_mean))
		var inner := atan(L / (rc - tf * 0.5))
		var outer := atan(L / (rc + tf * 0.5))
		if delta_mean > 0.0:        # left turn: left wheel is the inner one
			ang_l = inner
			ang_r = outer
		else:
			ang_l = -outer
			ang_r = -inner
	wheels[0].steer = ang_l
	wheels[1].steer = ang_r
	wheel_steer = [ang_l, ang_r]


func _update_assists_and_drivetrain(dt: float, xf: Transform3D) -> void:
	var rear: Array = [wheels[2], wheels[3]]
	# assists
	assists.update_abs(dt, wheels, speed)
	assists.update_tcs(dt, rear, speed, tire, drivetrain)
	assists.update_esc(dt, yaw_rate, _steer_cur, fwd_speed, lat_speed, wheels)

	# brake torque per wheel
	var bt := params.brake_torque_total * brake_pedal
	var pedal_f := bt * params.brake_bias_front * 0.5
	var pedal_r := bt * (1.0 - params.brake_bias_front) * 0.5
	var hold := 0.0
	if throttle_pedal < 0.02 and brake_pedal < 0.02 and handbrake < 0.01 and absf(fwd_speed) < 0.6:
		hold = params.auto_hold_torque
	for i in 4:
		var w := wheels[i]
		var ped := pedal_f if i < 2 else pedal_r
		w.brake_cmd = ped
		var total: float = ped * w.abs_mod + float(assists.esc_brake[i]) + hold
		if i >= 2:
			total += params.handbrake_torque * handbrake * 0.5
		w.brake_applied = total

	# drivetrain
	var thr := throttle_pedal * assists.esc_throttle_scale
	drivetrain.throttle_pedal = throttle_pedal
	drivetrain.brake_pedal = brake_pedal
	drivetrain.throttle = thr
	drivetrain.auto_shift(dt, throttle_pedal, absf(fwd_speed), brake_pedal)
	if drivetrain.auto and brake_pedal > 0.02 and fwd_speed < -0.5 and drivetrain.gear > 0:
		pass
	var out: Array = [0.0, 0.0]
	drivetrain.step(dt, rear, absf(fwd_speed), assists.tcs_scale, assists.traction_torque, out)

	# wheel angular speeds (front wheels free-rolling, rear from the drivetrain), then Coulomb brakes
	for i in 4:
		var w := wheels[i]
		var a := dt / (w.inertia + dt * w.torque_k)
		var om_nb: float
		if i >= 2:
			om_nb = out[i - 2]
		else:
			om_nb = w.omega + a * (w.torque_tire - drivetrain.rolling_torque(w))
		var db := a * w.brake_applied
		if absf(om_nb) <= db:
			w.omega = 0.0
		else:
			w.omega = om_nb - signf(om_nb) * db
		w.spin_angle += w.omega * dt


func _physics_process(_delta: float) -> void:
	_update_visual()


func _update_visual() -> void:
	if _knuckles.is_empty():
		return
	if _car_visual != null:
		_car_visual.call("set_brake", brake_pedal)
		_car_visual.call("set_reverse", drivetrain != null and drivetrain.gear < 0)
	for i in 4:
		var w := wheels[i]
		var k := _knuckles[i]
		k.position = w.rest_pos + Vector3.UP * w.comp
		k.rotation = Vector3(0.0, w.steer, 0.0)
		var wn := _wheel_nodes[i]
		if wn != null:
			wn.rotation = Vector3(-fposmod(w.spin_angle, TAU), 0.0, 0.0)
