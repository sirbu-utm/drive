class_name TestWorld
extends RefCounted
## Builders for flat test grounds, slopes, ramps and curbs (used by tests and by the test track scene).
## Convention: the main ground plane has its top surface at y = 0.

static func add_box(parent: Node, size: Vector3, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO,
		surface: String = "asphalt", color: Color = Color(0.2, 0.2, 0.22), visible: bool = true) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	b.add_child(cs)
	b.position = pos
	b.rotation_degrees = rot_deg
	b.set_meta("surface", surface)
	b.collision_layer = 1
	b.collision_mask = 0
	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	b.physics_material_override = pm
	if visible:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.9
		mi.material_override = m
		b.add_child(mi)
	parent.add_child(b)
	return b


static func add_ground(parent: Node, extent: float = 1200.0, surface: String = "asphalt", visible: bool = false) -> StaticBody3D:
	return add_box(parent, Vector3(extent, 4.0, extent), Vector3(0, -2.0, 0), Vector3.ZERO, surface, Color(0.18, 0.18, 0.2), visible)


## A plane inclined by `pitch_deg` (nose up positive when driving towards -Z) that blends from the flat ground.
## Returns the body. The incline starts at z = z0 and continues towards -Z.
static func add_incline(parent: Node, z0: float, length: float, pitch_deg: float, width: float = 30.0,
		surface: String = "asphalt", visible: bool = false) -> StaticBody3D:
	var a := deg_to_rad(pitch_deg)
	var thick := 2.0
	# centre of the top surface segment
	var cz := z0 - cos(a) * length * 0.5
	var cy := sin(a) * length * 0.5
	var pos := Vector3(0.0, cy, cz) - Vector3(0.0, cos(a), -sin(a)).rotated(Vector3.RIGHT, 0.0) * 0.0
	var n := Vector3(0.0, cos(a), sin(a))          # surface normal (rotated about X)
	pos -= n * thick * 0.5
	return add_box(parent, Vector3(width, thick, length), pos, Vector3(rad_to_deg(a), 0.0, 0.0), surface, Color(0.3, 0.28, 0.25), visible)


static func add_light_and_sky(parent: Node) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.25, 0.45, 0.8)
	sm.sky_horizon_color = Color(0.75, 0.82, 0.9)
	sm.ground_horizon_color = Color(0.75, 0.82, 0.9)
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	parent.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	parent.add_child(sun)
