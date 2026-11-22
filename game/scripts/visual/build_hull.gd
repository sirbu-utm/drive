extends SceneTree
## Builds res://assets/cars/ccgt/ccgt_hull.res: simplified convex hull of Body + Wing in the car frame
## (forward -Z, up +Y, origin on the ground between the axles). Run: scripts/godot.sh --headless --script res://scripts/visual/build_hull.gd
func _initialize() -> void:
	var root: Node3D = (load("res://assets/cars/ccgt/ccgt.glb") as PackedScene).instantiate()
	var pts := PackedVector3Array()
	for name in ["Body", "Wing", "Mirror_L", "Mirror_R"]:
		var mi := root.find_child(name, true, false) as MeshInstance3D
		if mi == null:
			continue
		var xf := _xf_to_root(mi, root)
		var shape := mi.mesh.create_convex_shape(true, true) as ConvexPolygonShape3D
		for p in shape.points:
			pts.append(xf * p)
	var hull := ConvexPolygonShape3D.new()
	hull.points = pts
	# re-hull the union (one convex piece), keep it light
	var am := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	am.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr)
	var final_shape := am.create_convex_shape(true, true) as ConvexPolygonShape3D
	if final_shape == null or final_shape.points.size() < 8:
		final_shape = hull
	# flat underside 12 cm above the ground: the body must not scrape before the tyres/suspension say so
	var lifted := PackedVector3Array()
	for p in final_shape.points:
		lifted.append(Vector3(p.x, maxf(p.y, 0.12), p.z))
	final_shape.points = lifted
	var mn := Vector3(1e9, 1e9, 1e9)
	var mx := -mn
	for p in final_shape.points:
		mn = mn.min(p)
		mx = mx.max(p)
	final_shape.margin = 0.02
	var err := ResourceSaver.save(final_shape, "res://assets/cars/ccgt/ccgt_hull.res")
	print("HULL points=", final_shape.points.size(), " bbox ", mn, " .. ", mx, " err=", err)
	root.free()
	quit(0)

func _xf_to_root(n: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D()
	var c: Node = n
	while c != null and c != root:
		xf = (c as Node3D).transform * xf
		c = c.get_parent()
	return xf
