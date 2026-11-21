class_name VehicleWheel
extends RefCounted
## One corner: suspension (shape cast + spring/damper/bump stop), tyre forces (Magic Formula + low speed stick
## model), wheel spin degree of freedom. The drivetrain integrates `omega`; this class only produces torques.

var index := 0
var front := true
var left := true
var radius := 0.3225
var width := 0.33
var inertia := 1.2
## chassis-local hub position at static ride height
var rest_pos := Vector3.ZERO

# suspension setup
var spring := 100000.0
var bump_damp := 4000.0
var rebound_damp := 7000.0
var spring_preload := 2500.0

# --- suspension state
var comp := 0.0                 # hub displacement up from the static position (m)
var comp_prev := 0.0
var comp_vel := 0.0
var in_contact := false
var contact_normal := Vector3.UP
var ground_vel := Vector3.ZERO
var surface: Dictionary = SurfaceDB.SURFACES["asphalt"]
var hub_world := Vector3.ZERO
var contact_world := Vector3.ZERO
var susp_force := 0.0           # normal load transmitted by the suspension (before ARB)
var arb_force := 0.0

# --- wheel state
var steer := 0.0                # yaw about the chassis +Y (rad, + = turn left)
var omega := 0.0                # rad/s, + = rolling forward
var spin_angle := 0.0

# --- tyre results (contact frame)
var fz := 0.0
var fx := 0.0
var fy := 0.0                   # along `right`
var kappa := 0.0
var alpha := 0.0
var slip_speed_x := 0.0

# --- public read-only style aliases for the visual / audio layers
var slip_ratio: float:
	get: return kappa
var slip_angle: float:
	get: return alpha
var load: float:
	get: return fz
var is_grounded: bool:
	get: return in_contact
var contact_point: Vector3:
	get: return contact_world
var surface_key: String:
	get: return String(surface.get("key", "asphalt"))
var ground_speed := 0.0
var torque_tire := 0.0          # torque on the wheel from the contact patch (about the axle), Nm
var torque_k := 0.0             # d(torque)/d(omega), >= 0, used for the implicit wheel update
var f_fwd := Vector3.FORWARD
var f_right := Vector3.RIGHT
var vx := 0.0
var vy := 0.0
var sliding := false

# --- internal tyre state
var bristle := Vector2.ZERO
var alpha_lag := 0.0

# --- assist / control state
var abs_mod := 1.0
var abs_active := false
var brake_cmd := 0.0            # Nm requested by pedal/handbrake/hold (before ABS)
var brake_applied := 0.0

var _sphere: SphereShape3D
var _q_cast: PhysicsShapeQueryParameters3D
var _q_rest: PhysicsShapeQueryParameters3D


func setup(exclude: Array[RID], mask: int) -> void:
	_sphere = SphereShape3D.new()
	_sphere.radius = radius
	_q_cast = PhysicsShapeQueryParameters3D.new()
	_q_cast.shape = _sphere
	_q_cast.exclude = exclude
	_q_cast.collision_mask = mask
	_q_cast.collide_with_bodies = true
	_q_cast.collide_with_areas = false
	_q_cast.margin = 0.0
	_q_rest = PhysicsShapeQueryParameters3D.new()
	_q_rest.shape = _sphere
	_q_rest.exclude = exclude
	_q_rest.collision_mask = mask
	_q_rest.collide_with_bodies = true
	_q_rest.collide_with_areas = false


## Find the ground below the hub. xf = chassis transform.
func cast(space: PhysicsDirectSpaceState3D, xf: Transform3D, travel_bump: float, travel_droop: float) -> void:
	var up := xf.basis.y
	var total := travel_bump + travel_droop
	var top := xf * (rest_pos + Vector3.UP * travel_bump)
	_q_cast.transform = Transform3D(Basis(), top)
	_q_cast.motion = -up * total
	var r := space.cast_motion(_q_cast)
	comp_prev = comp
	if r.size() < 2 or (r[0] >= 1.0 and r[1] >= 1.0):
		in_contact = false
		comp = -travel_droop
		hub_world = xf * (rest_pos + Vector3.UP * comp)
		contact_normal = up
		return
	# coarse hit distance from the top of the travel (cast_motion is quantised to ~1 mm) ...
	var d := total * r[1]
	var normal := up
	var d_exact := d
	# ... refined with the exact penetration depth of the sphere placed slightly below the first contact
	const PROBE := 0.004
	var probe := top - up * (d + PROBE)
	_q_rest.transform = Transform3D(Basis(), probe)
	var cp := space.collide_shape(_q_rest, 8)
	var best := -1.0
	var i := 0
	while i + 1 < cp.size():
		var pa: Vector3 = cp[i]
		var pb: Vector3 = cp[i + 1]
		var dep := pa.distance_to(pb)
		if dep > best:
			var dirv := pb - pa
			if dep > 1e-6 and dirv.dot(up) > 0.0:
				best = dep
				normal = dirv / dep
		i += 2
	if best >= 0.0:
		d_exact = d + PROBE - best / maxf(normal.dot(up), 0.35)
	comp = clampf(travel_bump - d_exact, -travel_droop, travel_bump)
	hub_world = xf * (rest_pos + Vector3.UP * comp)
	in_contact = true
	if normal.dot(up) < 0.35:
		normal = up
	contact_normal = normal
	# surface / ground velocity
	_q_rest.transform = Transform3D(Basis(), probe)
	var info := space.get_rest_info(_q_rest)
	if info.is_empty():
		ground_vel = Vector3.ZERO
		surface = SurfaceDB.SURFACES["asphalt"]
	else:
		ground_vel = info.get("linear_velocity", Vector3.ZERO)
		var obj := instance_from_id(info["collider_id"]) if info.has("collider_id") else null
		var hit: Vector3 = info.get("point", Vector3.INF)
		surface = SurfaceDB.get_surface(obj, hit) if obj != null else SurfaceDB.SURFACES["asphalt"]


