extends SceneTree
## Offline world builder (headless):  scripts/build_world.sh
## Reads pipeline/world/gen_world.py output (res://assets/world/gen/) and writes
##   res://assets/world/terrain/          Terrain3D region data
##   res://assets/world/terrain_tex/*.res  packed terrain textures (albedo+height, normal+roughness, BC3 + mips)
##   res://assets/world/terrain_assets.tres, terrain_material.tres, ocean_material.tres
##   res://assets/world/roads.scn          road meshes + colliders + guard rails
##   res://scenes/world/world.scn          the playable world (terrain, roads, ocean, sky; no vehicle)

const GEN := "res://assets/world/gen/"
const OUT := "res://assets/world/"
const TEX := "res://assets/textures/"

## terrain material ids (must match pipeline/world/gen_world.py MATERIALS)
const TERRAIN_TEX := [
	# name, poly haven set, uv_scale (repeats per metre), roughness mod, normal depth
	["grass", "rocky_terrain_02", 0.1, 0.0, 1.0],
	["meadow", "leafy_grass", 0.08, 0.0, 1.0],
	["rock", "mossy_rock", 0.04, 0.0, 1.3],
	["scree", "rocky_trail", 0.07, 0.0, 1.0],
	["dirt", "dirt_floor", 0.12, 0.0, 1.0],
	["sand", "coast_sand_01", 0.09, 0.0, 0.8],
	["gravel", "gravel_floor_02", 0.22, 0.0, 1.0],
	["forest", "brown_mud_leaves_01", 0.1, 0.0, 1.0, Color(0.8, 0.86, 0.74)],
]
const ROAD_KIND := {"country": 0, "highway": 1, "mountain": 2, "runway": 3, "taxi": 4}
const CAMBER := {"country": 0.02, "highway": 0.02, "mountain": 0.025, "runway": 0.01, "taxi": 0.015}

var N := 4096
var heights: PackedFloat32Array


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GEN + "roads.json"))
	N = int(meta.size)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT + "terrain"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT + "terrain_tex"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes/world"))
	heights = FileAccess.get_file_as_bytes(GEN + "height.r32").to_float32_array()

	var world := Node3D.new()
	world.name = "World"
	world.set_script(load("res://scripts/world/world_runtime.gd"))

	var terrain := _build_terrain(world)
	print("[build_world] terrain done (%d ms)" % (Time.get_ticks_msec() - t0))
	var roads := _build_roads(meta, world)
	print("[build_world] roads done (%d ms)" % (Time.get_ticks_msec() - t0))
	_build_vegetation(world)
	print("[build_world] vegetation done (%d ms)" % (Time.get_ticks_msec() - t0))

	_own(world, world)
	var ps := PackedScene.new()
	var err := ps.pack(world)
	if err != OK:
		push_error("pack failed %d" % err)
	err = ResourceSaver.save(ps, "res://scenes/world/world.scn")
	print("[build_world] saved world.scn err=%d (%d ms)" % [err, Time.get_ticks_msec() - t0])
	quit(0)


