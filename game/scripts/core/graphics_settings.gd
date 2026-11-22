extends Node
## Autoload "GraphicsSettings": graphics presets + individual options, applied at RUNTIME (no scene files are edited).
##   preset 0..3  Низкие / Средние / Высокие / Ультра (4 = custom, set automatically when a single option is changed)
##   attach(world) hooks the world: Environment (ssr/ssao/ssil/sdfgi/glow/volumetric fog), sun shadow distance,
##   tree draw distance (visibility_range_end of the Vegetation MultiMeshInstance3D children).
## Persisted in user://settings.cfg [graphics] through GameSettings.

signal changed

const PRESET_NAMES := ["Низкие", "Средние", "Высокие", "Ультра", "Особые"]
const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
const AA_NAMES := ["Выкл", "FXAA", "SMAA"]
const MSAA_NAMES := ["Выкл", "2x", "4x", "8x"]
const ANISO_NAMES := ["Выкл", "2x", "4x", "8x", "16x"]
const SHADOW_SIZES := [2048, 4096, 8192, 8192]
const SHADOW_NAMES := ["Низкое", "Среднее", "Высокое", "Ультра"]
const UPSCALER_NAMES := ["Билинейное", "FSR 2"]

## msaa, aa, aniso, shadow_size (index), shadow_quality (RenderingServer.ShadowQuality), shadow_distance,
## ssao, ssil, ssr, sdfgi, glow, vfog, tree_distance (multiplier), grass (World/Grass visible), scale, upscaler
const PRESETS := [
	# Низкие
	{"msaa": 0, "aa": 1, "aniso": 1, "shadow_size": 0, "shadow_quality": 1, "shadow_distance": 140.0, "ssao": false, "ssil": false,
		"ssr": false, "sdfgi": false, "glow": false, "vfog": false, "tree_distance": 0.4, "grass": false, "scale": 0.77, "upscaler": 1},
	# Средние
	{"msaa": 0, "aa": 2, "aniso": 2, "shadow_size": 1, "shadow_quality": 2, "shadow_distance": 220.0, "ssao": true, "ssil": false,
		"ssr": false, "sdfgi": false, "glow": true, "vfog": false, "tree_distance": 0.65, "grass": true, "scale": 1.0, "upscaler": 0},
	# Высокие
	{"msaa": 1, "aa": 2, "aniso": 3, "shadow_size": 2, "shadow_quality": 3, "shadow_distance": 320.0, "ssao": true, "ssil": true,
		"ssr": true, "sdfgi": false, "glow": true, "vfog": false, "tree_distance": 1.0, "grass": true, "scale": 1.0, "upscaler": 0},
	# Ультра: всё включено
	{"msaa": 2, "aa": 2, "aniso": 4, "shadow_size": 3, "shadow_quality": 4, "shadow_distance": 500.0, "ssao": true, "ssil": true,
		"ssr": true, "sdfgi": true, "glow": true, "vfog": true, "tree_distance": 1.4, "grass": true, "scale": 1.0, "upscaler": 0},
]
const DISPLAY_DEFAULTS := {"window_mode": 0, "resolution": 2, "vsync": true, "fps_cap": 0}

var preset := 2
var values: Dictionary = {}
var display: Dictionary = DISPLAY_DEFAULTS.duplicate()
var world: Node
var _viewport: Viewport
var _display_touched := false
var transient := false             # benchmark: do not persist
var scale_override := 0.0          # benchmark supersampling (> 1) wins over the preset scale


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_values()


func load_values() -> void:
	preset = int(GameSettings.get_value_or("graphics", "preset", 2))
	var base: Dictionary = PRESETS[clampi(preset, 0, 3)]
	values = base.duplicate()
	for k in values.keys():
		values[k] = GameSettings.get_value_or("graphics", k, values[k])
	for k in DISPLAY_DEFAULTS.keys():
		display[k] = GameSettings.get_value_or("graphics", k, DISPLAY_DEFAULTS[k])


func save_all() -> void:
	if transient:
		return
	GameSettings.set_value("graphics", "preset", preset)
	for k in values:
		GameSettings.set_value("graphics", k, values[k])
	for k in display:
		GameSettings.set_value("graphics", k, display[k])


func set_preset(i: int) -> void:
	preset = clampi(i, 0, 3)
	values = (PRESETS[preset] as Dictionary).duplicate()
	apply()
	save_all()


## change one option; the preset becomes "Особые"
func set_option(key: String, value: Variant) -> void:
	if DISPLAY_DEFAULTS.has(key):
		display[key] = value
		_display_touched = true
	else:
		values[key] = value
		preset = 4
	apply()
	save_all()


