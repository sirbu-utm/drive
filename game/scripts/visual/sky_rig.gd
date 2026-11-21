extends Node3D
class_name SkyRig
## Photographic time of day: WorldEnvironment + sun DirectionalLight3D driven by a set of HDRI keyframes
## (Poly Haven "qwantani" series: the same place photographed through a whole day).
## Sun/moon direction, colour and energy per photo come from pipeline/hdri_sun.py (sun_data.json).
##
##   set_time(hours)        0..24, blends the two neighbouring photos
##   set_keyframe(name)     jump to one photo ("noon", "sunset", ...)
##   environment / sun      exposed for other systems (fog, exposure, headlights logic)

const HDRI_DIR := "res://assets/hdri/qwantani/"
const SUN_DATA := HDRI_DIR + "sun_data.json"

## keyframe name -> hour of day. "moonrise" is skipped (inconsistent exposure in the set).
const KEYS := [
	["dawn", 5.4], ["sunrise", 6.1], ["morning", 7.6], ["mid_morning", 9.6], ["noon", 12.5],
	["afternoon", 15.2], ["late_afternoon", 17.0], ["sunset", 18.5], ["dusk_1", 19.1], ["dusk_2", 19.5],
	["night", 21.5],
]
## Relative scene brightness per keyframe (total horizontal illuminance, compressed range — auto exposure
## does the rest). Noon = 1.
const TARGET := {
	"dawn": 0.10, "sunrise": 0.17, "morning": 0.55, "mid_morning": 0.85, "noon": 1.0, "afternoon": 0.9,
	"late_afternoon": 0.6, "sunset": 0.32, "dusk_1": 0.12, "dusk_2": 0.08, "night": 0.05,
}

## extra multiplier on the photo's sky brightness (night photo has strong light pollution)
const SKY_MULT := {"night": 0.3, "dusk_2": 0.8}

@export var hours: float = 12.5
@export var rotation_rad: float = 0.0          ## rotate the whole sky (and sun) about +Y
@export var scene_scale: float = 3.0           ## Godot-unit illuminance at noon (white horizontal surface)
@export var sky_boost: float = 1.35            ## extra ambient vs. photo (gameplay readability in shadows)
@export var shadow_max_distance: float = 400.0
@export var radiance_quality: bool = true      ## true: high-quality radiance (static scenes); false: incremental

var environment: Environment
var world_env: WorldEnvironment
var sun: DirectionalLight3D
var sky_mat: ShaderMaterial
var data := {}
var _tex_cache := {}


func _ready() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(SUN_DATA))
	_build()
	set_time(hours)


func _build() -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky_hdri.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_512
	sky.process_mode = Sky.PROCESS_MODE_QUALITY if radiance_quality else Sky.PROCESS_MODE_INCREMENTAL

	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = 1.0
	# screen-space effects
	environment.ssr_enabled = true
	environment.ssr_max_steps = 96
	environment.ssr_fade_in = 0.1
	environment.ssr_fade_out = 2.0
	environment.ssr_depth_tolerance = 0.25
	environment.ssao_enabled = true
	environment.ssao_radius = 0.9
	environment.ssao_intensity = 1.6
	environment.ssao_power = 1.4
	environment.ssao_detail = 0.6
	environment.ssil_enabled = true
	environment.ssil_radius = 4.0
	environment.ssil_intensity = 0.8
	environment.glow_enabled = true
	environment.glow_normalized = true
	environment.glow_intensity = 0.55
	environment.glow_bloom = 0.04
	environment.glow_hdr_threshold = 1.1
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.06
	environment.adjustment_contrast = 1.03

	world_env = WorldEnvironment.new()
	world_env.environment = environment
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = shadow_max_distance
	sun.directional_shadow_split_1 = 0.05
	sun.directional_shadow_split_2 = 0.15
	sun.directional_shadow_split_3 = 0.4
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.0
	sun.light_angular_distance = 0.53      # soft shadow penumbra like the real sun
	add_child(sun)


func _tex(name: String) -> Texture2D:
	if not _tex_cache.has(name):
		_tex_cache[name] = load(HDRI_DIR + "qwantani_%s_puresky_4k.hdr" % name)
	return _tex_cache[name]


