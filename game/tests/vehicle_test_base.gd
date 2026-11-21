extends "res://tests/test_case.gd"
## Shared helpers for the vehicle tests: world + car spawning, scripted driver controllers.

var world: Node3D
var car: Vehicle

func make_world(extent: float = 1200.0) -> Node3D:
	world = Node3D.new()
	tree.root.add_child(world)
	TestWorld.add_ground(world, extent)
	return world

func spawn(pos: Vector3 = Vector3(0, 0.02, 0), yaw_deg: float = 0.0, speed_ms: float = 0.0, setup: Callable = Callable()) -> Vehicle:
	car = Vehicle.new()
	car.build_visual = false
	if setup.is_valid():
		setup.call(car)
	world.add_child(car)
	var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), pos)
	car.reset_to(xf, -xf.basis.z * speed_ms)
	return car

func cleanup() -> void:
	if world != null:
		world.queue_free()
		world = null
	car = null

func run_seconds(t: float, input: Callable = Callable()) -> void:
	var n := int(round(t * 240.0))
	for i in n:
		if input.is_valid():
			input.call(i / 240.0)
		await tree.physics_frame

## settle on flat ground with no input
func settle(t: float = 1.5) -> void:
	await run_seconds(t, func(_t): car.drive(0, 0, 0, 0))

## keep long straight runs inside the finite ground: teleport the car back by `shift` metres along Z
func wrap_z(limit: float = 400.0) -> void:
	var z := car.global_position.z
	if z < -limit:
		car.global_position += Vector3(0, 0, 2.0 * limit)
	elif z > limit:
		car.global_position -= Vector3(0, 0, 2.0 * limit)

func yaw_of(c: Vehicle) -> float:
	return atan2(c.global_basis.z.x, c.global_basis.z.z)   # heading about +Y, 0 = driving along -Z

func speed_kmh() -> float:
	return car.fwd_speed * 3.6

# ---- driver models --------------------------------------------------------------------------------------------

## pure pursuit steering angle (rad, + = left) towards a world point (x,z)
static func pursuit(c: Vehicle, target: Vector3) -> float:
	var local := c.global_transform.affine_inverse() * target
	var ld := maxf(Vector2(local.x, local.z).length(), 0.5)
	var alpha := atan2(-local.x, -local.z)      # + = target is to the left
	return atan2(2.0 * c.params.wheelbase * sin(alpha), ld)

## point on a circle (centre cx,cz radius r) ahead of the car by arc length ld, driving counter-clockwise seen from +Y
## when the centre is to the left of the car.
static func circle_target(c: Vehicle, centre: Vector3, r: float, ld: float, left: bool = true) -> Vector3:
	var rel := c.global_position - centre
	var th := atan2(rel.z, rel.x)
	var dir := -1.0 if left else 1.0          # heading -Z at the start: theta decreases for a left turn about a centre at -X
	th += dir * ld / r
	return centre + Vector3(cos(th), 0.0, sin(th)) * r

## simple speed controller: returns Vector2(throttle, brake)
static func speed_control(c: Vehicle, target_ms: float, kp: float = 0.35) -> Vector2:
	var e := target_ms - c.fwd_speed
	if e >= 0.0:
		return Vector2(clampf(kp * e, 0.0, 1.0), 0.0)
	return Vector2(0.0, clampf(-kp * e * 0.6, 0.0, 1.0))
