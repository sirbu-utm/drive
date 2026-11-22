class_name GhostCar
extends Node3D
## Semi-transparent copy of the car that replays a recorded lap. Samples are 19 floats at 60 Hz:
##   pos(3) quat(4) then for each wheel FL FR RL RR: suspension compression, steer, spin angle.

const STRIDE := 19
const RATE := 60.0
const WHEEL_NAMES := ["FL", "FR", "RL", "RR"]

var data := PackedFloat32Array()
var _knuckles: Array[Node3D] = []
var _wheel_nodes: Array[Node3D] = []
var _rest: Array[Vector3] = []
var _model: Node3D


func build(car_scene: PackedScene, rest_positions: Array[Vector3]) -> void:
	_rest = rest_positions
	_model = car_scene.instantiate() as Node3D
	add_child(_model)
	for i in 4:
		var k := Node3D.new()
		k.name = "GKnuckle_" + WHEEL_NAMES[i]
		add_child(k)
		k.position = _rest[i]
		_knuckles.append(k)
		var wn: Node3D = _model.get_wheel(WHEEL_NAMES[i]) if _model.has_method("get_wheel") else null
		if wn != null:
			wn.reparent(k, false)
			wn.position = Vector3.ZERO
		_wheel_nodes.append(wn)
		var cn: Node3D = _model.get_caliper(WHEEL_NAMES[i]) if _model.has_method("get_caliper") else null
		if cn != null:
			cn.reparent(k, false)
			cn.position = Vector3.ZERO
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	mat.albedo_color = Color(0.45, 0.75, 1.0, 0.34)
	mat.emission_enabled = true
	mat.emission = Color(0.15, 0.45, 0.95)
	mat.emission_energy_multiplier = 0.8
	mat.roughness = 0.5
	mat.rim_enabled = true
	mat.rim = 1.0
	mat.rim_tint = 0.3
	_apply(self, mat)
	visible = false


func _apply(n: Node, mat: Material) -> void:
	if n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		g.material_override = mat
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	elif n is Light3D:
		(n as Light3D).visible = false
	for c in n.get_children():
		_apply(c, mat)


func set_data(d: PackedFloat32Array) -> void:
	data = d
	visible = false


func duration() -> float:
	return float(data.size() / STRIDE - 1) / RATE if data.size() >= STRIDE * 2 else 0.0


## pose the ghost at lap time t (seconds); hides it past the end of the recording
func show_at(t: float) -> void:
	var n := data.size() / STRIDE
	if n < 2 or t < 0.0:
		visible = false
		return
	var f := t * RATE
	var i := int(f)
	if i >= n - 1:
		visible = false
		return
	var a := f - float(i)
	var o0 := i * STRIDE
	var o1 := o0 + STRIDE
	var p0 := Vector3(data[o0], data[o0 + 1], data[o0 + 2])
	var p1 := Vector3(data[o1], data[o1 + 1], data[o1 + 2])
	var q0 := Quaternion(data[o0 + 3], data[o0 + 4], data[o0 + 5], data[o0 + 6])
	var q1 := Quaternion(data[o1 + 3], data[o1 + 4], data[o1 + 5], data[o1 + 6])
	global_transform = Transform3D(Basis(q0.slerp(q1, a)), p0.lerp(p1, a))
	for w in 4:
		var b := 7 + w * 3
		var comp := lerpf(data[o0 + b], data[o1 + b], a)
		var steer := lerpf(data[o0 + b + 1], data[o1 + b + 1], a)
		var spin := lerpf(data[o0 + b + 2], data[o1 + b + 2], a)
		_knuckles[w].position = _rest[w] + Vector3.UP * comp
		_knuckles[w].rotation = Vector3(0.0, steer, 0.0)
		if _wheel_nodes[w] != null:
			_wheel_nodes[w].rotation = Vector3(-fposmod(spin, TAU), 0.0, 0.0)
	visible = true


## append one sample of `car` to `buf`
static func record(buf: PackedFloat32Array, car: Vehicle) -> void:
	var xf := car.global_transform
	var q := xf.basis.get_rotation_quaternion()
	buf.append(xf.origin.x)
	buf.append(xf.origin.y)
	buf.append(xf.origin.z)
	buf.append(q.x)
	buf.append(q.y)
	buf.append(q.z)
	buf.append(q.w)
	for w in car.wheels:
		buf.append(w.comp)
		buf.append(w.steer)
		buf.append(w.spin_angle)
