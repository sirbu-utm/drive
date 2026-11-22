class_name Minimap
extends Control
## Round heading-up minimap. The map texture is built at runtime: world overview (map_preview.png, dimmed, if present)
## plus the road lines from roads.json; a shader crops/rotates it around the player. The player arrow is drawn on top.

const MAP_PX := 1024
const PREVIEW := "res://assets/world/gen/map_preview.png"

const SHADER_CODE := """
shader_type canvas_item;
uniform sampler2D map : filter_linear_mipmap, repeat_disable;
uniform vec2 center = vec2(0.5);
uniform float view = 0.16;
uniform float angle = 0.0;
uniform vec4 ring_color : source_color = vec4(0.95, 0.95, 0.95, 0.9);
void fragment() {
	vec2 p = UV - 0.5;
	float r = length(p) * 2.0;
	vec2 rp = vec2(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle));
	vec2 uv = center + rp * view;
	vec4 c = texture(map, uv);
	float inside = 1.0 - smoothstep(0.985, 1.0, r);
	float border = smoothstep(0.93, 0.95, r) * inside;
	vec3 col = mix(c.rgb, ring_color.rgb, border);
	COLOR = vec4(col, inside * mix(0.92, 1.0, border));
}
"""

var net: RoadNet
var vehicle: Node3D
var view_metres := 700.0               # width of the visible area
var _tex: ImageTexture
var _mat: ShaderMaterial
var _arrow_color := Color(1.0, 0.82, 0.1)
var world_size := 4096.0
var world_origin := Vector2(-2048.0, -2048.0)


func _ready() -> void:
	custom_minimum_size = Vector2(230, 230)
	size = Vector2(230, 230)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if net == null:
		net = RoadNet.new()
	world_size = net.world_size
	world_origin = net.origin
	_build_texture()
	var sh := Shader.new()
	sh.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("map", _tex)
	material = _mat
	var arrow := Arrow.new()
	arrow.set_anchors_preset(Control.PRESET_FULL_RECT)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.use_parent_material = false
	add_child(arrow)


func _build_texture() -> void:
	var img := Image.create(MAP_PX, MAP_PX, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.08, 0.1, 0.12))
	if ResourceLoader.exists(PREVIEW):
		var pv: Texture2D = load(PREVIEW)
		var src := pv.get_image()
		if src != null:
			src.convert(Image.FORMAT_RGBA8)
			if src.get_width() != MAP_PX:
				src.resize(MAP_PX, MAP_PX)
			# dim + desaturate a little so the road lines pop
			for y in MAP_PX:
				for x in MAP_PX:
					var c := src.get_pixel(x, y)
					var g := (c.r + c.g + c.b) / 3.0
					img.set_pixel(x, y, Color(lerpf(c.r, g, 0.35) * 0.62, lerpf(c.g, g, 0.35) * 0.62, lerpf(c.b, g, 0.35) * 0.66, 1.0))
	var colors := {"country": Color(0.97, 0.97, 0.97), "mountain": Color(1.0, 0.75, 0.2), "runway": Color(0.85, 0.9, 1.0),
		"taxi": Color(0.7, 0.72, 0.78), "dirt": Color(0.75, 0.5, 0.25)}
	for r in net.roads:
		var col: Color = colors.get(r["kind"], Color(0.9, 0.9, 0.9))
		var rad := 1.6 if r["kind"] != "runway" else 2.4
		var pts: PackedVector3Array = r["pts"]
		for i in range(1, pts.size()):
			_line(img, _to_px(pts[i - 1]), _to_px(pts[i]), col, rad)
	_tex = ImageTexture.create_from_image(img)


func _to_px(p: Vector3) -> Vector2:
	return Vector2((p.x - world_origin.x) / world_size, (p.z - world_origin.y) / world_size) * float(MAP_PX)


static func _line(img: Image, a: Vector2, b: Vector2, col: Color, rad: float) -> void:
	var d := a.distance_to(b)
	var steps := maxi(int(ceil(d)), 1)
	var ir := int(ceil(rad))
	for s in steps + 1:
		var p := a.lerp(b, float(s) / float(steps))
		for dy in range(-ir, ir + 1):
			for dx in range(-ir, ir + 1):
				if dx * dx + dy * dy <= rad * rad:
					var x := int(p.x) + dx
					var y := int(p.y) + dy
					if x >= 0 and y >= 0 and x < MAP_PX and y < MAP_PX:
						img.set_pixel(x, y, col)


func _process(_dt: float) -> void:
	if vehicle == null or _mat == null:
		return
	var xf := vehicle.get_global_transform_interpolated()
	var p := xf.origin
	var f := -xf.basis.z
	var c := Vector2((p.x - world_origin.x) / world_size, (p.z - world_origin.y) / world_size)
	_mat.set_shader_parameter("center", c)
	_mat.set_shader_parameter("view", view_metres / world_size)
	_mat.set_shader_parameter("angle", atan2(f.x, -f.z))
	queue_redraw()


func _draw() -> void:
	# the shader samples its own "map" uniform; the rect only provides UV 0..1
	if _tex != null:
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)


class Arrow extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var pts := PackedVector2Array([c + Vector2(0, -13), c + Vector2(9, 11), c + Vector2(0, 6), c + Vector2(-9, 11)])
		draw_colored_polygon(pts, Color(1.0, 0.82, 0.1))
		draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), Color(0, 0, 0, 0.9), 1.5, true)