func _own(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		if c.scene_file_path == "":
			_own(c, owner_node)


# ------------------------------------------------------------------------------------------------
# terrain
# ------------------------------------------------------------------------------------------------
func _load_img(path: String) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		push_error("cannot load " + path)
	return img


func _pack_textures(set_name: String) -> Array:
	var base := TEX + set_name + "/" + set_name
	var alb_path := OUT + "terrain_tex/%s_alb_h.res" % set_name
	var nrm_path := OUT + "terrain_tex/%s_nrm_r.res" % set_name
	if not (FileAccess.file_exists(alb_path) and FileAccess.file_exists(nrm_path)):
		var diff := _load_img(base + "_diff_2k.jpg")
		var disp := _load_img(base + "_disp_2k.jpg")
		var nor := _load_img(base + "_nor_gl_2k.jpg")
		var arm := _load_img(base + "_arm_2k.jpg")
		var ah: Image = Terrain3DUtil.pack_image(diff, disp, null, false, false, true, 0, 0)
		var nr: Image = Terrain3DUtil.pack_image(nor, arm, null, false, false, false, 1, 0)
		for pair in [[ah, alb_path], [nr, nrm_path]]:
			var img: Image = pair[0]
			if img.get_width() != 2048:
				img.resize(2048, 2048, Image.INTERPOLATE_LANCZOS)
			img.generate_mipmaps()
			img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
			ResourceSaver.save(ImageTexture.create_from_image(img), pair[1])
	return [load(alb_path), load(nrm_path)]


func _build_terrain(world: Node3D) -> Node3D:
	var t: Terrain3D = Terrain3D.new()
	t.name = "Terrain3D"
	world.add_child(t)
	t.region_size = 1024
	t.vertex_spacing = 1.0
	print("[build_world] scene region_size=", t.region_size)
	t.mesh_lods = 8
	t.mesh_size = 64

	var mat := Terrain3DMaterial.new()
	mat.world_background = Terrain3DMaterial.NONE
	mat.auto_shader_enabled = false
	mat.dual_scaling_enabled = true
	mat.macro_variation_enabled = true
	mat.projection_enabled = true
	mat.texture_filtering = Terrain3DMaterial.LINEAR_ANISOTROPIC
	ResourceSaver.save(mat, OUT + "terrain_material.tres")
	t.material = load(OUT + "terrain_material.tres")

	var assets := Terrain3DAssets.new()
	for i in TERRAIN_TEX.size():
		var d: Array = TERRAIN_TEX[i]
		var tx := _pack_textures(d[1])
		var ta := Terrain3DTextureAsset.new()
		ta.name = d[0]
		ta.albedo_texture = tx[0]
		ta.normal_texture = tx[1]
		ta.uv_scale = d[2]
		ta.normal_depth = d[4]
		ta.detiling_rotation = 0.35
		ta.detiling_shift = 0.4
		if d.size() > 5:
			ta.albedo_color = d[5]
		assets.set_texture_asset(i, ta)
	ResourceSaver.save(assets, OUT + "terrain_assets.tres")
	t.assets = load(OUT + "terrain_assets.tres")

	if not OS.get_cmdline_user_args().has("--skip-terrain-data"):
		var tdir := ProjectSettings.globalize_path(OUT + "terrain")
		for f in DirAccess.get_files_at(tdir):
			DirAccess.remove_absolute(tdir.path_join(f))
		var tmp: Terrain3D = Terrain3D.new()
		tmp.vertex_spacing = 1.0
		root.add_child(tmp)
		tmp.change_region_size(1024)
		print("[build_world] tmp region_size=", tmp.region_size)
		var hb := FileAccess.get_file_as_bytes(GEN + "height.r32")
		var cb := FileAccess.get_file_as_bytes(GEN + "control.r32")
		var himg := Image.create_from_data(N, N, false, Image.FORMAT_RF, hb)
		var cimg := Image.create_from_data(N, N, false, Image.FORMAT_RF, cb)
		tmp.data.import_images([himg, cimg, null], Vector3(-N / 2.0, 0.0, -N / 2.0), 0.0, 1.0)
		print("[build_world] terrain regions=", tmp.data.get_region_count(), " h(0,0)=", tmp.data.get_height(Vector3.ZERO))
		tmp.data.save_directory(OUT + "terrain")
		root.remove_child(tmp)
		tmp.free()
	t.data_directory = OUT + "terrain"

	var ocean := (load("res://addons/terrain_3d/extras/shaders/M_ocean.tres") as ShaderMaterial).duplicate(true)
	ocean.set_shader_parameter("sea_level", 0.0)
	ocean.set_shader_parameter("height_scale", 1.2)
	ocean.set_shader_parameter("water_color", Color(0.06, 0.16, 0.2))
	ResourceSaver.save(ocean, OUT + "ocean_material.tres")
	t.ocean_material = load(OUT + "ocean_material.tres")
	t.ocean_enabled = true
	return t


# ------------------------------------------------------------------------------------------------
# roads
# ------------------------------------------------------------------------------------------------
func height_at(x: float, z: float) -> float:
	var c := clampf(x + N / 2.0, 0.0, N - 1.001)
	var r := clampf(z + N / 2.0, 0.0, N - 1.001)
	var c0 := int(c)
	var r0 := int(r)
	var fc := c - c0
	var fr := r - r0
	var i := r0 * N + c0
	var h00 := heights[i]
	var h10 := heights[i + 1]
	var h01 := heights[i + N]
	var h11 := heights[i + N + 1]
	return lerpf(lerpf(h00, h10, fc), lerpf(h01, h11, fc), fr)


func _road_material(kind: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/road.gdshader")
	var set_name := "asphalt_track" if kind in ["runway", "taxi", "highway"] else "asphalt_02"
	var base := TEX + set_name + "/" + set_name
	m.set_shader_parameter("albedo_tex", load(base + "_diff_2k.jpg"))
	m.set_shader_parameter("normal_tex", load(base + "_nor_gl_2k.jpg"))
	m.set_shader_parameter("arm_tex", load(base + "_arm_2k.jpg"))
	m.set_shader_parameter("kind", ROAD_KIND[kind])
	m.set_shader_parameter("tile_m", 6.0 if kind == "runway" else 4.0)
	return m


func _build_roads(meta: Dictionary, world: Node3D) -> Node3D:
	var roads := Node3D.new()
	roads.name = "Roads"
	world.add_child(roads)
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.62, 0.64, 0.66)
	rail_mat.metallic = 0.85
	rail_mat.roughness = 0.38
	# ends of branch roads that join another paved road: their cross-fall fades to zero there so the branch
	# meets the parent's edge without a step
	for r in meta.roads:
		r["taper_start"] = false
		r["taper_end"] = false
		if not r.paved or r.closed:
			continue
		for which in ["start", "end"]:
			var pe: Array = r.points[0] if which == "start" else r.points[r.points.size() - 1]
			var pv := Vector3(pe[0], pe[1], pe[2])
			for o in meta.roads:
				if o == r or not o.paved:
					continue
				for k in range(0, o.points.size(), 1):
					var q: Array = o.points[k]
					if Vector2(q[0] - pv.x, q[2] - pv.z).length() < float(o.width[k]) * 0.5 + 1.5:
						r["taper_" + which] = true
						break
				if r["taper_" + which]:
					break
	for r in meta.roads:
		if not r.paved:
			continue
		var node := Node3D.new()
		node.name = r.name
		roads.add_child(node)
		_build_road(r, node, _road_material(r.kind))
		if r.kind in ["mountain", "country"]:
			_build_rails(r, node, rail_mat)
	return roads


func _frames(r: Dictionary) -> Dictionary:
	var pts: Array = r.points
	var n := pts.size()
	var closed: bool = r.closed
	var P := PackedVector3Array()
	P.resize(n)
	for i in n:
		P[i] = Vector3(pts[i][0], pts[i][1], pts[i][2])
	var S := PackedFloat32Array()
	S.resize(n)
	var R := PackedVector3Array()
	R.resize(n)
	var acc := 0.0
	for i in n:
		if i > 0:
			acc += P[i].distance_to(P[i - 1])
		S[i] = acc
		var a := P[(i - 1 + n) % n] if (closed or i > 0) else P[i]
		var b := P[(i + 1) % n] if (closed or i < n - 1) else P[i]
		var t := Vector3(b.x - a.x, 0.0, b.z - a.z).normalized()
		R[i] = t.cross(Vector3.UP).normalized()
	return {"P": P, "S": S, "R": R, "n": n, "len": acc}


func _build_road(r: Dictionary, parent: Node3D, mat: ShaderMaterial) -> void:
	var f := _frames(r)
	var P: PackedVector3Array = f.P
	var S: PackedFloat32Array = f.S
	var R: PackedVector3Array = f.R
	var n: int = f.n
	var total: float = f.len
	var widths: Array = r.width
	var camber0: float = CAMBER[r.kind]
	var cam_mul := PackedFloat32Array()
	cam_mul.resize(n)
	for i in n:
		var m := 1.0
		if r.get("taper_start", false):
			m = minf(m, smoothstep(0.0, 25.0, S[i]))
		if r.get("taper_end", false):
			m = minf(m, smoothstep(0.0, 25.0, total - S[i]))
		cam_mul[i] = m
	var camber := camber0
	# lateral profile: skirt, edge .. centre .. edge, skirt   (fractions of half width; skirt handled separately)
	var fr := [-1.0, -0.66, -0.33, 0.0, 0.33, 0.66, 1.0]
	var chunk := 75
	var start := 0
	var ci := 0
	while start < n - 1:
		var end := mini(start + chunk, n - 1)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var faces := PackedVector3Array()
		var cols := fr.size() + 2
		var verts := []
		for i in range(start, end + 1):
			var half: float = widths[i] * 0.5
			camber = camber0 * cam_mul[i]
			var row := []
			# left skirt
			var offs := [-(half + 0.45)]
			for k in fr:
				offs.append(k * half)
			offs.append(half + 0.45)
			for j in offs.size():
				var off: float = offs[j]
				var y: float = P[i].y - camber * absf(clampf(off, -half, half))
				if j == 0 or j == offs.size() - 1:
					y = P[i].y - camber * half - 0.4
				var v := P[i] + R[i] * off
				v.y = y
				row.append(v)
				st.set_uv(Vector2(off, S[i]))
				st.set_uv2(Vector2(half, total))
				st.add_vertex(v)
			verts.append(row)
		var rows := end - start + 1
		for i in rows - 1:
			for j in cols - 1:
				var a := i * cols + j
				var b := a + 1
				var c := a + cols
				var d := c + 1
				st.add_index(a)
				st.add_index(c)
				st.add_index(b)
				st.add_index(b)
				st.add_index(c)
				st.add_index(d)
				if j > 0 and j < cols - 2:     # collision: road top only (no skirts)
					faces.append_array([verts[i][j], verts[i][j + 1], verts[i + 1][j],
							verts[i][j + 1], verts[i + 1][j + 1], verts[i + 1][j]])
		# collision overlaps the next chunk by one row: separate trimesh bodies sharing only an edge let a
		# shape cast slip through the seam
		var nxt := end + 1
		if r.closed and nxt >= n - 1:
			nxt = 1 + (nxt - (n - 1))
		if nxt < n:
			var half_n: float = widths[nxt] * 0.5
			camber = camber0 * cam_mul[nxt]
			var extra := []
			for k in fr:
				var off2: float = k * half_n
				var v2 := P[nxt] + R[nxt] * off2
				v2.y = P[nxt].y - camber * absf(off2)
				extra.append(v2)
			var last: Array = verts[rows - 1]
			for j in range(1, cols - 2):
				var e := j - 1
				faces.append_array([last[j], last[j + 1], extra[e], last[j + 1], extra[e + 1], extra[e]])
		st.generate_normals()
		st.generate_tangents()
		var mesh := st.commit()
		var mi := MeshInstance3D.new()
		mi.name = "seg%03d" % ci
		mi.mesh = mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		var body := StaticBody3D.new()
		body.name = "col%03d" % ci
		body.set_meta("surface", "asphalt")
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		shape.backface_collision = true
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		parent.add_child(body)
		start = end
		ci += 1


## W-beam guard rails where the ground drops away more than 2.5 m beside the road.
func _build_rails(r: Dictionary, parent: Node3D, mat: Material) -> void:
	var f := _frames(r)
	var P: PackedVector3Array = f.P
	var R: PackedVector3Array = f.R
	var n: int = f.n
	var widths: Array = r.width
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.1, 0.9, 0.12)
	var posts := []
	var rail_parent := Node3D.new()
	rail_parent.name = "Rails"
	parent.add_child(rail_parent)
	for side in [-1.0, 1.0]:
		var run := []
		for i in n:
			var half: float = widths[i] * 0.5
			var off: float = side * (half + 1.4)
			var p := P[i] + R[i] * off
			var drop := P[i].y - height_at((P[i] + R[i] * side * (half + 6.0)).x, (P[i] + R[i] * side * (half + 6.0)).z)
			if drop > 2.5:
				run.append(Vector3(p.x, P[i].y, p.z))
			else:
				if run.size() >= 6:
					_rail_run(run, rail_parent, mat, posts)
				run = []
		if run.size() >= 6:
			_rail_run(run, rail_parent, mat, posts)
	if posts.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = post_mesh
	mm.instance_count = posts.size()
	var pt := []
	for p in posts:
		pt.append(Transform3D(Basis(), p))
	mm.buffer = _mm_buffer(pt)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "RailPosts"
	mmi.multimesh = mm
	mmi.material_override = mat
	parent.add_child(mmi)


