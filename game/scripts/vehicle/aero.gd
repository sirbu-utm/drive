class_name Aero
extends RefCounted
## Drag + downforce. Downforce is split between a front point and a rear (wing) point.

var p: VehicleParams
var drag_n := 0.0
var downforce_n := 0.0
var front_df := 0.0
var rear_df := 0.0


func _init(params: VehicleParams) -> void:
	p = params


## v: world velocity, xf: chassis transform. Returns a list of [force_world, point_world] pairs.
func compute(v: Vector3, xf: Transform3D) -> Array:
	var speed := v.length()
	var q := 0.5 * p.air_density * speed * speed
	drag_n = q * p.cda
	downforce_n = q * p.cla
	front_df = downforce_n * p.aero_front_share
	rear_df = downforce_n - front_df
	var out := []
	if speed > 0.01:
		var drag_dir := -v / speed
		out.append([drag_dir * drag_n, xf * Vector3(0.0, p.drag_point_height, 0.0)])
	var down := -xf.basis.y
	out.append([down * front_df, xf * p.aero_front_point])
	out.append([down * rear_df, xf * p.aero_rear_point])
	return out
