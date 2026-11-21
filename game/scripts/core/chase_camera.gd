class_name ChaseCamera
extends Camera3D
## Simple spring chase camera for the test track and screenshots (the real camera system comes in Phase 4).
## mode: "chase" (behind, follows the heading blended with the velocity), "side" (fixed offset to the right),
## "top" (high above), "front34".

@export var target: Node3D
@export var mode := "chase"
@export var distance := 7.5
@export var height := 2.4
var _pos_smooth := Vector3.ZERO
var _dir_smooth := Vector3(0, 0, -1)


func _ready() -> void:
	fov = 62.0
	current = true


func _physics_process(dt: float) -> void:
	if target == null:
		return
	var tp := target.global_position
	var fwd := -target.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var vel := Vector3.ZERO
	if target is RigidBody3D:
		vel = (target as RigidBody3D).linear_velocity
		vel.y = 0.0
	var dir := fwd
	if vel.length() > 5.0:
		dir = fwd.lerp(vel.normalized(), 0.45).normalized()
	_dir_smooth = _dir_smooth.lerp(dir, 1.0 - exp(-dt * 4.0)).normalized()
	var want := tp
	var look := tp + Vector3(0, 0.6, 0)
	match mode:
		"side":
			var right := _dir_smooth.cross(Vector3.UP)
			want = tp + right * 7.0 + Vector3(0, 1.4, 0) - _dir_smooth * 1.5
		"top":
			want = tp + Vector3(0, 28.0, 0) + _dir_smooth * -4.0
			look = tp
		"front34":
			var right2 := _dir_smooth.cross(Vector3.UP)
			want = tp + _dir_smooth * 6.5 + right2 * 3.5 + Vector3(0, 1.3, 0)
		_:
			want = tp - _dir_smooth * distance + Vector3(0, height, 0)
	_pos_smooth = want if _pos_smooth == Vector3.ZERO else _pos_smooth.lerp(want, 1.0 - exp(-dt * 8.0))
	global_position = _pos_smooth
	look_at(look, Vector3.UP)
