extends Node3D
## World look-dev / screenshot scene (Opus visual QA).
##   SHOT_EXTRA="-- --view=coast --hour=17 --car=1" scripts/shot.sh scenes/world/world_preview.tscn out.png 120
## Views are picked on the roads so the shots show real driving spots.

var world: Node3D
var cam: Camera3D
var args := {}
var car: Node3D

## name: [road name, fraction along road, camera back (m), camera height (m), side offset (m), look-ahead (m), fov]
const VIEWS := {
	"coast": ["ring", 0.12, 14.0, 3.0, -4.0, 25.0, 55.0],
	"highway": ["ring", 0.33, 16.0, 3.5, 3.0, 60.0, 50.0],
	"north": ["ring", 0.62, 12.0, 3.2, -3.0, 30.0, 55.0],
	"pass_low": ["mountain_pass", 0.12, 25.0, 12.0, 15.0, 20.0, 55.0],
	"pass_hairpin": ["mountain_pass", 0.3, 40.0, 30.0, 25.0, 10.0, 55.0],
	"pass_top": ["mountain_pass", 0.62, 18.0, 5.0, -6.0, 40.0, 55.0],
	"runway": ["runway", 0.2, 30.0, 6.0, 12.0, 120.0, 50.0],
	"west": ["ring", 0.86, 14.0, 3.0, 4.0, 30.0, 55.0],
}


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := (a as String).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"


func _ready() -> void:
	_parse_args()
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_4X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	vp.anisotropic_filtering_level = Viewport.ANISOTROPY_16X
	RenderingServer.directional_shadow_atlas_set_size(8192, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)

	world = (load("res://scenes/world/world.scn") as PackedScene).instantiate()
	world.start_hour = float(args.get("hour", "16.5"))
	add_child(world)

	cam = Camera3D.new()
	cam.far = 12000.0
	cam.near = 0.1
	add_child(cam)
	cam.current = true
	var attr := CameraAttributesPractical.new()
	attr.auto_exposure_enabled = true
	attr.auto_exposure_scale = 0.45
	attr.auto_exposure_speed = 20.0
	cam.attributes = attr
	_place_camera(args.get("view", "coast"))
	world.set_focus(cam)


func _road_points(name: String) -> Array:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/world/gen/roads.json"))
	for r in meta.roads:
		if r.name == name:
			return r.points
	return []


func _place_camera(view: String) -> void:
	if args.has("pos"):
		var p: PackedStringArray = (args["pos"] as String).split(",")
		var l: PackedStringArray = (args.get("look", "0,0,0") as String).split(",")
		cam.fov = float(args.get("fov", "55"))
		cam.look_at_from_position(Vector3(float(p[0]), float(p[1]), float(p[2])), Vector3(float(l[0]), float(l[1]), float(l[2])), Vector3.UP)
		return
	if view == "overview":
		cam.fov = 60.0
		cam.look_at_from_position(Vector3(-2600, 1300, 2600), Vector3(0, 0, 0), Vector3.UP)
		return
	if view == "overview_n":
		cam.fov = 55.0
		cam.look_at_from_position(Vector3(200, 600, 600), Vector3(200, 120, -1500), Vector3.UP)
		return
	var v: Array = VIEWS.get(view, VIEWS["coast"])
	var pts := _road_points(v[0])
	var k := int(float(v[1]) * (pts.size() - 1))
	var p := Vector3(pts[k][0], pts[k][1], pts[k][2])
	var q := Vector3(pts[mini(k + 3, pts.size() - 1)][0], pts[mini(k + 3, pts.size() - 1)][1], pts[mini(k + 3, pts.size() - 1)][2])
	var fwd := (q - p).normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var eye: Vector3 = p - fwd * float(v[2]) + Vector3.UP * float(v[3]) + right * float(v[4])
	var target: Vector3 = p + fwd * float(v[5]) + Vector3.UP * 1.0
	cam.fov = float(v[6])
	cam.look_at_from_position(eye, target, Vector3.UP)
	if args.get("car", "0") == "1":
		car = (load("res://assets/cars/ccgt/ccgt_visual.tscn") as PackedScene).instantiate()
		add_child(car)
		var half := 2.2
		car.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), p + right * half + Vector3.UP * 0.0)