func _info(name: String) -> Dictionary:
	return data["qwantani_%s_puresky_4k.hdr" % name]


func _photo_to_world(v: Vector3) -> Vector3:
	# inverse of the rotation used in sky_hdri.gdshader
	var c := cos(rotation_rad)
	var s := sin(rotation_rad)
	return Vector3(c * v.x - s * v.z, v.y, s * v.x + c * v.z)


## Godot-unit sky multiplier and sun energy for one keyframe
func _calib(name: String) -> Dictionary:
	var q := _info(name)
	var dir := Vector3(q.sun_dir[0], q.sun_dir[1], q.sun_dir[2]).normalized()
	var sun_e: float = q.sun_energy if q.has_disc else 0.0
	var e_total: float = q.sky_irradiance + sun_e * PI * maxf(dir.y, 0.0)
	var k: float = scene_scale * TARGET[name] / maxf(e_total, 1e-6)
	var col := Color(q.sun_color[0], q.sun_color[1], q.sun_color[2])
	var light_e := k * sun_e
	k *= SKY_MULT.get(name, 1.0)
	if name == "night":
		# moonlight: dim, cool, from the brightest point of the night sky
		col = Color(0.62, 0.72, 1.0)
		light_e = scene_scale * TARGET[name] * 0.9
	return {"k": k, "dir": dir, "sun_e": light_e, "col": col}


func set_keyframe(name: String) -> void:
	for i in KEYS.size():
		if KEYS[i][0] == name:
			set_time(KEYS[i][1])
			return


func set_time(h: float) -> void:
	hours = fposmod(h, 24.0)
	# find neighbours (wrapping night -> dawn)
	var n := KEYS.size()
	var ia := n - 1
	for i in n:
		if KEYS[i][1] <= hours:
			ia = i
	var ib := (ia + 1) % n
	var ta: float = KEYS[ia][1]
	var tb: float = KEYS[ib][1]
	if tb <= ta:
		tb += 24.0
	var hh := hours if hours >= ta else hours + 24.0
	var t := clampf((hh - ta) / maxf(tb - ta, 1e-3), 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	var a := _calib(KEYS[ia][0])
	var b := _calib(KEYS[ib][0])
	sky_mat.set_shader_parameter("sky_a", _tex(KEYS[ia][0]))
	sky_mat.set_shader_parameter("sky_b", _tex(KEYS[ib][0]))
	sky_mat.set_shader_parameter("blend", t)
	sky_mat.set_shader_parameter("energy_a", a.k * sky_boost)
	sky_mat.set_shader_parameter("energy_b", b.k * sky_boost)
	sky_mat.set_shader_parameter("rotation", rotation_rad)

	# sun: interpolate direction/colour/energy; a keyframe without a disc contributes 0 energy
	var da: Vector3 = a.dir
	var db: Vector3 = b.dir
	var dir := da.slerp(db, t).normalized() if da.dot(db) > -0.99 else (da if t < 0.5 else db)
	dir = _photo_to_world(dir)
	var e: float = lerpf(a.sun_e, b.sun_e, t)
	var col: Color = (a.col as Color).lerp(b.col, t)
	# fade the light out as the disc reaches the horizon (avoid razor shadows at grazing angles)
	e *= smoothstep(-0.01, 0.04, dir.y) if KEYS[ia][0] != "night" and KEYS[ib][0] != "night" else 1.0
	sun.light_energy = e
	sun.light_color = col
	sun.visible = e > 0.001
	if dir.y < 0.02:
		dir.y = 0.02
	var up := Vector3.UP if absf(dir.normalized().y) < 0.98 else Vector3.FORWARD
	sun.look_at_from_position(Vector3.ZERO, -dir.normalized(), up)
	sun.global_position = global_position


## Approximate scene brightness (for auto-exposure / headlight logic): 1 = noon.
func daylight() -> float:
	var n := KEYS.size()
	var best := 0.0
	for i in n:
		if absf(KEYS[i][1] - hours) < 1.0:
			best = maxf(best, TARGET[KEYS[i][0]])
	return best
