class_name Game
extends Node3D
## Main scene: the open world + the player's CCGT + camera system + HUD.
##   WASD/arrows drive, Space handbrake, C camera, R respawn on the nearest road, F1 telemetry, F2-F6 assists/gearbox.
## Started from scenes/main.tscn it opens the main menu (start_in_menu): the car drives itself around the ring behind it.
##   Esc = pause. Menus: scripts/ui/*, settings: GameSettings / GraphicsSettings autoloads, time trial: TimeTrial.
## Command line (after --):  --menu / --nomenu  --ui=main|settings|pause|trial_select  --tab=N  --trial=ring|mountain_pass  --bench=...
##   (older args below)  --hour=17  --cam=<0..4>  --pos=x,y,z --yaw=deg (start somewhere else)  --road=ring|mountain_pass|runway --idx=N
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
@export var start_in_menu := false
var mode := "free"                  # "menu" | "free" | "trial"
var menus: MenuManager
var trial: TimeTrial
var trial_hud: TrialHUD
var audio: VehicleAudio
var _hud_layer: CanvasLayer
var _free_cam := CameraRig.Mode.CHASE_NEAR
var headlights_manual := false        # L pressed: the player decides, otherwise automatic by the time of day
var _lights_on := false
var _lights_valid := false


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := (a as String).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"


func _ready() -> void:
	_parse_args()
	var menu_start := (start_in_menu or args.has("menu")) and not args.has("nomenu")
	net = RoadNet.new()
	car = Vehicle.new()
	car.name = "Player"
	car.car_scene = load(CAR_VISUAL)
	car.meta_path = CAR_META
	car.hull_path = "res://assets/cars/ccgt/ccgt_hull.res"
	# camera first: Terrain3D looks for an active camera when it enters the tree
	rig = CameraRig.new()
	rig.name = "CameraRig"
	rig.vehicle = car
	add_child(rig)
	world = (load(WORLD_SCENE) as PackedScene).instantiate()
	world.start_hour = float(args.get("hour", str(world.start_hour)))
	world.get_node("Terrain3D").clipmap_target = rig.camera
	add_child(world)
	GraphicsSettings.attach(world)
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
	audio = VehicleAudio.new()
	audio.name = "Audio"
	audio.vehicle = car
	audio.rig = rig
	car.add_child(audio)
	rig.mode_changed.connect(func(n: String): hud.show_toast(n))
	if args.has("autopilot"):
		autopilot = Autopilot.new(net, String(args["autopilot"]), 1, int(args.get("idx", "20")), float(args.get("speed", "45")), 0.7)
	if not args.has("autopilot") or menu_start or args.has("trial"):
		controller = PlayerController.new()
		controller.vehicle = car
		controller.reset_requested.connect(respawn)
		controller.telemetry_toggled.connect(overlay.toggle)
		controller.assist_changed.connect(_on_assist_toggled)
		controller.headlights_toggled.connect(_toggle_headlights)
		add_child(controller)
	GameSettings.changed.connect(_on_setting_changed)
	_apply_settings()
	menus = MenuManager.new()
	menus.name = "Menus"
	menus.game = self
	add_child(menus)
	if menu_start:
		to_menu()
	elif args.has("trial"):
		start_trial(String(args["trial"]))
	if args.has("ui"):
		_debug_ui.call_deferred()
	if args.has("bench"):
		var b := Benchmark.new()
		b.name = "Benchmark"
		add_child(b)
		b.start(self)


func _debug_ui() -> void:
	match String(args["ui"]):
		"settings":
			menus.open_settings("main", int(args.get("tab", "0")))
		"pause":
			pause()
		"trial_select":
			menus.show_main()
			menus.main._show_routes()


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
	if trial != null:
		_teleport(trial.respawn_pose())
		hud.show_toast("Возврат на последний створ")
		return
	var heading := -car.global_basis.z
	var n := net.nearest(car.global_position, heading)
	if n["road"].is_empty():
		_teleport(world.get_spawn(0))
		return
	var xf := net.lane_pose(n["road"], n["i"], n["dir"], 0.5)
	_teleport(xf)
	if hud:
		hud.show_toast("Возврат на дорогу")