func _rail_run(run: Array, parent: Node3D, mat: Material, posts: Array) -> void:
	# beam ribbon (two faces) 0.32 m tall centred at 0.6 m, plus box colliders every segment
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body := StaticBody3D.new()
	body.set_meta("surface", "concrete")
	parent.add_child(body)
	var acc := 0.0
	for i in run.size() - 1:
		var a: Vector3 = run[i]
		var b: Vector3 = run[i + 1]
		acc += a.distance_to(b)
		var lo := Vector3(0, 0.45, 0)
		var hi := Vector3(0, 0.78, 0)
		for q in [[a + lo, b + lo, a + hi], [b + lo, b + hi, a + hi], [a + hi, b + lo, a + lo], [a + hi, b + hi, b + lo]]:
			for v in q:
				st.add_vertex(v)
		if fmod(acc, 4.0) < a.distance_to(b):
			posts.append(a + Vector3(0, 0.45, 0))
		var seg := b - a
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.25, 0.9, seg.length() + 0.05)
		cs.shape = box
		var mid := (a + b) * 0.5 + Vector3(0, 0.45, 0)
		cs.transform = Transform3D(Basis.looking_at(seg.normalized(), Vector3.UP), mid)
		body.add_child(cs)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	parent.add_child(mi)


# ------------------------------------------------------------------------------------------------
# vegetation (impostor trees, MultiMesh chunks) + trunk collider list for world_runtime.gd
# ------------------------------------------------------------------------------------------------
const IMP_DIR := "res://assets/vegetation/impostors/"
const SPECIES := {
	"fir": ["fir_a", "fir_b", "fir_c"],
	"broadleaf": ["island_tree_01", "island_tree_02"],
	"sapling": ["sapling_a", "sapling_b"],
}
const TRUNK_R := {"fir_a": 0.32, "fir_b": 0.3, "fir_c": 0.3, "island_tree_01": 0.22, "island_tree_02": 0.2,
		"sapling_a": 0.1, "sapling_b": 0.1, "jacaranda": 0.45}