func compute_suspension(dt: float, p: VehicleParams) -> void:
	if not in_contact:
		susp_force = 0.0
		comp_vel = lerpf(comp_vel, 0.0, 0.3)
		return
	var vel := clampf((comp - comp_prev) / dt, -4.0, 4.0)
	comp_vel = lerpf(comp_vel, vel, 1.0 - exp(-dt / 0.010))
	var f := maxf(spring_preload + spring * comp, 0.0)
	f += (bump_damp if comp_vel > 0.0 else rebound_damp) * comp_vel
	var x := comp - (p.travel_bump - p.bumpstop_length)
	if x > 0.0:
		f += p.bumpstop_rate * x * (1.0 + 3.0 * x / p.bumpstop_length)
	susp_force = f


## Tyre forces. v_hub: world velocity of the hub point. Sets fx, fy, torque_tire, torque_k.
func compute_tire(dt: float, p: VehicleParams, tire: TireModel, xf: Transform3D, v_hub: Vector3, extra_mu: float = 1.0) -> void:
	fz = maxf(susp_force + arb_force, 0.0)
	var up := xf.basis.y
	var n := contact_normal
	var fw := xf.basis * Vector3(-sin(steer), 0.0, -cos(steer))
	f_fwd = (fw - n * fw.dot(n)).normalized()
	f_right = f_fwd.cross(n)
	if not in_contact or fz <= 0.0:
		fx = 0.0
		fy = 0.0
		kappa = 0.0
		alpha = 0.0
		torque_tire = 0.0
		torque_k = 0.0
		sliding = false
		bristle = Vector2.ZERO
		alpha_lag = 0.0
		return
	var vrel := v_hub - ground_vel
	vx = vrel.dot(f_fwd)
	vy = vrel.dot(f_right)
	ground_speed = sqrt(vx * vx + vy * vy)
	var mu_scale: float = surface["mu"] * extra_mu
	var R := radius
	slip_speed_x = omega * R - vx
	var w_stick := 1.0 - smoothstep(p.stick_speed_low, p.stick_speed_high, ground_speed)

	# ---- Magic Formula branch
	var fx_m := 0.0
	var fy_m := 0.0
	var k_m := 0.0
	var vden := maxf(absf(vx), 1.2)
	kappa = slip_speed_x / vden
	alpha = atan2(vy, vden)
	if w_stick < 0.999:
		if p.relaxation_length > 0.0 and w_stick < 0.5:
			var a := 1.0 - exp(-maxf(ground_speed, 0.5) * dt / p.relaxation_length)
			alpha_lag += (alpha - alpha_lag) * a
		else:
			alpha_lag = alpha
		var fm := tire.combined(kappa, alpha_lag, fz, mu_scale)
		fx_m = fm.x
		fy_m = -fm.y
		k_m = maxf(fm.z, 0.0) * R * R / vden
	# ---- stick (bristle) branch
	var fx_s := 0.0
	var fy_s := 0.0
	var k_s := 0.0
	var kb := p.stick_stiffness * fz
	var cb := p.stick_damping * fz
	if w_stick > 0.001:
		var s := Vector2(slip_speed_x, -vy)
		bristle += s * dt
		var fmax := tire.peak_force(fz, mu_scale)
		var fv := bristle * kb + s * cb
		var mag := fv.length()
		if mag > fmax:
			fv *= fmax / mag
			bristle = (fv - s * cb) / kb
			var bl := bristle.length()
			if bl > fmax / kb * 1.5:
				bristle *= fmax / kb * 1.5 / bl
			k_s = 0.0
		else:
			k_s = R * R * (cb + kb * dt)
		fx_s = fv.x
		fy_s = fv.y
	else:
		bristle = Vector2(fx_m, fy_m) / maxf(kb, 1.0)
	fx = lerpf(fx_m, fx_s, w_stick)
	fy = lerpf(fy_m, fy_s, w_stick)
	torque_k = lerpf(k_m, k_s, w_stick)
	torque_tire = -R * fx
	sliding = absf(kappa) > tire.kappa_peak * 1.5 or absf(alpha) > tire.alpha_peak * 1.5


func world_force() -> Vector3:
	return f_fwd * fx + f_right * fy + contact_normal * fz
