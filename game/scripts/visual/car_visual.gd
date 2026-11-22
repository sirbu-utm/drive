extends Node3D
class_name CarVisual
## Visual layer of a car: swaps the imported GLB placeholder materials for DRIVE1 shaders, adds lamps,
## and exposes a tiny API the vehicle physics drives every frame. Owns NO physics.
##
## Node contract (from pipeline/build_car.py): Body, Wing, Wheel_FL/FR/RL/RR, Caliper_*, Mirror_L/R,
## Taillight_{L,R}{1..3}, Headlight_L/R (empties), Exhaust_L/R (empties). Car forward = -Z, up = +Y.
##
## API for the vehicle:
##   set_brake(v: float)        0..1 brake pedal -> tail lights + brake glow source
##   set_reverse(on: bool)
##   set_headlights(on: bool)
##   set_disc_heat(wheel: String, heat: float)   wheel = "FL"/"FR"/"RL"/"RR", heat 0..1
##   set_paint(color: Color, flop: Color = auto)
##   get_wheel(id) / get_caliper(id) -> Node3D    (cached BEFORE the vehicle reparents them)

@export var model_scene: PackedScene = preload("res://assets/cars/ccgt/ccgt.glb")
@export var paint_color: Color = Color(0.62, 0.035, 0.03)
@export var headlights_on: bool = false
@export var dirt: float = 0.0

const SHADERS := {
	"paint": preload("res://shaders/car_paint.gdshader"),
	"carbon": preload("res://shaders/carbon.gdshader"),
	"glass": preload("res://shaders/car_glass.gdshader"),
	"light": preload("res://shaders/car_light.gdshader"),
	"disc": preload("res://shaders/brake_disc.gdshader"),
	"tire": preload("res://shaders/tire.gdshader"),
}

const CAR_LAYER := 2          # render layer bit 2: the car itself
const GRASS_LAYER := 4        # render layer bit 3: GPU grass (too costly for the probe)
@export var reflection_quality: int = 2
var _probe: ReflectionProbe
var driver: DriverRig
var model: Node3D
var wheels := {}
var calipers := {}
var _mats := {}
var _taillights: Array[GeometryInstance3D] = []
var _head_lights: Array[SpotLight3D] = []
var _head_bulbs: Array[GeometryInstance3D] = []
var _brake_glow: OmniLight3D
var _brake := 0.0
var _reverse := false


func _ready() -> void:
	model = model_scene.instantiate()
	add_child(model)
	_build_materials()
	_apply_materials(model)
	for id in ["FL", "FR", "RL", "RR"]:
		wheels[id] = model.find_child("Wheel_" + id, true, false)
		calipers[id] = model.find_child("Caliper_" + id, true, false)
	for n in model.find_children("Taillight_*", "GeometryInstance3D", true, false):
		_taillights.append(n)
	_make_lamps()
	set_headlights(headlights_on)
	set_brake(0.0)
	var fx := CarEffects.new()
	fx.name = "Effects"
	add_child(fx)
	# driver + steering wheel
	var meta_path := "res://assets/cars/ccgt/ccgt_meta.json"
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path)) if FileAccess.file_exists(meta_path) else {}
	driver = DriverRig.new()
	driver.name = "Driver"
	model.add_child(driver)
	driver.setup(model, meta)
	# car meshes on render layer 2 so the car's own reflection probe can skip them
	for gi in find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).layers = CAR_LAYER
	_make_reflection_probe()
	set_reflection_quality(reflection_quality)
	# the car's own lamps light the road, not the car/driver (red brake glow was tinting the cabin)
	if _brake_glow:
		_brake_glow.light_cull_mask = 0xFFFFF & ~CAR_LAYER
	for s in _head_lights:
		s.light_cull_mask = 0xFFFFF & ~CAR_LAYER