const VEG_CHUNK := 512.0


func _impostor(name: String) -> Dictionary:
	var jp := IMP_DIR + name + ".json"
	if not FileAccess.file_exists(jp) or not ResourceLoader.exists(IMP_DIR + name + "_albedo.png"):
		return {}
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(jp))
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/impostor.gdshader")
	m.set_shader_parameter("albedo_atlas", load(IMP_DIR + name + "_albedo.png"))
	m.set_shader_parameter("normal_atlas", load(IMP_DIR + name + "_normal.png"))
	m.set_shader_parameter("az_count", int(meta.az))
	var el: Array = meta.elevations
	m.set_shader_parameter("elevations_deg", Vector3(el[0], el[1], el[2]))
	var sc: Array = meta.scales
	m.set_shader_parameter("frame_scales", Vector3(sc[0], sc[1], sc[2]))
	m.set_shader_parameter("cols", int(meta.cols))
	m.set_shader_parameter("rows", int(meta.rows))
	var c: Array = meta.centre
	m.set_shader_parameter("centre", Vector3(c[0], c[1], c[2]))
	# quad with a conservative AABB (the vertex shader expands it to a camera-facing billboard)
	var R: float = max(float(meta.radius), float(sc.max()) * 0.75)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(1, 2, 0), Vector3(-1, 2, 0)])
	arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, m)
	var cv := Vector3(c[0], c[1], c[2])
	mesh.custom_aabb = AABB(cv - Vector3(R, R, R), Vector3(R, R, R) * 2.0)
	return {"mesh": mesh, "meta": meta}


