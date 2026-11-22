extends Node3D
## Look-dev for impostors: one tree (and a row) on a plane. -- --tree=island_tree_01 --dist=12 --el=5
var args := {}

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := (a as String).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var rig := SkyRig.new()
	rig.rotation_rad = deg_to_rad(35)
	add_child(rig)
	rig.set_time(float(args.get("hour", "15")))
	var builder = load("res://scripts/world/build_world.gd").new()
	var d: Dictionary = builder._impostor(args.get("tree", "island_tree_01"))
	print("IMPTEST loaded=", not d.is_empty())
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = d.mesh
	mm.instance_count = 7
	for i in 7:
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, i * 0.9), Vector3((i - 3) * 9.0, 0, -float(i % 2) * 12.0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	plane.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.25, 0.32, 0.15)
	plane.material_override = gm
	add_child(plane)
	var cam := Camera3D.new()
	add_child(cam)
	var dist := float(args.get("dist", "22"))
	var el := deg_to_rad(float(args.get("el", "4")))
	cam.look_at_from_position(Vector3(0, 2.5 + dist * sin(el), dist * cos(el)), Vector3(0, 2.5, -4), Vector3.UP)
	cam.fov = 55
	cam.current = true
	get_viewport().msaa_3d = Viewport.MSAA_4X
