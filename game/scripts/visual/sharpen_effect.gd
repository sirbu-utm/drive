@tool
extends CompositorEffect
class_name SharpenEffect
## Contrast-adaptive sharpening (after AMD FidelityFX CAS, MIT) as a compute CompositorEffect.
## Runs on the HDR colour buffer after transparents: the per-pixel sharpening weight is computed from
## x/(1+x)-compressed values (CAS expects 0..1), then applied to the real HDR colours.

@export_range(0.0, 1.0, 0.01) var sharpness: float = 0.4

var rd: RenderingDevice
var shader: RID
var pipeline: RID

const CONTEXT := &"drive1_sharpen"
const TMP := &"src_copy"

const GLSL := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D dst_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D src_image;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float sharpness;
	float mode;      // 0 = sharpen src -> dst, 1 = plain copy src -> dst
} p;

vec3 ld(ivec2 c) {
	c = clamp(c, ivec2(0), ivec2(p.size) - 1);
	return max(imageLoad(src_image, c).rgb, vec3(0.0));
}
vec3 cmp(vec3 v) { return v / (1.0 + v); }

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	if (uv.x >= int(p.size.x) || uv.y >= int(p.size.y)) return;
	if (p.mode > 0.5) {
		imageStore(dst_image, uv, imageLoad(src_image, uv));
		return;
	}
	vec3 a = ld(uv + ivec2(-1, -1)), b = ld(uv + ivec2(0, -1)), c = ld(uv + ivec2(1, -1));
	vec3 d = ld(uv + ivec2(-1, 0)),  e = ld(uv),                f = ld(uv + ivec2(1, 0));
	vec3 g = ld(uv + ivec2(-1, 1)),  h = ld(uv + ivec2(0, 1)),  i = ld(uv + ivec2(1, 1));
	vec3 ca = cmp(a), cb = cmp(b), cc = cmp(c), cd = cmp(d), ce = cmp(e), cf = cmp(f), cg = cmp(g), ch = cmp(h), ci = cmp(i);
	vec3 mn = min(min(min(cd, ce), min(cf, cb)), ch);
	vec3 mn2 = min(mn, min(min(ca, cc), min(cg, ci)));
	mn += mn2;
	vec3 mx = max(max(max(cd, ce), max(cf, cb)), ch);
	vec3 mx2 = max(mx, max(max(ca, cc), max(cg, ci)));
	mx += mx2;
	vec3 amp = clamp(min(mn, 2.0 - mx) / max(mx, vec3(1e-4)), 0.0, 1.0);
	amp = sqrt(amp);
	float peak = -1.0 / mix(8.0, 5.0, clamp(p.sharpness, 0.0, 1.0));
	vec3 w = amp * peak;
	vec3 rcp = 1.0 / (1.0 + 4.0 * w);
	vec3 outc = max((b * w + d * w + f * w + h * w + e) * rcp, vec3(0.0));
	imageStore(dst_image, uv, vec4(outc, imageLoad(src_image, uv).a));
}
"""


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(_compile)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null and shader.is_valid():
		rd.free_rid(shader)


func _compile() -> void:
	if rd == null:
		return
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = GLSL
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("SharpenEffect: " + spirv.compile_error_compute)
		return
	shader = rd.shader_create_from_spirv(spirv)
	if shader.is_valid():
		pipeline = rd.compute_pipeline_create(shader)


func _render_callback(type: int, render_data: RenderData) -> void:
	if rd == null or type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or not pipeline.is_valid() or sharpness <= 0.001:
		return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if rsb == null:
		return
	var size := rsb.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	if rsb.has_texture(CONTEXT, TMP):
		var fmt := rd.texture_get_format(rsb.get_texture(CONTEXT, TMP))
		if fmt.width != size.x or fmt.height != size.y:
			rsb.clear_context(CONTEXT)
	if not rsb.has_texture(CONTEXT, TMP):
		var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		rsb.create_texture(CONTEXT, TMP, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage,
				RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	var groups := Vector2i((size.x - 1) / 8 + 1, (size.y - 1) / 8 + 1)
	var tmp := rsb.get_texture(CONTEXT, TMP)
	for view in rsb.get_view_count():
		var color := rsb.get_color_layer(view)
		# pass 1: sharpen colour -> tmp, pass 2: copy tmp -> colour (the colour buffer can't be copied from)
		_dispatch(tmp, color, size, groups, 0.0)
		_dispatch(color, tmp, size, groups, 1.0)


func _dispatch(dst: RID, src: RID, size: Vector2i, groups: Vector2i, mode: float) -> void:
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u0.binding = 0
	u0.add_id(dst)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(src)
	var uset := UniformSetCacheRD.get_cache(shader, 0, [u0, u1])
	var pc := PackedFloat32Array([size.x, size.y, sharpness, mode]).to_byte_array()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	rd.compute_list_end()