func attach(world_node: Node) -> void:
	world = world_node
	_viewport = world_node.get_viewport() if world_node != null else get_viewport()
	apply()


## First-start display setup before any world exists (menu in front of a black screen etc.)
func apply_display() -> void:
	var win := get_window()
	if win == null or DisplayServer.get_name() == "headless":
		return
	# never fight explicit command line sizes (screenshots / movie maker / benchmark) until the user changes a display option
	if not _display_touched:
		var a := OS.get_cmdline_args()
		if a.has("--resolution") or a.has("--write-movie") or a.has("--bench-size"):
			return
		if not GameSettings.cfg.has_section_key("graphics", "window_mode"):
			return
	var res: Vector2i = RESOLUTIONS[clampi(int(display["resolution"]), 0, RESOLUTIONS.size() - 1)]
	if int(display["window_mode"]) == 1:
		win.mode = Window.MODE_FULLSCREEN
	else:
		win.mode = Window.MODE_WINDOWED
		win.size = res
		var scr := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
		win.position = Vector2i((scr - res) / 2).max(Vector2i(0, 0))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(display["vsync"]) else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = int(display["fps_cap"])


func apply() -> void:
	var vp: Viewport = _viewport if _viewport != null else get_viewport()
	if vp == null:
		return
	var v := values
	vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X, Viewport.MSAA_8X][clampi(int(v["msaa"]), 0, 3)]
	vp.screen_space_aa = [Viewport.SCREEN_SPACE_AA_DISABLED, Viewport.SCREEN_SPACE_AA_FXAA, Viewport.SCREEN_SPACE_AA_SMAA][clampi(int(v["aa"]), 0, 2)]
	var sc := clampf(float(v["scale"]), 0.5, 1.0)
	if scale_override > 1.0:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = scale_override
	elif sc < 0.995:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if int(v["upscaler"]) == 1 else Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = sc
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = 1.0
	vp.anisotropic_filtering_level = [Viewport.ANISOTROPY_DISABLED, Viewport.ANISOTROPY_2X, Viewport.ANISOTROPY_4X,
		Viewport.ANISOTROPY_8X, Viewport.ANISOTROPY_16X][clampi(int(v["aniso"]), 0, 4)]
	var si := clampi(int(v["shadow_size"]), 0, 3)
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_SIZES[si], si >= 3)
	var sq := clampi(int(v["shadow_quality"]), 0, 5)
	RenderingServer.directional_soft_shadow_filter_set_quality(sq)
	RenderingServer.positional_soft_shadow_filter_set_quality(clampi(sq - 1, 0, 5))
	if world != null and is_instance_valid(world):
		_apply_world(world)
	apply_display()
	changed.emit()


func _apply_world(w: Node) -> void:
	var sky: Object = w.get("sky")
	if sky != null:
		var env: Environment = sky.get("environment")
		if env != null:
			var ultra_fog := bool(values["vfog"])
			env.ssao_enabled = bool(values["ssao"])
			env.ssil_enabled = bool(values["ssil"])
			env.ssr_enabled = bool(values["ssr"])
			env.glow_enabled = bool(values["glow"])
			env.sdfgi_enabled = bool(values["sdfgi"])
			if env.sdfgi_enabled:
				env.sdfgi_cascades = 4
				env.sdfgi_min_cell_size = 0.5
				env.sdfgi_use_occlusion = true
				env.sdfgi_read_sky_light = true
				env.sdfgi_energy = 0.8
			env.volumetric_fog_enabled = ultra_fog
			if ultra_fog:
				env.volumetric_fog_density = 0.006
				env.volumetric_fog_length = 160.0
				env.volumetric_fog_detail_spread = 2.0
				env.volumetric_fog_gi_inject = 0.5
				env.volumetric_fog_ambient_inject = 0.2
		var sun: DirectionalLight3D = sky.get("sun")
		if sun != null:
			sun.directional_shadow_max_distance = float(values["shadow_distance"])
	var grass: Variant = w.get("grass")
	if grass is Node3D:
		(grass as Node3D).visible = bool(values["grass"])
	var veg := w.get_node_or_null("Vegetation")
	if veg != null:
		var f := float(values["tree_distance"])
		for c in veg.get_children():
			var g := c as GeometryInstance3D
			if g == null:
				continue
			if not g.has_meta("base_vis_end"):
				g.set_meta("base_vis_end", g.visibility_range_end)
			var base: float = g.get_meta("base_vis_end")
			if base > 0.0:
				g.visibility_range_end = base * f
