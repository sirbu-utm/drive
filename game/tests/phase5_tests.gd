extends "res://tests/vehicle_test_base.gd"
## Phase 5: audio assets + runtime mix, menus / game flow, graphics settings, time trial with ghost.

const AUDIO := "res://assets/audio/"


func _loudest(players: Array) -> AudioStreamPlayer3D:
	var best: AudioStreamPlayer3D = null
	for p in players:
		if p.stream_paused:
			continue
		if best == null or p.volume_db > best.volume_db:
			best = p
	return best


func test_audio_assets_loop_and_cover_range() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(AUDIO + "engine_loops.json"))
	var loops: Array = meta["loops"]
	check_eq(loops.size(), 16, "8 rpm points x throttle on/off")
	var rpms := {}
	for l in loops:
		var st := load(AUDIO + l["file"]) as AudioStreamWAV
		check(st != null, "%s loads" % l["file"])
		if st == null:
			continue
		check_eq(st.loop_mode, AudioStreamWAV.LOOP_FORWARD, "%s loops (smpl chunk)" % l["file"])
		check(st.loop_end > st.loop_begin + 20000, "%s loop spans the file" % l["file"])
		rpms[int(l["nominal_rpm"])] = true
	check(rpms.has(1000) and rpms.has(9000), "idle (1000) and limiter (9000 rpm) points exist")
	for f in ["whine", "squeal_a", "squeal_b", "slide_loose", "road_asphalt", "road_gravel", "road_grass", "wind"]:
		var st := load(AUDIO + f + ".wav") as AudioStreamWAV
		check(st != null and st.loop_mode == AudioStreamWAV.LOOP_FORWARD, "%s is a loop" % f)
	for f in ["pop_1", "pop_2", "pop_3", "pop_4", "pop_5", "shift_1", "shift_2", "shift_3", "bump", "impact_light_1", "impact_heavy_1", "starter"]:
		check(load(AUDIO + f + ".wav") != null, "%s loads" % f)


func test_vehicle_audio_engine_pitch_pops_shift_squeal() -> void:
	make_world()
	spawn(Vector3(0, 0.02, 0), 0.0, 0.0)
	var a := VehicleAudio.new()
	a.vehicle = car
	car.add_child(a)
	await tree.process_frame
	# idle: engine loops audible, pitch matches rpm / loop rpm
	await run_seconds(1.5, func(_t): car.drive(0, 0, 0, 0))
	for i in 10:
		await tree.process_frame
	var engines: Array = a._on + a._off
	var top := _loudest(engines)
	check(top != null, "an engine loop is audible at idle")
	if top != null:
		var idx := engines.find(top) % a._rpms.size()
		var expect := car.rpm / a._rpms[idx]
		check_near(top.pitch_scale, expect, 0.12, "idle pitch follows rpm (%.0f rpm)" % car.rpm)
		check(top.volume_db > -20.0, "idle loop is audible (%.1f dB)" % top.volume_db)
	# full throttle: rpm rises, pitch / crossfade follow, shifts clunk, no mid-pull silence
	var squeal := 0.0
	await run_seconds(4.5, func(_t: float): car.drive(1.0, 0, 0, 0))
	var rpm_after := car.rpm
	check(rpm_after > 3500.0, "pulled hard (%.0f rpm)" % rpm_after)
	check(int(a.dbg.get("shifts", 0)) >= 1, "gear shifts trigger the clunk (%d)" % int(a.dbg.get("shifts", 0)))
	for i in 6:
		await tree.process_frame
	var on_top := _loudest(a._on)
	check(on_top != null and on_top.volume_db > -12.0, "throttle-on loops carry the mix under load")
	var vol_on: float = on_top.volume_db if on_top != null else -80.0
	var pops_before := int(a.dbg.get("pops", 0))
	# lift at high rpm -> overrun: off loops take over, pops appear
	await run_seconds(1.5, func(_t: float): car.drive(0.0, 0.0, 0.0, 0.0))
	for i in 6:
		await tree.process_frame
	var off_top := _loudest(a._off)
	check(off_top != null, "overrun loops audible after lift")
	if off_top != null and on_top != null:
		check(off_top.volume_db > _loudest(a._on).volume_db if _loudest(a._on) != null else true, "off loop louder than on loop in overrun")
	metric("pops_after_lift", int(a.dbg.get("pops", 0)) - pops_before)
	metric("shifts", int(a.dbg.get("shifts", 0)))
	check(int(a.dbg.get("pops", 0)) - pops_before >= 1, "overrun pops after a lift at high rpm")
	# cornering hard on tarmac: squeal
	await settle(0.3)
	car.reset_to(Transform3D(Basis(Vector3.UP, 0.0), Vector3(0, 0.02, 0)), Vector3(0, 0, -24.0))
	var st := {"squeal": 0.0}
	await run_seconds(3.0, func(t: float):
		car.drive(0.45, 0.0, deg_to_rad(11.0) if t > 0.3 else 0.0, 0.0)
		if int(t * 240.0) % 4 == 0:
			st["squeal"] = maxf(st["squeal"], float(a.dbg.get("squeal", 0.0))))
	squeal = st["squeal"]
	metric("squeal_peak", squeal)
	check(squeal > 0.25, "tyre squeal rises in a slide (%.2f)" % squeal)
	a.queue_free()
	cleanup()
	await tree.physics_frame