# ------------------------------------------------------------------------------------------------
# materials
# ------------------------------------------------------------------------------------------------
func _shader_mat(shader: Shader, params := {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m


func _std(albedo: Color, metal: float, rough: float, extra := {}) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = metal
	m.roughness = rough
	for k in extra:
		m.set(k, extra[k])
	return m


func _build_materials() -> void:
	_mats["paint"] = _shader_mat(SHADERS.paint, {"dirt": dirt})
	_mats["carbon"] = _shader_mat(SHADERS.carbon)
	_mats["carbon_matte"] = _shader_mat(SHADERS.carbon, {"matte": true})
	_mats["glass"] = _shader_mat(SHADERS.glass)
	_mats["headlight_glass"] = _shader_mat(SHADERS.glass, {"tint": Color(0.6, 0.62, 0.65), "alpha_facing": 0.06, "alpha_grazing": 0.8})
	_mats["taillight"] = _shader_mat(SHADERS.light, {"base_lamp": 0.15})
	_mats["headlight_bulb"] = _shader_mat(SHADERS.light, {
		"lens_color": Color(0.85, 0.87, 0.9), "emit_color": Color(1.0, 0.95, 0.88), "emit_energy": 25.0})
	_mats["brake_disc"] = _shader_mat(SHADERS.disc)
	_mats["tire"] = _shader_mat(SHADERS.tire)
	_mats["headlight_chrome"] = _std(Color(0.92, 0.92, 0.94), 1.0, 0.05,
			{"emission_enabled": true, "emission": Color(1.0, 0.97, 0.92), "emission_energy_multiplier": 0.0})
	_mats["chrome"] = _std(Color(0.9, 0.9, 0.92), 1.0, 0.06)
	_mats["rim"] = _std(Color(0.80, 0.81, 0.83), 1.0, 0.36, {"clearcoat_enabled": true, "clearcoat": 0.8, "clearcoat_roughness": 0.06})
	_mats["caliper"] = _std(Color(0.95, 0.62, 0.02), 0.0, 0.3, {"clearcoat_enabled": true, "clearcoat": 1.0})
	_mats["exhaust"] = _std(Color(0.36, 0.33, 0.30), 1.0, 0.3, {"anisotropy_enabled": true, "anisotropy": 0.6})
	_mats["black_plastic"] = _std(Color(0.025, 0.025, 0.027), 0.0, 0.55)
	_mats["interior"] = _std(Color(0.04, 0.038, 0.038), 0.0, 0.8)
	set_paint(paint_color)


func _material_for(src: Material, node_name: String) -> Material:
	if src == null:
		return null
	var key := src.resource_name.to_lower()
	# Blender may suffix duplicates (".001")
	var dot := key.find(".")
	if dot > 0:
		key = key.substr(0, dot)
	if key == "carbon" and (node_name == "Body"):
		return _mats["carbon"]
	return _mats.get(key, null)


func _apply_materials(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_inst := mi as MeshInstance3D
		if mesh_inst.mesh == null:
			continue
		for s in mesh_inst.mesh.get_surface_count():
			var m := _material_for(mesh_inst.mesh.surface_get_material(s), mesh_inst.name)
			if m:
				mesh_inst.set_surface_override_material(s, m)
				if (m as ShaderMaterial) and (m as ShaderMaterial).shader == SHADERS.light and m == _mats["headlight_bulb"]:
					if not _head_bulbs.has(mesh_inst):
						_head_bulbs.append(mesh_inst)


# ------------------------------------------------------------------------------------------------
# lamps
# ------------------------------------------------------------------------------------------------
func _headlight_cookie() -> ImageTexture:
	# Low-beam pattern: bright wide band below a sharp cut-off line, with the classic kick-up to the right.
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var u := (x + 0.5) / size * 2.0 - 1.0
			var v := (y + 0.5) / size * 2.0 - 1.0          # +v = down in projector space
			var cutoff := -0.02 - (0.12 * clampf((u - 0.05) / 0.35, 0.0, 1.0))
			var below := smoothstep(cutoff - 0.03, cutoff + 0.03, v)
			var r := sqrt(u * u * 0.7 + v * v * 1.6)
			var falloff := clampf(1.0 - r, 0.0, 1.0)
			var hot := exp(-((u * u) * 5.0 + pow(v - 0.06, 2.0) * 60.0))
			var i := clampf((falloff * 0.65 + hot * 0.9) * below + falloff * 0.06, 0.0, 1.0)
			img.set_pixel(x, y, Color(i, i * 0.98, i * 0.94))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _make_lamps() -> void:
	var cookie := _headlight_cookie()
	for side in ["L", "R"]:
		var marker := model.find_child("Headlight_" + side, true, false) as Node3D
		if marker == null:
			continue
		var s := SpotLight3D.new()
		s.name = "HeadBeam_" + side
		s.light_color = Color(1.0, 0.96, 0.9)
		s.light_energy = 30.0
		s.spot_range = 110.0
		s.spot_angle = 38.0
		s.spot_attenuation = 0.6
		s.shadow_enabled = true
		s.light_projector = cookie
		s.light_specular = 0.6
		marker.add_child(s)
		# aim straight ahead, slightly down (forward = -Z)
		s.rotation = Vector3(deg_to_rad(-0.7), 0.0, 0.0)
		_head_lights.append(s)
	_brake_glow = OmniLight3D.new()
	_brake_glow.name = "BrakeGlow"
	_brake_glow.light_color = Color(1.0, 0.08, 0.04)
	_brake_glow.omni_range = 4.0
	_brake_glow.light_energy = 0.0
	_brake_glow.shadow_enabled = false
	var bb := _taillight_center()
	_brake_glow.position = bb + Vector3(0, 0, 0.6)
	model.add_child(_brake_glow)


func _taillight_center() -> Vector3:
	if _taillights.is_empty():
		return Vector3(0, 0.6, 2.1)
	var c := Vector3.ZERO
	for t in _taillights:
		c += t.global_position - global_position
	return c / _taillights.size()


# ------------------------------------------------------------------------------------------------
# API
# ------------------------------------------------------------------------------------------------
func set_brake(v: float) -> void:
	_brake = clampf(v, 0.0, 1.0)
	var on := 1.0 if _brake > 0.05 else 0.0
	var lamp := lerpf(0.15, 1.0, on)
	for t in _taillights:
		t.set_instance_shader_parameter("lamp", lamp)
	if _brake_glow:
		_brake_glow.light_energy = on * 1.2


func set_reverse(on: bool) -> void:
	_reverse = on


func set_headlights(on: bool) -> void:
	headlights_on = on
	for s in _head_lights:
		s.visible = on
	for b in _head_bulbs:
		b.set_instance_shader_parameter("lamp", 1.0 if on else 0.0)
	# reflectors glow when the lamps are on (fakes light scattering inside the housing)
	(_mats["headlight_chrome"] as StandardMaterial3D).emission_energy_multiplier = 0.35 if on else 0.0


func set_disc_heat(wheel_id: String, heat: float) -> void:
	var w: Node = wheels.get(wheel_id)
	if w is GeometryInstance3D:
		(w as GeometryInstance3D).set_instance_shader_parameter("heat", clampf(heat, 0.0, 1.0))


## Real-time reflections of the surroundings on the paint/glass (the sky alone looks flat).
## 0 = off, 1 = low (shorter range), 2 = high.
func set_reflection_quality(q: int) -> void:
	reflection_quality = clampi(q, 0, 2)
	if _probe == null:
		return
	_probe.visible = reflection_quality > 0
	_probe.max_distance = 140.0 if reflection_quality == 1 else 420.0
	_probe.mesh_lod_threshold = 8.0 if reflection_quality == 1 else 3.0


func _make_reflection_probe() -> void:
	_probe = ReflectionProbe.new()
	_probe.name = "ReflectionProbe"
	_probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	_probe.size = Vector3(9.0, 5.0, 9.0)
	_probe.position = Vector3(0, 0.8, 0)
	_probe.box_projection = false
	_probe.interior = false
	_probe.enable_shadows = false
	_probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	_probe.intensity = 1.0
	_probe.blend_distance = 1.0
	_probe.cull_mask = 0xFFFFF & ~CAR_LAYER & ~GRASS_LAYER
	add_child(_probe)


func set_paint(color: Color, flop: Color = Color(-1, -1, -1)) -> void:
	paint_color = color
	if flop.r < 0.0:
		flop = Color(color.r * 0.22, color.g * 0.22, color.b * 0.25)
	var m: ShaderMaterial = _mats["paint"]
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("flop_color", flop)
	m.set_shader_parameter("flake_tint", color.lerp(Color.WHITE, 0.6))


func set_dirt(v: float) -> void:
	dirt = v
	(_mats["paint"] as ShaderMaterial).set_shader_parameter("dirt", v)


func get_wheel(id: String) -> Node3D:
	return wheels.get(id)


func get_caliper(id: String) -> Node3D:
	return calipers.get(id)
