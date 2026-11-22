class_name RoadNet
extends RefCounted
## Road centrelines from res://assets/world/gen/roads.json (points every 2 m, widths, closed flag).
## Used by respawn (R), the autopilot used in tests, and the minimap.

const ROADS_JSON := "res://assets/world/gen/roads.json"

var roads: Array = []                    # Dictionary: name, kind, closed, paved, surface, pts (PackedVector3Array), width (PackedFloat32Array), s (PackedFloat32Array, arc length)
var world_size := 4096.0
var origin := Vector2(-2048.0, -2048.0)


func _init(path: String = ROADS_JSON) -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	world_size = float(meta.get("size", 4096))
	var o: Array = meta.get("origin", [-2048.0, -2048.0])
	origin = Vector2(float(o[0]), float(o[1]))
	for r in meta["roads"]:
		var pts := PackedVector3Array()
		var s := PackedFloat32Array()
		var acc := 0.0
		for i in r["points"].size():
			var p: Array = r["points"][i]
			var v := Vector3(float(p[0]), float(p[1]), float(p[2]))
			if i > 0:
				acc += v.distance_to(pts[i - 1])
			pts.append(v)
			s.append(acc)
		var w := PackedFloat32Array()
		for x in r["width"]:
			w.append(float(x))
		roads.append({"name": r["name"], "kind": r["kind"], "closed": bool(r["closed"]), "paved": bool(r["paved"]),
			"surface": r["surface"], "pts": pts, "width": w, "s": s, "length": acc})


func get_road(name: String) -> Dictionary:
	for r in roads:
		if r["name"] == name:
			return r
	return {}


## Wrap / clamp a sample index for a road.
func idx(road: Dictionary, i: int) -> int:
	var n: int = road["pts"].size()
	if road["closed"]:
		# the closed loop repeats the first point at the end
		var m := n - 1
		return posmod(i, m)
	return clampi(i, 0, n - 1)


## Unit tangent (horizontal-ish, along increasing index) at sample i.
func tangent(road: Dictionary, i: int) -> Vector3:
	var a: Vector3 = road["pts"][idx(road, i - 1)]
	var b: Vector3 = road["pts"][idx(road, i + 1)]
	return (b - a).normalized()


## Position on the lane. dir = +1 travelling with increasing index, -1 against. Right-hand traffic.
func lane_point(road: Dictionary, i: int, dir: int = 1, lane_frac: float = 0.25) -> Vector3:
	var j := idx(road, i)
	var p: Vector3 = road["pts"][j]
	var t := tangent(road, j) * float(dir)
	var right := t.cross(Vector3.UP).normalized()
	return p + right * float(road["width"][j]) * lane_frac


## Transform for a car travelling on the right lane, facing along the road.
func lane_pose(road: Dictionary, i: int, dir: int = 1, lift: float = 0.5, lane_frac: float = 0.25) -> Transform3D:
	var t := tangent(road, idx(road, i)) * float(dir)
	var fwd := Vector3(t.x, 0.0, t.z).normalized()
	var pos := lane_point(road, i, dir, lane_frac) + Vector3(0, lift, 0)
	# pitch with the road slope
	var basis := Basis.looking_at(t, Vector3.UP)
	return Transform3D(basis, pos)


## Nearest paved road sample to a world position. Returns {road, i, dist, dir} where dir is the travel direction
## (+1/-1) that best matches `heading` (a world forward vector; pass ZERO to get +1).
func nearest(pos: Vector3, heading: Vector3 = Vector3.ZERO, paved_only: bool = true) -> Dictionary:
	var best := {"road": {}, "i": 0, "dist": 1e18, "dir": 1}
	for r in roads:
		if paved_only and not r["paved"]:
			continue
		var pts: PackedVector3Array = r["pts"]
		for i in pts.size():
			var p := pts[i]
			var dx := p.x - pos.x
			var dz := p.z - pos.z
			var d2 := dx * dx + dz * dz
			if d2 < best["dist"]:
				best["dist"] = d2
				best["road"] = r
				best["i"] = i
	best["dist"] = sqrt(best["dist"])
	if not best["road"].is_empty():
		var t := tangent(best["road"], best["i"])
		best["dir"] = 1 if heading == Vector3.ZERO or t.dot(heading) >= 0.0 else -1
	return best


## Search a window around hint for the nearest sample of a given road (cheap tracking). Returns index (unwrapped).
func track(road: Dictionary, pos: Vector3, hint: int, window: int = 60) -> int:
	var best_i := hint
	var best_d := 1e18
	for k in range(-window / 4, window + 1):
		var i := hint + k
		var p: Vector3 = road["pts"][idx(road, i)]
		var dx := p.x - pos.x
		var dz := p.z - pos.z
		var d2 := dx * dx + dz * dz
		if d2 < best_d:
			best_d = d2
			best_i = i
	return best_i