func test_vehicle_audio_impact_and_interior_mix() -> void:
	make_world()
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(30, 6, 1)
	cs.shape = bs
	wall.add_child(cs)
	wall.position = Vector3(0, 3, -45)
	world.add_child(wall)
	spawn(Vector3(0, 0.02, 0), 0.0, 22.0)
	var rig := CameraRig.new()
	rig.vehicle = car
	tree.root.add_child(rig)
	var a := VehicleAudio.new()
	a.vehicle = car
	a.rig = rig
	car.add_child(a)
	await tree.process_frame
	rig.set_mode(CameraRig.Mode.CHASE_NEAR)
	await run_seconds(0.5, func(_t): car.drive(0.4, 0, 0, 0))
	for i in 20:
		await tree.process_frame
	var lp_out := AudioServer.get_bus_effect(AudioServer.get_bus_index("Engine"), 0) as AudioEffectLowPassFilter
	check(lp_out.cutoff_hz > 12000.0, "exterior engine bus is open (%.0f Hz)" % lp_out.cutoff_hz)
	rig.set_mode(CameraRig.Mode.COCKPIT)
	for i in 120:
		await tree.process_frame
	check(lp_out.cutoff_hz < 4000.0, "cockpit camera muffles the engine bus (%.0f Hz)" % lp_out.cutoff_hz)
	check_eq(a._on[0].attenuation_model, AudioStreamPlayer3D.ATTENUATION_DISABLED, "interior mix disables distance attenuation")
	rig.set_mode(CameraRig.Mode.CHASE_NEAR)
	for i in 120:
		await tree.process_frame
	check(lp_out.cutoff_hz > 12000.0, "back outside the bus opens again (%.0f Hz)" % lp_out.cutoff_hz)
	# drive into the wall: impact sound
	await run_seconds(4.0, func(_t): car.drive(0.6, 0, 0, 0))
	metric("impacts", int(a.dbg.get("impacts", 0)))
	check(int(a.dbg.get("impacts", 0)) >= 1, "wall hit plays an impact (%d)" % int(a.dbg.get("impacts", 0)))
	a.queue_free()
	rig.queue_free()
	cleanup()
	await tree.physics_frame


func _new_game(args := {}, scene: String = "res://scenes/game.tscn") -> Game:
	var g := (load(scene) as PackedScene).instantiate() as Game
	g.args = args
	tree.root.add_child(g)
	await tree.physics_frame
	await tree.physics_frame
	return g


func _free_game(g: Game) -> void:
	tree.paused = false
	g.queue_free()
	await tree.physics_frame
	await tree.physics_frame
	GameSettings.cfg = ConfigFile.new()


