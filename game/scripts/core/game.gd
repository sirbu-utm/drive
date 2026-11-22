class_name Game
extends Node3D
## Main scene: the open world + the player's CCGT + camera system + HUD.
##   WASD/arrows drive, Space handbrake, C camera, R respawn on the nearest road, F1 telemetry, F2-F6 assists/gearbox.
## Command line (after --):  --hour=17  --cam=<0..4>  --pos=x,y,z --yaw=deg (start somewhere else)  --road=ring|mountain_pass|runway --idx=N
##   --autopilot=<road>   drive by the Autopilot (demos / screenshots)   --speed=m/s (autopilot cap)

const WORLD_SCENE := "res://scenes/world/world.scn"
const CAR_VISUAL := "res://assets/cars/ccgt/ccgt_visual.tscn"
const CAR_META := "res://assets/cars/ccgt/ccgt_meta.json"

var world: Node3D
var car: Vehicle
var rig: CameraRig
var controller: PlayerController
var overlay: TelemetryOverlay
var hud: HUD
var net: RoadNet
var autopilot: Autopilot
var args := {}


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := (a as String).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"


func _ready() -> void:
	_parse_args()
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_4X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	net = RoadNet.new()
	car = Vehicle.new()
	car.name = "Player"
	car.car_scene = load(CAR_VISUAL)
	car.meta_path = CAR_META
	# camera first: Terrain3D looks for an active camera when it enters the tree
	rig = CameraRig.new()
	rig.name = "CameraRig"
	rig.vehicle = car
	add_child(rig)
	world = (load(WORLD_SCENE) as PackedScene).instantiate()
	world.start_hour = float(args.get("hour", str(world.start_hour)))
	world.get_node("Terrain3D").clipmap_target = rig.camera
	add_child(world)
	add_child(car)
	_place_start()
	world.set_focus(car)
	if args.has("cam"):
		rig.set_mode(int(args["cam"]))
	overlay = TelemetryOverlay.new()
	overlay.vehicle = car
	add_child(overlay)
	hud = HUD.new()
	hud.vehicle = car
	add_child(hud)
	rig.mode_changed.connect(func(n: String): hud.show_toast(n))
	if args.has("autopilot"):
		autopilot = Autopilot.new(net, String(args["autopilot"]), 1, int(args.get("idx", "20")), float(args.get("speed", "45")), 0.7)
	else:
		controller = PlayerController.new()
		controller.vehicle = car
		controller.reset_requested.connect(respawn)
		controller.telemetry_toggled.connect(overlay.toggle)
		controller.assist_changed.connect(func(n: String, on: bool): hud.show_toast("%s: %s" % [n, "вкл" if on else "выкл"]))
		add_child(controller)


func _place_start() -> void:
	var xf: Transform3D
	if args.has("road"):
		var road := net.get_road(String(args["road"]))
		xf = net.lane_pose(road, int(args.get("idx", "20")), 1, 0.5)
	elif args.has("pos"):
		var p := String(args["pos"]).split(",")
		xf = Transform3D(Basis(Vector3.UP, deg_to_rad(float(args.get("yaw", "0")))), Vector3(float(p[0]), float(p[1]), float(p[2])))
	else:
		xf = world.get_spawn(0)
	_teleport(xf)


func _teleport(xf: Transform3D, vel: Vector3 = Vector3.ZERO) -> void:
	car.reset_to(xf, vel)
	car.reset_physics_interpolation()
	if rig:
		rig._have_pos = false


## R: put the car on the nearest road sample, right lane, facing the way it was heading.
func respawn() -> void:
	var heading := -car.global_basis.z
	var n := net.nearest(car.global_position, heading)
	if n["road"].is_empty():
		_teleport(world.get_spawn(0))
		return
	var xf := net.lane_pose(n["road"], n["i"], n["dir"], 0.5)
	_teleport(xf)
	if hud:
		hud.show_toast("Возврат на дорогу")


func _physics_process(_dt: float) -> void:
	if autopilot != null:
		var c := autopilot.update(car)
		car.drive(c.x, c.y, c.z)
