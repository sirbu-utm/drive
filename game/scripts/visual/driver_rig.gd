extends Node3D
class_name DriverRig
## Driver in the cockpit: rotating steering wheel, two-bone IK arms with gloves gripping the rim, torso and
## helmet (hidden when the camera is inside the head, i.e. cockpit cam). Car frame: forward -Z, up +Y.
## Updated in _physics_process because everything here is a child of the physics-interpolated car body.

const STEER_RATIO := 9.0                    # steering-wheel turns per front-wheel angle (race-car quick rack)
const UPPER := 0.29
const FORE := 0.28
const EYE := Vector3(-0.30, 0.90, -0.12)
const GRIP_UP_DEG := 15.0                   # hands at "quarter to three"

var vehicle: Node
var wheel_node: Node3D
var wheel_rest: Basis
var center := Vector3(-0.297, 0.678, -0.457)
var axis := Vector3(0.0, 0.211, 0.977)
var radius := 0.18
var r0 := Vector3.RIGHT
var u0 := Vector3.UP
var angle := 0.0

var _arms := {}          # side -> {upper, fore, hand, shoulder}
var _head: Node3D
var _torso: MeshInstance3D


func setup(model: Node3D, meta: Dictionary) -> void:
	var sw: Dictionary = meta.get("steering_wheel", {})
	if sw.has("center"):
		center = Vector3(sw.center[0], sw.center[1], sw.center[2])
		axis = Vector3(sw.axis[0], sw.axis[1], sw.axis[2]).normalized()
		radius = float(sw.radius)
	wheel_node = model.find_child("SteeringWheel", true, false) as Node3D
	if wheel_node:
		wheel_rest = wheel_node.basis
	r0 = (Vector3.RIGHT - axis * axis.dot(Vector3.RIGHT)).normalized()
	u0 = axis.cross(r0).normalized()
	if u0.y < 0.0:
		u0 = -u0
	_build_body()


func _ready() -> void:
	var n: Node = get_parent()
	while n != null:
		if n.get_class() == "RigidBody3D" and n.get("wheels") != null:
			vehicle = n
			break
		n = n.get_parent()


func _mat(c: Color, rough: float, extra := {}) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	for k in extra:
		m.set(k, extra[k])
	return m


func _capsule(r: float, length: float, mat: Material) -> MeshInstance3D:
	var cm := CapsuleMesh.new()
	cm.radius = r
	cm.height = length + 2.0 * r
	cm.radial_segments = 16
	cm.rings = 6
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = mat
	add_child(mi)
	return mi


func _build_body() -> void:
	var suit := _mat(Color(0.05, 0.07, 0.13), 0.92)
	var suit_accent := _mat(Color(0.06, 0.06, 0.07), 0.7)
	var glove := _mat(Color(0.025, 0.025, 0.028), 0.5, {"clearcoat_enabled": true, "clearcoat": 0.3})
	for side in [-1.0, 1.0]:
		var shoulder := EYE + Vector3(0.19 * side, -0.21, 0.11)
		var upper := _capsule(0.052, UPPER, suit)
		var fore := _capsule(0.043, FORE, suit)
		var cuff := _capsule(0.047, 0.035, suit_accent)
		var hand := _capsule(0.036, 0.075, glove)
		var thumb := _capsule(0.015, 0.035, glove)
		_arms[side] = {"upper": upper, "fore": fore, "cuff": cuff, "hand": hand, "thumb": thumb, "shoulder": shoulder}
	_torso = _capsule(0.17, 0.32, suit)
	_torso.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-12.0)), EYE + Vector3(0, -0.42, 0.16))
	_head = Node3D.new()
	add_child(_head)
	_head.position = EYE + Vector3(0, 0.02, 0.05)
	var helmet := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.135
	sm.height = 0.27
	helmet.mesh = sm
	helmet.material_override = _mat(Color(0.92, 0.92, 0.94), 0.2, {"clearcoat_enabled": true, "clearcoat": 1.0, "metallic": 0.1})
	_head.add_child(helmet)
	var visor := MeshInstance3D.new()
	var vm := SphereMesh.new()
	vm.radius = 0.138
	vm.height = 0.15
	visor.mesh = vm
	visor.position = Vector3(0, 0.0, -0.01)
	visor.scale = Vector3(0.92, 0.6, 1.0)
	visor.material_override = _mat(Color(0.02, 0.02, 0.03), 0.05, {"metallic": 0.8})
	_head.add_child(visor)


## orient a capsule (axis +Y) between two points
func _place(mi: Node3D, a: Vector3, b: Vector3, roll_hint: Vector3 = Vector3.FORWARD) -> void:
	var d := b - a
	var len := d.length()
	if len < 1e-4:
		return
	var y := d / len
	var x := roll_hint.cross(y)
	if x.length() < 1e-3:
		x = Vector3.RIGHT.cross(y)
	x = x.normalized()
	var z := x.cross(y).normalized()
	mi.transform = Transform3D(Basis(x, y, z), (a + b) * 0.5)


func _ik(shoulder: Vector3, target: Vector3, pole: Vector3) -> Vector3:
	var to := target - shoulder
	var d := clampf(to.length(), 0.05, UPPER + FORE - 0.005)
	var dir := to.normalized()
	var a := (UPPER * UPPER - FORE * FORE + d * d) / (2.0 * d)
	var h := sqrt(maxf(UPPER * UPPER - a * a, 0.0))
	var bend := (pole - dir * pole.dot(dir)).normalized()
	return shoulder + dir * a + bend * h


func _physics_process(_dt: float) -> void:
	var steer := 0.0
	if vehicle and vehicle.wheels.size() >= 2:
		steer = 0.5 * (float(vehicle.wheels[0].steer) + float(vehicle.wheels[1].steer))
	angle = clampf(steer * STEER_RATIO, -deg_to_rad(200.0), deg_to_rad(200.0))
	var rot := Basis(axis, angle)
	if wheel_node:
		wheel_node.basis = rot * wheel_rest
	var up := deg_to_rad(GRIP_UP_DEG)
	for side in _arms:
		var s: float = side
		var arm: Dictionary = _arms[side]
		var grip_dir: Vector3 = rot * (r0 * (s * cos(up)) + u0 * sin(up))
		var grip := center + grip_dir * radius
		var shoulder: Vector3 = arm.shoulder
		var pole := Vector3(1.0 * s, -1.3, 0.35).normalized()
		var elbow := _ik(shoulder, grip, pole)
		_place(arm.upper, shoulder, elbow)
		_place(arm.fore, elbow, grip - (grip - elbow).normalized() * 0.03)
		var fdir := (grip - elbow).normalized()
		_place(arm.cuff, grip - fdir * 0.09, grip - fdir * 0.05)
		# fist wraps the rim: oriented along the rim tangent, centred on the grip point
		var tangent: Vector3 = axis.cross(grip_dir).normalized()
		_place(arm.hand, grip - tangent * 0.04, grip + tangent * 0.04, fdir)
		_place(arm.thumb, grip + axis * 0.03 - tangent * 0.02, grip + axis * 0.03 + tangent * 0.02, fdir)


func _process(_dt: float) -> void:
	# hide head + torso when the active camera sits inside them (cockpit view)
	var cam := get_viewport().get_camera_3d()
	if cam and _head:
		var inside := cam.global_position.distance_to(_head.global_position) < 0.32
		_head.visible = not inside
		_torso.visible = not inside