func test_menu_flow_pause_settings_paint() -> void:
	var g := await _new_game({}, "res://scenes/main.tscn")
	check_eq(g.mode, "menu", "main scene starts in the menu")
	check(g.menus.main.visible and not g.menus.pause_menu.visible, "main menu shown")
	check(not g.hud.visible, "no HUD behind the menu")
	check(g.autopilot != null, "the car drives itself behind the menu")
	await run_seconds(4.0)
	check(g.car.speed > 15.0, "attract-mode car is moving (%.1f m/s)" % g.car.speed)
	# free ride
	g.start_free()
	await run_seconds(0.5)
	check_eq(g.mode, "free", "free ride started")
	check(not g.menus.main.visible and g.hud.visible, "menu hidden, HUD shown")
	check(g.controller != null and g.controller.enabled and g.autopilot == null, "player has control")
	# pause
	g.pause()
	check(tree.paused and g.menus.pause_menu.visible, "pause menu pauses the tree")
	g.menus.open_settings("pause", 0)
	check(g.menus.settings.visible and not g.menus.pause_menu.visible, "settings opens from pause")
	g.menus.settings.close()
	check(g.menus.pause_menu.visible, "closing settings returns to pause")
	g.resume()
	check(not tree.paused and not g.menus.pause_menu.visible, "resume")
	# assists / gearbox / sensitivity from the settings
	GameSettings.set_value("assists", "abs", false)
	GameSettings.set_value("assists", "esc", true)
	GameSettings.set_value("controls", "manual_gearbox", true)
	GameSettings.set_value("controls", "steer_sensitivity", 0.7)
	GameSettings.set_value("controls", "steer_linearity", 1.9)
	check(not g.car.assists.abs_on and g.car.assists.esc_on, "assist settings reach the car")
	check(g.controller.manual_gearbox and not g.car.drivetrain.auto, "manual gearbox setting applied")
	check_near(g.controller.steer_sensitivity, 0.7, 0.001, "steering sensitivity applied")
	check_near(g.controller.filter.linearity, 1.9, 0.001, "steering linearity applied")
	# paint
	GameSettings.set_value("car", "color", Color(0.1, 0.2, 0.9))
	var cv := g.car.car_visual()
	check(cv != null and (cv.get("paint_color") as Color).is_equal_approx(Color(0.1, 0.2, 0.9)), "paint colour reaches CarVisual.set_paint")
	# settings file round trip (in-memory config in headless)
	GameSettings.set_value("audio", "engine", 0.4)
	check_near(float(GameSettings.get_value("audio", "engine")), 0.4, 0.001, "audio setting stored")
	GameSettings.apply_audio()
	var bi := AudioServer.get_bus_index("Engine")
	check(bi >= 0 and absf(AudioServer.get_bus_volume_db(bi) - linear_to_db(0.4)) < 0.1, "Engine bus volume follows the slider")
	# back to menu
	g.to_menu()
	check_eq(g.mode, "menu", "back in the menu")
	check(g.menus.main.visible and g.autopilot != null, "menu + attract mode again")
	await _free_game(g)


