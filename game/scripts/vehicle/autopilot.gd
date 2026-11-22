class_name Autopilot
extends RefCounted
## Path-following driver for tests and demos: pure pursuit on a road lane (RoadNet) with a speed profile derived from
## the path curvature (lateral g limit, braking distance look-ahead, stop at the end of open roads).

var net: RoadNet
var road: Dictionary
var path := PackedVector3Array()       # lane points in travel order
var vlim := PackedFloat32Array()       # speed limit per sample (m/s)
var closed := false
var m := 0                             # samples in the loop (closed) / path length (open)
var i_cur := 0                         # unwrapped progress index
var start_index := 0

var vmax := 80.0                       # m/s cap
var lat_g := 0.8                       # lateral acceleration budget (in g) for the corner speed
var brake_decel := 7.5                 # m/s^2 used for the braking look-ahead
var lane_frac := 0.25
var stop_at_end := true
var lap_done := false
var finished := false
var lookahead_min := 6.0
var lookahead_gain := 0.40
var spacing := 2.0

var cte := 0.0                         # cross-track error (m, + = car is left of the path)
var max_cte := 0.0
var v_target := 0.0


func _init(road_net: RoadNet, road_name: String, dir: int = 1, start_i: int = 0, speed_cap: float = 80.0, lateral_g: float = 0.8) -> void:
	net = road_net
	road = net.get_road(road_name)
	vmax = speed_cap
	lat_g = lateral_g
	closed = road["closed"]
	var n: int = road["pts"].size()
	m = n - 1 if closed else n
	for k in m:
		var j := k if dir > 0 else (m - 1 - k) if not closed else posmod(-k, m)
		path.append(net.lane_point(road, j, dir, lane_frac))
	if dir < 0 and not closed:
		pass
	start_index = start_i
	i_cur = start_i
	_build_speed_profile()


func _at(i: int) -> Vector3:
	if closed:
		return path[posmod(i, m)]
	return path[clampi(i, 0, m - 1)]


func _build_speed_profile() -> void:
	vlim.resize(m)
	var kap := PackedFloat32Array()
	kap.resize(m)
	for k in m:
		var a := _at(k - 2)
		var b := _at(k)
		var c := _at(k + 2)
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var bc := Vector2(c.x - b.x, c.z - b.z)
		var l1 := ab.length()
		var l2 := bc.length()
		if l1 < 0.01 or l2 < 0.01:
			kap[k] = 0.0
			continue
		var ang := absf(ab.angle_to(bc))
		kap[k] = 2.0 * sin(ang * 0.5) / (0.5 * (l1 + l2)) * 1.0
	# smooth the curvature a little (5 samples) and convert to a speed
	for k in m:
		var s := 0.0
		for d in range(-3, 4):
			s = maxf(s, kap[posmod(k + d, m)] if closed else kap[clampi(k + d, 0, m - 1)])
		var v := sqrt(lat_g * 9.81 / maxf(s, 1e-4))
		vlim[k] = minf(v, vmax)
	if not closed and stop_at_end:
		vlim[m - 1] = 0.0


func is_done() -> bool:
	return finished


## returns Vector3(throttle, brake, steer_angle_rad)
func update(car: Vehicle) -> Vector3:
	var pos := car.global_position
	# track progress (window search ahead of the current index)
	var best_i := i_cur
	var best_d := 1e18
	for k in range(-6, 50):
		var i := i_cur + k
		if not closed and (i < 0 or i >= m):
			continue
		var p := _at(i)
		var dx := p.x - pos.x
		var dz := p.z - pos.z
		var d2 := dx * dx + dz * dz
		if d2 < best_d:
			best_d = d2
			best_i = i
	i_cur = maxi(best_i, i_cur - 3)
	if closed:
		if i_cur - start_index >= m:
			finished = true
	elif i_cur >= m - 3 and stop_at_end:
		if car.speed < 1.0:
			finished = true
		elif i_cur >= m - 1:
			pass
	# cross track error
	var p0 := _at(i_cur)
	var p1 := _at(i_cur + 1)
	var t := Vector2(p1.x - p0.x, p1.z - p0.z).normalized()
	var rel := Vector2(pos.x - p0.x, pos.z - p0.z)
	# left of travel direction in (x,z) with y up: left = (t.y, -t.x)? travelling -Z (t = (0,-1)): left = -X => (t.y... )
	cte = rel.dot(Vector2(t.y, -t.x))
	max_cte = maxf(max_cte, absf(cte))
	# pure pursuit
	var v := maxf(car.speed, 0.0)
	var ld := clampf(lookahead_min + lookahead_gain * v, lookahead_min, 50.0)
	var k_ahead := int(round(ld / spacing))
	var target := _at(i_cur + k_ahead)
	var local := car.global_transform.affine_inverse() * target
	var dist := maxf(Vector2(local.x, local.z).length(), 0.5)
	var alpha := atan2(-local.x, -local.z)
	var steer := clampf(atan2(2.0 * car.params.wheelbase * sin(alpha), dist), -0.6, 0.6)
	# speed profile with braking look-ahead
	var vt := vmax
	var kmax := int(350.0 / spacing)
	for k in range(0, kmax):
		var i := i_cur + k
		if not closed and i >= m:
			break
		var allowed := sqrt(maxf(vlim[posmod(i, m)] if closed else vlim[i], 0.0) * (vlim[posmod(i, m)] if closed else vlim[i]) + 2.0 * brake_decel * float(k) * spacing)
		vt = minf(vt, allowed)
	v_target = vt
	var e := vt - car.fwd_speed
	var thr := clampf(0.35 * e, 0.0, 1.0)
	var brk := clampf(-0.25 * (e + 0.8), 0.0, 1.0)
	if e > -0.8:
		brk = 0.0
	return Vector3(thr, brk, steer)
