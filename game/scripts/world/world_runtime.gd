extends Node3D
## Runtime glue for res://scenes/world/world.scn (built by scripts/world/build_world.gd).
##   set_focus(node)            the node terrain LOD, collision and shadows follow (the player car)
##   surface_at(world_pos)      physics surface key under a point ("grass", "rock", ...), used by SurfaceDB
##   get_spawn(i) -> Transform3D  spawn transforms on the roads
##   sky                         the SkyRig (time of day)

const TERRAIN_SURFACE := ["grass", "grass", "rock", "gravel", "dirt", "sand", "gravel", "dirt"]   # by terrain material id
const ROADS_JSON := "res://assets/world/gen/roads.json"

@export var start_hour: float = 17.0
@export var dynamic_time: bool = false
@export var day_length_minutes: float = 48.0

var terrain: Node3D
var sky: SkyRig
var focus: Node3D
var spawns: Array[Transform3D] = []


func _ready() -> void:
	terrain = get_node_or_null("Terrain3D")
	if terrain:
		terrain.set_meta("surface_provider", self)
		terrain.collision_mode = 1          # Terrain3DCollision.DYNAMIC_GAME
		terrain.collision_radius = 96
		terrain.collision_shape_size = 16
	sky = SkyRig.new()
	sky.name = "Sky"
	sky.radiance_quality = false
	sky.shadow_max_distance = 300.0
	sky.rotation_rad = deg_to_rad(35.0)
	add_child(sky)
	sky.set_time(start_hour)
	_setup_atmosphere()
	_load_spawns()
	_create_tree_colliders()


func _setup_atmosphere() -> void:
	var env := sky.environment
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.62, 0.7, 0.8)
	env.fog_sun_scatter = 0.25
	env.fog_aerial_perspective = 0.85
	env.fog_sky_affect = 0.0
	env.fog_depth_begin = 300.0
	env.fog_depth_end = 5000.0
	env.fog_depth_curve = 1.6
	env.fog_density = 0.6


func set_focus(node: Node3D) -> void:
	focus = node
	if terrain:
		terrain.clipmap_target = node
		terrain.collision_target = node


func _process(delta: float) -> void:
	if dynamic_time and sky:
		sky.set_time(sky.hours + delta * 24.0 / (day_length_minutes * 60.0))
	if sky and focus:
		sky.global_position = focus.global_position


func surface_at(world_pos: Vector3) -> String:
	if terrain == null:
		return "grass"
	var id: Vector3 = terrain.data.get_texture_id(world_pos)
	if is_nan(id.x):
		return "grass"
	var m := int(id.y) if id.z > 0.5 else int(id.x)
	return TERRAIN_SURFACE[clampi(m, 0, TERRAIN_SURFACE.size() - 1)]


func _load_spawns() -> void:
	if not FileAccess.file_exists(ROADS_JSON):
		return
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ROADS_JSON))
	for r in meta.roads:
		if not r.paved:
			continue
		var pts: Array = r.points
		for k in [10, pts.size() / 3, (2 * pts.size()) / 3]:
			if k + 1 >= pts.size():
				continue
			var a := Vector3(pts[k][0], pts[k][1], pts[k][2])
			var b := Vector3(pts[k + 1][0], pts[k + 1][1], pts[k + 1][2])
			var fwd := (b - a).normalized()
			# drive on the right-hand lane
			var right := fwd.cross(Vector3.UP).normalized()
			var half: float = r.width[k] * 0.5
			var pos := a + right * (half * 0.5) + Vector3(0, 0.6, 0)
			spawns.append(Transform3D(Basis.looking_at(fwd, Vector3.UP), pos))


func get_spawn(i: int = 0) -> Transform3D:
	if spawns.is_empty():
		return Transform3D(Basis(), Vector3(0, 50, 0))
	return spawns[i % spawns.size()]


## Trunk colliders straight in the physics server (no nodes): one static body per 512 m cell.
func _create_tree_colliders() -> void:
	var path := "res://assets/world/tree_colliders.bin"
	if not FileAccess.file_exists(path):
		return
	var data := FileAccess.get_file_as_bytes(path).to_float32_array()
	var cells := {}
	var space := get_world_3d().space
	for i in data.size() / 4:
		var x := data[4 * i]
		var y := data[4 * i + 1]
		var z := data[4 * i + 2]
		var r := data[4 * i + 3]
		var key := Vector2i(int(floor(x / 512.0)), int(floor(z / 512.0)))
		if not cells.has(key):
			var b := PhysicsServer3D.body_create()
			PhysicsServer3D.body_set_mode(b, PhysicsServer3D.BODY_MODE_STATIC)
			PhysicsServer3D.body_set_space(b, space)
			PhysicsServer3D.body_attach_object_instance_id(b, get_instance_id())
			cells[key] = b
			_tree_bodies.append(b)
		var shape := PhysicsServer3D.cylinder_shape_create()
		PhysicsServer3D.shape_set_data(shape, {"radius": maxf(r, 0.08), "height": 6.0})
		_tree_shapes.append(shape)
		PhysicsServer3D.body_add_shape(cells[key], shape, Transform3D(Basis(), Vector3(x, y + 2.5, z)))


var _tree_bodies: Array[RID] = []
var _tree_shapes: Array[RID] = []


func _exit_tree() -> void:
	for b in _tree_bodies:
		PhysicsServer3D.free_rid(b)
	for s in _tree_shapes:
		PhysicsServer3D.free_rid(s)