func test_graphics_presets_apply_at_runtime() -> void:
	var g := await _new_game()
	var env: Environment = g.world.sky.environment
	var sun: DirectionalLight3D = g.world.sky.sun
	GraphicsSettings.set_preset(3)
	check(env.sdfgi_enabled and env.ssr_enabled and env.ssao_enabled and env.ssil_enabled and env.glow_enabled and env.volumetric_fog_enabled, "Ultra: everything on")
	check_near(sun.directional_shadow_max_distance, 500.0, 0.1, "Ultra shadow distance")
	check(g.world.grass == null or g.world.grass.visible, "Ultra: grass on")
	var veg := g.world.get_node("Vegetation")
	var first := veg.get_child(0) as GeometryInstance3D
	var base: float = first.get_meta("base_vis_end")
	var ultra_end := first.visibility_range_end
	check_near(ultra_end, base * 1.4, 1.0, "Ultra tree distance x1.4")
	GraphicsSettings.set_preset(0)
	check(not env.sdfgi_enabled and not env.ssr_enabled and not env.ssao_enabled and not env.ssil_enabled and not env.glow_enabled and not env.volumetric_fog_enabled, "Low: everything off")
	check_near(sun.directional_shadow_max_distance, 140.0, 0.1, "Low shadow distance")
	check(g.world.grass == null or not g.world.grass.visible, "Low: grass off")
	check_near(first.visibility_range_end, base * 0.4, 1.0, "Low tree distance x0.4")
	var vp := g.get_viewport()
	check_eq(vp.msaa_3d, Viewport.MSAA_DISABLED, "Low: MSAA off")
	check_eq(vp.scaling_3d_mode, Viewport.SCALING_3D_MODE_FSR2, "Low: FSR 2 upscaling")
	check_near(vp.scaling_3d_scale, 0.77, 0.01, "Low: render scale 77 %")
	GraphicsSettings.set_option("ssao", true)
	check_eq(GraphicsSettings.preset, 4, "a single toggle switches to the custom preset")
	check(env.ssao_enabled and not env.ssr_enabled, "individual toggle applied")
	GraphicsSettings.set_preset(2)
	check_eq(vp.msaa_3d, Viewport.MSAA_2X, "High: MSAA 2x")
	check_eq(vp.scaling_3d_mode, Viewport.SCALING_3D_MODE_BILINEAR, "High: native resolution")
	check_near(vp.scaling_3d_scale, 1.0, 0.001, "High: full render scale")
	await _free_game(g)


func test_headlights_auto_and_manual_and_interior_exposure() -> void:
	var g := await _new_game({"hour": "12.5"})
	await tree.process_frame
	await tree.process_frame
	var cv := g.car.car_visual()
	check(cv != null, "car visual present")
	check(not g._lights_on, "headlights off at noon")
	g.world.sky.set_time(21.0)
	await tree.process_frame
	await tree.process_frame
	check(g._lights_on, "automatic headlights on at 21:00")
	g.world.sky.set_time(5.0)
	await tree.process_frame
	check(g._lights_on, "and at 05:00")
	g.world.sky.set_time(12.0)
	await tree.process_frame
	check(not g._lights_on, "off again at noon")
	g._toggle_headlights()
	check(g._lights_on and g.headlights_manual, "L switches the lights on manually")
	g.world.sky.set_time(21.0)
	await tree.process_frame
	g._toggle_headlights()
	check(not g._lights_on, "manual off sticks in the dark")
	g.world.sky.set_time(12.0)
	await tree.process_frame
	check(not g._lights_on, "manual mode no longer follows the clock")
	# exposure attributes per camera
	var rig := g.rig
	rig.set_mode(CameraRig.Mode.CHASE_NEAR)
	var chase_attr := rig.camera.attributes as CameraAttributesPractical
	check_near(chase_attr.auto_exposure_max_sensitivity, 800.0, 1.0, "chase cams keep the wide exposure range")
	for m in [CameraRig.Mode.HOOD, CameraRig.Mode.BUMPER, CameraRig.Mode.COCKPIT]:
		rig.set_mode(m)
		var a := rig.camera.attributes as CameraAttributesPractical
		check(a != null and a.auto_exposure_min_sensitivity >= 99.0 and a.auto_exposure_max_sensitivity <= 401.0 and absf(a.auto_exposure_scale - 0.35) < 0.01, "mounted camera %d has the tight exposure range" % m)
	check(rig.is_interior(), "cockpit counts as interior")
	rig.set_mode(CameraRig.Mode.BUMPER)
	check(not rig.is_interior() and rig.is_mounted(), "bumper is mounted but not interior")
	await _free_game(g)


