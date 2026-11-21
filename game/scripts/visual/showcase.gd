extends Node3D
## Car showcase / look-dev scene (Opus visual QA). Builds everything in code so screenshots can be driven
## from the command line:
##   scripts/shot.sh scenes/showcase/car_showcase.tscn out.png 40 1920x1080   with
##   SHOT_EXTRA="-- --view=front34 --tod=late_afternoon --paint=0.62,0.035,0.03 --lights=1 --brake=1"
## Views: front34, rear34, side, front_low, wheel, top, night_front

var car: CarVisual
var cam: Camera3D
var rig: SkyRig
var args := {}

const VIEWS := {
	# position, target, fov
	"front34": [Vector3(-3.9, 1.25, -5.2), Vector3(0.0, 0.45, -0.1), 40.0],
	"rear34": [Vector3(4.2, 1.35, 5.4), Vector3(0.0, 0.5, 0.2), 40.0],
	"side": [Vector3(-7.5, 0.75, 0.0), Vector3(0.0, 0.5, 0.0), 35.0],
	"front_low": [Vector3(-1.4, 0.38, -4.6), Vector3(0.0, 0.45, -1.2), 55.0],
	"wheel": [Vector3(-2.6, 0.55, -3.2), Vector3(-0.8, 0.32, -1.35), 45.0],
	"top": [Vector3(-3.0, 6.5, -3.5), Vector3(0.0, 0.3, 0.0), 40.0],
	"far": [Vector3(-12.0, 2.5, -16.0), Vector3(0.0, 0.6, 0.0), 30.0],
}


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var s: String = a.trim_prefix("--")
		var kv := s.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"


func _ready() -> void:
	_parse_args()
	_setup_render()

	rig = SkyRig.new()
	rig.rotation_rad = deg_to_rad(float(args.get("sky_rot", "35")))
	rig.radiance_quality = true
	rig.shadow_max_distance = 60.0
	add_child(rig)
	if args.has("tod"):
		rig.set_keyframe(args["tod"])
	elif args.has("hour"):
		rig.set_time(float(args["hour"]))
	else:
		rig.set_keyframe("late_afternoon")

	_make_ground()

	car = CarVisual.new()
	add_child(car)
	if args.has("paint"):
		var p: PackedStringArray = (args["paint"] as String).split(",")
		car.set_paint(Color(float(p[0]), float(p[1]), float(p[2])))
	car.set_headlights(args.get("lights", "0") == "1")
	car.set_brake(float(args.get("brake", "0")))
	if args.has("heat"):
		for w in ["FL", "FR", "RL", "RR"]:
			car.set_disc_heat(w, float(args["heat"]))
	if args.has("dirt"):
		car.set_dirt(float(args["dirt"]))
	if args.has("steer"):
		var st := deg_to_rad(float(args["steer"]))
		for w in ["FL", "FR"]:
			car.get_wheel(w).rotate_y(st)
			car.get_caliper(w).rotate_y(st)

	cam = Camera3D.new()
	add_child(cam)
	var v: Array = VIEWS.get(args.get("view", "front34"), VIEWS["front34"])
	cam.fov = v[2]
	cam.look_at_from_position(v[0], v[1], Vector3.UP)
	cam.near = 0.05
	cam.far = 4000.0
	cam.current = true
	var attr := CameraAttributesPractical.new()
	attr.auto_exposure_enabled = args.get("autoexp", "1") == "1"
	attr.auto_exposure_scale = 0.45
	attr.auto_exposure_speed = 10.0
	attr.auto_exposure_min_sensitivity = 50.0
	attr.auto_exposure_max_sensitivity = 1600.0
	cam.attributes = attr


func _setup_render() -> void:
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_4X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	vp.use_debanding = true
	vp.anisotropic_filtering_level = Viewport.ANISOTROPY_16X
	vp.mesh_lod_threshold = 0.5
	RenderingServer.directional_shadow_atlas_set_size(8192, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	RenderingServer.positional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)


func _make_ground() -> void:
	var tex_dir := "res://assets/textures/asphalt_track/asphalt_track_"
	var m := ORMMaterial3D.new()
	m.albedo_texture = load(tex_dir + "diff_2k.jpg")
	m.normal_enabled = true
	m.normal_texture = load(tex_dir + "nor_gl_2k.jpg")
	m.normal_scale = 1.0
	m.orm_texture = load(tex_dir + "arm_2k.jpg")
	m.uv1_scale = Vector3(60, 60, 1)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.albedo_color = Color(0.74, 0.78, 0.84)
	var plane := PlaneMesh.new()
	plane.size = Vector2(240, 240)
	plane.subdivide_width = 4
	plane.subdivide_depth = 4
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = m
	add_child(mi)