# ---- game flow ----------------------------------------------------------------------------------------------

func hud_toast(text: String) -> void:
	if hud:
		hud.show_toast(text)


func place_car(xf: Transform3D, vel: Vector3 = Vector3.ZERO) -> void:
	_teleport(xf, vel)
	if car.drivetrain != null:
		car.drivetrain.sync_to_speed(vel.length())


func _toggle_headlights() -> void:
	headlights_manual = true
	_set_headlights(not _lights_on)
	hud.show_toast("Фары: %s" % ("вкл" if _lights_on else "выкл"))


func _set_headlights(on: bool) -> void:
	_lights_on = on
	_lights_valid = true
	var cv := car.car_visual()
	if cv != null:
		cv.call("set_headlights", on)


## automatic headlights: on in the dark hours (SkyRig.hours < 6.4 or > 19.2) until L is pressed
func _update_headlights() -> void:
	if headlights_manual or world == null or world.sky == null:
		return
	var h: float = world.sky.hours
	var want := h < 6.4 or h > 19.2
	if not _lights_valid or want != _lights_on:
		_set_headlights(want)


func _on_assist_toggled(n: String, on: bool) -> void:
	hud.show_toast("%s: %s" % [n, "вкл" if on else "выкл"])
	# keep the saved settings in step with the F-keys
	var a := car.assists
	GameSettings.cfg.set_value("assists", "abs", a.abs_on)
	GameSettings.cfg.set_value("assists", "tcs", a.tcs_on)
	GameSettings.cfg.set_value("assists", "esc", a.esc_on)
	GameSettings.cfg.set_value("assists", "countersteer", a.countersteer_on)
	GameSettings.cfg.set_value("controls", "manual_gearbox", controller.manual_gearbox)


func _on_setting_changed(section: String, _key: String) -> void:
	if section == "assists" or section == "controls" or section == "car":
		_apply_settings()


func _apply_settings() -> void:
	GameSettings.apply_to_vehicle(car)
	if controller != null:
		GameSettings.apply_to_controller(controller)
	var cv := car.car_visual()
	if cv != null:
		cv.call("set_paint", GameSettings.get_value("car", "color"))


func _clear_trial() -> void:
	if trial != null:
		trial.queue_free()
		trial = null
	if trial_hud != null:
		_hud_layer.queue_free()
		_hud_layer = null
		trial_hud = null


func to_menu() -> void:
	_clear_trial()
	get_tree().paused = false
	if mode != "menu":
		_free_cam = rig.mode if rig.mode != CameraRig.Mode.CHASE_FAR else _free_cam
	mode = "menu"
	hud.visible = false
	overlay.visible = false
	if controller != null:
		controller.enabled = false
	var road := net.get_road("ring")
	autopilot = Autopilot.new(net, "ring", 1, 900, 34.0, 0.7)
	place_car(net.lane_pose(road, 880, 1, 0.5), net.tangent(road, 880) * 30.0)
	rig.set_mode(CameraRig.Mode.CHASE_FAR)
	menus.show_main()


func _enter_play() -> void:
	_clear_trial()
	get_tree().paused = false
	menus.hide_all()
	hud.visible = true
	if controller != null:
		controller.enabled = true
	if not args.has("autopilot"):
		autopilot = null
	car.set_reverse(false)
	rig.set_mode(_free_cam)
	_apply_settings()


func start_free() -> void:
	_enter_play()
	mode = "free"
	place_car(world.get_spawn(0))
	if audio:
		audio.start_engine()
	hud.show_toast("Свободная езда")