func test_time_trial_runway_splits_ghost_invalid() -> void:
	TrialRecords.cfg_path = "user://test_records.cfg"
	TrialRecords.ghost_dir = "user://test_"
	DirAccess.remove_absolute(TrialRecords.cfg_path)
	DirAccess.remove_absolute(TrialRecords.ghost_path("runway"))
	var g := await _new_game({"autopilot": "runway", "speed": "70"})
	var times: Array[float] = []
	var splits_seen: Array[int] = []
	g.start_trial("runway")
	var tr := g.trial
	check(tr != null, "trial created")
	tr.lap_done.connect(func(t: float, nb: bool, valid: bool): times.append(t))
	tr.sector_done.connect(func(i: int, t: float, d: float): splits_seen.append(i))
	check_eq(tr.gates.size(), 4, "open road: start + 2 sectors + finish")
	check_eq(tr.state, TimeTrial.State.COUNTDOWN, "countdown first")
	await run_seconds(2.0)
	check(g.car.speed < 1.5, "car held during the countdown (%.1f m/s)" % g.car.speed)
	var t_guard := 0
	while tr.state != TimeTrial.State.FINISHED and t_guard < 240 * 80:
		await tree.physics_frame
		t_guard += 1
	check_eq(tr.state, TimeTrial.State.FINISHED, "sprint finished")
	check_eq(times.size(), 1, "one lap result")
	check_eq(splits_seen, [0, 1], "two sector splits in order")
	var first_time: float = times[0] if times.size() > 0 else 0.0
	metric("runway_time_s", first_time)
	check(first_time > 15.0 and first_time < 60.0, "plausible time (%.2f s)" % first_time)
	var rec := TrialRecords.best("runway")
	check_near(float(rec["time"]), first_time, 0.001, "best lap saved")
	check_eq((rec["splits"] as PackedFloat32Array).size(), 2, "best splits saved")
	check(tr.ghost.duration() > first_time - 0.1, "ghost recorded (%.2f s)" % tr.ghost.duration())
	check(FileAccess.file_exists(TrialRecords.ghost_path("runway")), "ghost persisted")
	# second run: ghost replays the best lap next to the player
	g.restart_trial()
	await run_seconds(5.5)
	var gh_dist := -1.0
	var guard2 := 0
	while tr.state != TimeTrial.State.RUNNING and guard2 < 240 * 10:
		await tree.physics_frame
		guard2 += 1
	await run_seconds(6.0)
	await tree.process_frame
	check(tr.ghost.visible, "ghost visible during the run")
	gh_dist = tr.ghost.global_position.distance_to(g.car.global_position)
	metric("ghost_dist_at_6s_m", gh_dist)
	check(gh_dist < 30.0, "ghost drives alongside the player (%.1f m)" % gh_dist)
	var d_seen: Array[bool] = [false]
	tr.sector_done.connect(func(i: int, t: float, d: float): d_seen[0] = d_seen[0] or not is_nan(d))
	guard2 = 0
	while tr.state != TimeTrial.State.FINISHED and guard2 < 240 * 80:
		await tree.physics_frame
		guard2 += 1
	check(d_seen[0], "sector deltas against the best lap are produced")
	check_eq(times.size(), 2, "second lap result")
	if times.size() > 1:
		check_near(times[1], first_time, 1.0, "repeat run time is consistent (%.2f vs %.2f)" % [times[1], first_time])
	# third run: reset (R) invalidates the lap, best stays
	var best_before := float(TrialRecords.best("runway")["time"])
	g.restart_trial()
	guard2 = 0
	while tr.state != TimeTrial.State.RUNNING and guard2 < 240 * 12:
		await tree.physics_frame
		guard2 += 1
	await run_seconds(4.0)
	g.respawn()
	check(tr.invalid, "respawn marks the lap invalid")
	await run_seconds(2.0)
	guard2 = 0
	var valid_flags: Array[bool] = []
	tr.lap_done.connect(func(t: float, nb: bool, valid: bool): valid_flags.append(valid))
	while tr.state != TimeTrial.State.FINISHED and guard2 < 240 * 90:
		await tree.physics_frame
		guard2 += 1
	check(valid_flags.size() >= 1 and not valid_flags[0], "invalid lap reported as not valid")
	check_near(float(TrialRecords.best("runway")["time"]), best_before, 0.0001, "invalid lap does not touch the record")
	DirAccess.remove_absolute(TrialRecords.cfg_path)
	DirAccess.remove_absolute(TrialRecords.ghost_path("runway"))
	TrialRecords.cfg_path = "user://records.cfg"
	TrialRecords.ghost_dir = "user://"
	await _free_game(g)
