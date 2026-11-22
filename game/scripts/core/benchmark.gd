class_name Benchmark
extends Node
## Fly-through benchmark: the autopilot drives the ring while per-frame times are recorded.
##   godot/exe ... -- --bench=ultra|high|medium|low|<0-3> --bench-size=2560x1440 --bench-seconds=120 --bench-out=path.json [--bench-cam=0..4]
## Prints "BENCH ..." and writes JSON: avg FPS, 1 % low (mean of the slowest 1 % frames, as FPS), 0.1 % low, frame-time percentiles,
## RenderingServer GPU / CPU render times (viewport measure), draw calls, objects, primitives.
## --bench-size renders at that resolution: the window is resized when the screen allows it, otherwise the 3D scale supersamples.

var game: Game
var duration := 120.0
var warmup := 6.0
var out_path := ""
var label := ""
var ablate: Array = []                   # list of feature keys switched off one by one after the main run ("sdfgi", "ssr", ...)
var _t0 := 0
var _last := 0
var _elapsed := 0.0
var _ft := PackedFloat32Array()
var _gpu := PackedFloat32Array()
var _cpu := PackedFloat32Array()
var _draw := PackedFloat32Array()
var _vp: RID
var _results: Array[Dictionary] = []
var _phase := "main"
var _abl_i := -1
var _abl_dur := 12.0
var _size_info := ""


func start(g: Game) -> void:
	game = g
	var a := g.args
	var p := String(a["bench"])
	var names := {"low": 0, "medium": 1, "med": 1, "high": 2, "ultra": 3}
	var idx: int = names.get(p.to_lower(), int(p) if p.is_valid_int() else 3)
	label = p
	GraphicsSettings.transient = true
	GameSettings.transient = true
	GraphicsSettings.set_preset(idx)
	duration = float(a.get("bench-seconds", "120"))
	out_path = String(a.get("bench-out", ""))
	if a.has("bench-ablate"):
		ablate = String(a["bench-ablate"]).split(",")
	_abl_dur = float(a.get("bench-ablate-seconds", "12"))
	var win := g.get_window()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if a.has("bench-size"):
		var sz := String(a["bench-size"]).split("x")
		var want := Vector2i(int(sz[0]), int(sz[1]))
		win.mode = Window.MODE_WINDOWED
		win.size = want
		await get_tree().process_frame
		await get_tree().process_frame
		var got := win.size
		_size_info = "window %dx%d" % [got.x, got.y]
		if got.x < want.x:
			# the OS clamped the window to the screen: render at the wanted resolution by supersampling the 3D view
			var vp := g.get_viewport()
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			vp.scaling_3d_scale = float(want.x) / float(got.x)
			_size_info += ", 3D supersampled x%.3f -> %dx%d render" % [vp.scaling_3d_scale, want.x, want.y]
			GraphicsSettings.scale_override = vp.scaling_3d_scale
		else:
			_size_info += " (native)"
	_vp = g.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	g.hud.visible = true
	_last = Time.get_ticks_usec()
	_t0 = _last
	print("BENCH start preset=%s %s duration=%.0fs" % [p, _size_info, duration])


func _process(_dt: float) -> void:
	if game == null:
		return
	var now := Time.get_ticks_usec()
	var dt := float(now - _last) / 1000.0
	_last = now
	_elapsed += dt / 1000.0
	if _elapsed < warmup:
		return
	_ft.append(dt)
	_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_vp))
	_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(_vp))
	_draw.append(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)))
	var run_t := _elapsed - warmup
	var limit := duration if _phase == "main" else _abl_dur
	if run_t >= limit:
		_finish_phase()


func _stats(name: String) -> Dictionary:
	var n := _ft.size()
	var sorted := _ft.duplicate()
	sorted.sort()
	var total := 0.0
	for x in _ft:
		total += x
	var avg_ms := total / maxf(n, 1)
	var worst1 := maxi(1, int(n * 0.01))
	var worst01 := maxi(1, int(n * 0.001))
	var s1 := 0.0
	for i in worst1:
		s1 += sorted[n - 1 - i]
	var s01 := 0.0
	for i in worst01:
		s01 += sorted[n - 1 - i]
	var g_sum := 0.0
	var c_sum := 0.0
	var d_sum := 0.0
	for i in n:
		g_sum += _gpu[i]
		c_sum += _cpu[i]
		d_sum += _draw[i]
	var info := {
		"name": name, "frames": n, "avg_fps": 1000.0 / avg_ms, "low1_fps": 1000.0 / (s1 / worst1), "low01_fps": 1000.0 / (s01 / worst01),
		"p50_ms": sorted[n / 2], "p99_ms": sorted[mini(n - 1, int(n * 0.99))], "max_ms": sorted[n - 1],
		"gpu_ms": g_sum / maxf(n, 1), "cpu_render_ms": c_sum / maxf(n, 1), "draw_calls": d_sum / maxf(n, 1),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"size": _size_info,
	}
	return info


func _finish_phase() -> void:
	var r := _stats(label if _phase == "main" else "no_" + _phase)
	_results.append(r)
	print("BENCH %s: avg %.1f fps, 1%% low %.1f fps, 0.1%% low %.1f, p99 %.2f ms, GPU %.2f ms, CPU-render %.2f ms, draws %.0f, prims %.0f (%s)" % [
		r["name"], r["avg_fps"], r["low1_fps"], r["low01_fps"], r["p99_ms"], r["gpu_ms"], r["cpu_render_ms"], r["draw_calls"], r["primitives"], _size_info])
	# ablation: switch features off one by one, measure again (GPU cost per feature)
	_abl_i += 1
	if _abl_i < ablate.size():
		var key: String = ablate[_abl_i]
		_phase = key
		_ft = PackedFloat32Array()
		_gpu = PackedFloat32Array()
		_cpu = PackedFloat32Array()
		_draw = PackedFloat32Array()
		_elapsed = 0.0
		_apply_ablation(key)
		return
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(_results, "  "))
			f.close()
	get_tree().quit()


func _apply_ablation(key: String) -> void:
	# every ablation is cumulative with respect to the baseline preset, not to the previous one: restore first
	GraphicsSettings.set_preset(GraphicsSettings.preset if GraphicsSettings.preset <= 3 else 3)
	match key:
		"sdfgi": GraphicsSettings.set_option("sdfgi", false)
		"ssr": GraphicsSettings.set_option("ssr", false)
		"ssil": GraphicsSettings.set_option("ssil", false)
		"ssao": GraphicsSettings.set_option("ssao", false)
		"vfog": GraphicsSettings.set_option("vfog", false)
		"glow": GraphicsSettings.set_option("glow", false)
		"msaa": GraphicsSettings.set_option("msaa", 0)
		"aa": GraphicsSettings.set_option("aa", 0)
		"shadows":
			GraphicsSettings.set_option("shadow_size", 0)
			GraphicsSettings.set_option("shadow_quality", 1)
		"shadow_distance": GraphicsSettings.set_option("shadow_distance", 120.0)
		"trees": GraphicsSettings.set_option("tree_distance", 0.3)
		"grass": GraphicsSettings.set_option("grass", false)
		"aniso": GraphicsSettings.set_option("aniso", 0)
		"fsr":
			GraphicsSettings.set_option("scale", 0.67)
			GraphicsSettings.set_option("upscaler", 1)
	print("BENCH ablation: %s off" % key)