func _build_vegetation(world: Node3D) -> void:
	var imps := {}
	for kind in SPECIES:
		for sp in SPECIES[kind]:
			var d := _impostor(sp)
			if not d.is_empty():
				imps[sp] = d
	var jac := _impostor("jacaranda")
	if not jac.is_empty():
		imps["jacaranda"] = jac
	if imps.is_empty():
		print("[build_world] no impostors baked yet, skipping vegetation")
		return
	var veg := Node3D.new()
	veg.name = "Vegetation"
	world.add_child(veg)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261121
	var buckets := {}
	var colliders := PackedFloat32Array()
	var count := 0
	for kind in SPECIES:
		var path: String = GEN + "trees_%s.f32" % kind
		if not FileAccess.file_exists(path):
			continue
		var data := FileAccess.get_file_as_bytes(path).to_float32_array()
		var avail: Array = SPECIES[kind].filter(func(n): return imps.has(n))
		if avail.is_empty():
			continue
		for i in data.size() / 4:
			var x := data[4 * i]
			var z := data[4 * i + 1]
			var yaw := data[4 * i + 2]
			var sc := data[4 * i + 3]
			var y := height_at(x, z)
			var sp: String = avail[rng.randi() % avail.size()]
			if kind == "broadleaf":
				sc *= 1.7          # island trees are compact (~5 m); grow them into proper woodland trees
			if kind == "broadleaf" and imps.has("jacaranda") and y < 25.0 and rng.randf() < 0.03:
				sp = "jacaranda"
				sc *= 0.7
			var key := "%s|%d|%d" % [sp, int(floor(x / VEG_CHUNK)), int(floor(z / VEG_CHUNK))]
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc), Vector3(x, y - 0.15, z)))
			colliders.append_array([x, y, z, TRUNK_R.get(sp, 0.2) * sc])
			count += 1
	for key in buckets:
		var parts: PackedStringArray = (key as String).split("|")
		var list: Array = buckets[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = imps[parts[0]].mesh
		mm.instance_count = list.size()
		var cc := Vector3((int(parts[1]) + 0.5) * VEG_CHUNK, 0.0, (int(parts[2]) + 0.5) * VEG_CHUNK)
		var ysum := 0.0
		for t in list:
			ysum += (t as Transform3D).origin.y
		cc.y = ysum / list.size()
		var local := []
		for t in list:
			local.append(Transform3D((t as Transform3D).basis, (t as Transform3D).origin - cc))
		mm.buffer = _mm_buffer(local)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%s_%s" % [parts[0], parts[1], parts[2]]
		mmi.position = cc
		mmi.multimesh = mm
		mmi.visibility_range_end = 2400.0
		mmi.visibility_range_end_margin = 300.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		veg.add_child(mmi)
	var f := FileAccess.open(OUT + "tree_colliders.bin", FileAccess.WRITE)
	f.store_buffer(colliders.to_byte_array())
	f.close()
	print("[build_world] trees placed: %d in %d multimeshes" % [count, buckets.size()])


## MultiMesh TRANSFORM_3D buffer (12 floats per instance, rows of the 3x4 matrix). Written directly because
## set_instance_transform() is a no-op under the headless dummy renderer and would save identity transforms.
func _mm_buffer(list: Array) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(list.size() * 12)
	for i in list.size():
		var t: Transform3D = list[i]
		var o := i * 12
		b[o + 0] = t.basis.x.x
		b[o + 1] = t.basis.y.x
		b[o + 2] = t.basis.z.x
		b[o + 3] = t.origin.x
		b[o + 4] = t.basis.x.y
		b[o + 5] = t.basis.y.y
		b[o + 6] = t.basis.z.y
		b[o + 7] = t.origin.y
		b[o + 8] = t.basis.x.z
		b[o + 9] = t.basis.y.z
		b[o + 10] = t.basis.z.z
		b[o + 11] = t.origin.z
	return b
