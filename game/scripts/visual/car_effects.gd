extends Node3D
class_name CarEffects
## Per-car visual effects driven by the physics read-outs of the parent Vehicle (found by walking up the tree):
##   * tyre smoke (asphalt) / dust (dirt, gravel, sand, grass) per wheel — GPU particles in world space
##   * skid marks — ring buffer of quads (one MultiMesh per car), persistent until overwritten
##   * brake disc glow — heat model from brake work, fed to CarVisual.set_disc_heat()
## Without a Vehicle ancestor (showcase scene) it does nothing.

const WHEEL_IDS := ["FL", "FR", "RL", "RR"]
const DUSTY := {"dirt": Color(0.42, 0.34, 0.25), "gravel": Color(0.55, 0.52, 0.48), "sand": Color(0.72, 0.64, 0.5),
		"grass": Color(0.36, 0.33, 0.24), "rock": Color(0.5, 0.48, 0.45)}
const SKID_CAPACITY := 3000
const SKID_SEG := 0.35

var vehicle: Node
var visual: Node
var _smoke: Array[GPUParticles3D] = []
var _dust: Array[GPUParticles3D] = []
var _skid_mm: MultiMesh
var _skid_next := 0
var _skid_last: Array = [null, null, null, null]
var _heat := [0.0, 0.0, 0.0, 0.0]
static var _smoke_tex: ImageTexture


func _ready() -> void:
	visual = get_parent()
	var n: Node = get_parent()
	while n != null:
		if n.get_class() == "RigidBody3D" and n.get("wheels") != null:
			vehicle = n
			break
		n = n.get_parent()
	if vehicle == null:
		set_process(false)
		return
	top_level = true
	global_transform = Transform3D.IDENTITY
	for i in 4:
		_smoke.append(_make_emitter(false))
		_dust.append(_make_emitter(true))
	_make_skids()


# ------------------------------------------------------------------------------------------------
func _smoke_texture() -> ImageTexture:
	if _smoke_tex:
		return _smoke_tex
	var s := 128
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.045
	noise.fractal_octaves = 4
	for y in s:
		for x in s:
			var u := (x + 0.5) / s * 2.0 - 1.0
			var v := (y + 0.5) / s * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var a := clampf(1.0 - r, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			var nz := 0.55 + 0.45 * noise.get_noise_2d(x, y)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a * nz * 1.3, 0.0, 1.0)))
	img.generate_mipmaps()
	_smoke_tex = ImageTexture.create_from_image(img)
	return _smoke_tex


func _make_emitter(dust: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 320 if dust else 480
	p.lifetime = 3.0 if dust else 3.6
	p.local_coords = false
	p.emitting = true
	p.amount_ratio = 0.0
	p.fixed_fps = 60
	p.interpolate = true
	p.visibility_aabb = AABB(Vector3(-40, -5, -40), Vector3(80, 30, 80))
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 75.0
	pm.initial_velocity_min = 0.4
	pm.initial_velocity_max = 1.8
	pm.gravity = Vector3(0, 0.35 if not dust else -0.2, 0)
	pm.damping_min = 1.2
	pm.damping_max = 2.2
	pm.inherit_velocity_ratio = 0.3
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.25
	pm.scale_min = 0.6
	pm.scale_max = 1.1
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.5))
	sc.add_point(Vector2(0.35, 2.0))
	sc.add_point(Vector2(1.0, 4.2 if not dust else 3.2))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.0))
	grad.add_point(0.05, Color(1, 1, 1, 0.75 if not dust else 0.8))
	grad.add_point(0.5, Color(1, 1, 1, 0.4 if not dust else 0.45))
	grad.set_color(grad.get_point_count() - 1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.angular_velocity_min = -25.0
	pm.angular_velocity_max = 25.0
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = _smoke_texture()
	m.albedo_color = Color(0.97, 0.97, 0.98) if not dust else Color(0.45, 0.38, 0.3)
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	m.backlight_enabled = true
	m.backlight = Color(0.55, 0.55, 0.55)
	m.roughness = 1.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.proximity_fade_enabled = true
	m.proximity_fade_distance = 0.8
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	quad.material = m
	p.draw_pass_1 = quad
	add_child(p)
	return p


func _make_skids() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.orientation = PlaneMesh.FACE_Y
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;
varying vec3 wpos;
float h21(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float vn(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y);
}
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float edge = smoothstep(0.0, 0.2, UV.x) * smoothstep(1.0, 0.8, UV.x);
	float grain = 0.7 + 0.3 * vn(wpos.xz * 9.0) * (0.6 + 0.4 * vn(wpos.xz * 1.3));
	ALBEDO = vec3(0.018, 0.017, 0.016);
	ROUGHNESS = 0.55;
	SPECULAR = 0.3;
	ALPHA = COLOR.a * edge * grain;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.render_priority = 1
	quad.material = mat
	_skid_mm = MultiMesh.new()
	_skid_mm.transform_format = MultiMesh.TRANSFORM_3D
	_skid_mm.use_colors = true
	_skid_mm.mesh = quad
	_skid_mm.instance_count = SKID_CAPACITY
	_skid_mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _skid_mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-4000, -100, -4000), Vector3(8000, 800, 8000))
	add_child(mmi)