func start_trial(route: String) -> void:
	_enter_play()
	mode = "trial"
	trial = TimeTrial.new()
	trial.name = "TimeTrial"
	add_child(trial)
	trial.setup(self, route)
	_make_trial_autopilot()
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 21
	add_child(_hud_layer)
	trial_hud = TrialHUD.new()
	trial_hud.trial = trial
	_hud_layer.add_child(trial_hud)
	if audio:
		audio.start_engine()


func _make_trial_autopilot() -> void:
	if args.has("autopilot") and trial != null:
		autopilot = Autopilot.new(net, trial.route, 1, trial.start_idx - 18, float(args.get("speed", "45")), 0.7)


func restart_trial() -> void:
	if trial != null:
		resume()
		trial.restart()
		_make_trial_autopilot()


func pause() -> void:
	if mode == "menu" or get_tree().paused:
		return
	get_tree().paused = true
	menus.show_pause(mode == "trial")


func resume() -> void:
	get_tree().paused = false
	menus.hide_all()


func _physics_process(_dt: float) -> void:
	if autopilot != null:
		var c := autopilot.update(car)
		car.drive(c.x, c.y, c.z)


func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(String(args["shot"]))
	print("SHOT saved %s (%dx%d)" % [args["shot"], img.get_width(), img.get_height()])
	if not args.has("shot-keep"):
		get_tree().quit()


# ---- smoothness measurement (dev): --jitter=<frames> [--nointerp]  prints per-frame displacement statistics
var _jit_n := 0
var _jit_car: Array[float] = []
var _jit_cam: Array[float] = []
var _jit_wheel: Array[float] = []
var _jit_prev_car := Vector3.ZERO
var _jit_prev_cam := Vector3.ZERO
var _jit_prev_wheel := Vector3.ZERO

var _shot_frame := 0

func _process(_dt: float) -> void:
	_update_headlights()
	if args.has("shot"):
		_shot_frame += 1
		if _shot_frame == int(args.get("shot-frame", "120")):
			_take_shot.call_deferred()
	if not args.has("jitter") or car == null:
		return
	if args.has("nointerp"):
		car.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var cp := car.get_global_transform_interpolated().origin
	var cc := rig.camera.global_position
	var wn := car.get_node_or_null("Visual/Knuckle_FL") as Node3D
	var wp := wn.get_global_transform_interpolated().origin if wn != null else Vector3.ZERO
	if _jit_n > 600:
		_jit_car.append(cp.distance_to(_jit_prev_car))
		_jit_cam.append(cc.distance_to(_jit_prev_cam))
		_jit_wheel.append(wp.distance_to(_jit_prev_wheel))
	_jit_prev_car = cp
	_jit_prev_cam = cc
	_jit_prev_wheel = wp
	_jit_n += 1
	if _jit_n >= int(args["jitter"]):
		for pair in [["car", _jit_car], ["camera", _jit_cam], ["front-left hub", _jit_wheel]]:
			var a: Array = pair[1]
			var mean := 0.0
			for x in a:
				mean += x
			mean /= maxf(a.size(), 1)
			var v := 0.0
			var mx := 0.0
			for x in a:
				v += (x - mean) * (x - mean)
				mx = maxf(mx, x)
			var sd := sqrt(v / maxf(a.size(), 1))
			# jitter = deviation of a step from the average of its neighbours (removes the smooth acceleration trend)
			var j := 0.0
			var jm := 0.0
			for i in range(1, a.size() - 1):
				var dev := absf(a[i] - 0.5 * (a[i - 1] + a[i + 1]))
				j += dev
				jm = maxf(jm, dev)
			j /= maxf(a.size() - 2, 1)
			print("JITTER %s: mean step %.4f m, step-to-step jitter mean %.5f m (%.2f %% of step), max %.4f m, interp=%s" % [pair[0], mean, j, 100.0 * j / maxf(mean, 1e-6), jm, str(not args.has("nointerp"))])
		get_tree().quit()