func _add_skid(a: Vector3, b: Vector3, n: Vector3, width: float, strength: float) -> void:
	var d := b - a
	var len := d.length()
	if len < 0.05:
		return
	var fwd := d / len
	var right := fwd.cross(n).normalized()
	var up := right.cross(fwd).normalized()
	# quad local axes: X = across (width), Z = along (length), Y = up
	var basis := Basis(right * width, up, -fwd * len)
	var t := Transform3D(basis, (a + b) * 0.5 + n * 0.012)
	_skid_mm.set_instance_transform(_skid_next, t)
	_skid_mm.set_instance_color(_skid_next, Color(1, 1, 1, clampf(strength, 0.0, 0.85)))
	_skid_next = (_skid_next + 1) % SKID_CAPACITY
	_skid_mm.visible_instance_count = maxi(_skid_mm.visible_instance_count, mini(_skid_next if _skid_next > 0 else SKID_CAPACITY, SKID_CAPACITY))


# ------------------------------------------------------------------------------------------------
func _process(delta: float) -> void:
	var wheels: Array = vehicle.wheels
	var v_body: Vector3 = vehicle.linear_velocity
	var speed := v_body.length()
	var brake: float = vehicle.get("brake") if vehicle.get("brake") != null else 0.0
	for i in mini(4, wheels.size()):
		var w = wheels[i]
		var grounded: bool = w.is_grounded
		var key: String = w.surface_key
		var sr: float = absf(w.slip_ratio)
		var sa: float = absf(w.slip_angle)
		var gs: float = absf(w.ground_speed)
		# slip velocity in m/s: longitudinal (wheelspin/lock) + lateral (sliding)
		var slip_v := absf(w.slip_speed_x) + gs * sin(minf(sa, 1.2))
		var intensity := clampf((slip_v - 2.5) / 9.0, 0.0, 1.0) if grounded else 0.0
		var cp: Vector3 = w.contact_point
		var nrm: Vector3 = w.contact_normal
		var dusty := DUSTY.has(key)
		# smoke on hard surfaces, dust on loose ones (dust also from just rolling fast)
		var sm := _smoke[i]
		var du := _dust[i]
		sm.global_position = cp + nrm * 0.15
		du.global_position = cp + nrm * 0.1
		if dusty:
			sm.amount_ratio = 0.0
			var roll := clampf((speed - 6.0) / 25.0, 0.0, 1.0) * (0.35 if key == "grass" else 0.8)
			du.amount_ratio = clampf(maxf(intensity, roll), 0.0, 1.0) if grounded else 0.0
			(du.draw_pass_1.surface_get_material(0) as StandardMaterial3D).albedo_color = DUSTY[key]
		else:
			du.amount_ratio = 0.0
			sm.amount_ratio = intensity
		# skid marks
		var mark := grounded and (intensity > 0.05 or (dusty and speed > 3.0))
		if mark:
			var strength := intensity * 0.9 if not dusty else 0.35 + 0.4 * intensity
			var last = _skid_last[i]
			if last == null:
				_skid_last[i] = cp
			elif (cp - (last as Vector3)).length() > SKID_SEG:
				_add_skid(last, cp, nrm, w.width * 0.95, strength)
				_skid_last[i] = cp
		else:
			_skid_last[i] = null
		# brake disc heat: front discs do ~65 % of the work; cool down exponentially (faster with airflow)
		var bias := 0.65 if i < 2 else 0.35
		var work: float = brake * absf(w.omega) * float(w.radius) * bias * 0.0035
		_heat[i] = clampf(_heat[i] + work * delta - _heat[i] * (0.06 + speed * 0.002) * delta, 0.0, 1.0)
		if visual and visual.has_method("set_disc_heat"):
			visual.set_disc_heat(WHEEL_IDS[i], _heat[i])
