// DRIVE1 — road surface: PBR asphalt in metric UVs + procedural markings, tyre wear and repair patches.
// Vertex data from scripts/world/build_world.gd:
//   UV  = (lateral offset m, signed, + = right of travel direction; arc length m)
//   UV2 = (half width m at this point; total road length m)
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D arm_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tile_m = 4.0;
uniform vec3 tint : source_color = vec3(0.78, 0.8, 0.84);
uniform int kind = 0;           // 0 country, 1 highway, 2 mountain, 3 runway, 4 taxiway
uniform float wear = 0.55;      // paint wear
uniform float track_strength = 0.35;
uniform vec3 white_paint : source_color = vec3(0.86, 0.86, 0.82);
uniform vec3 yellow_paint : source_color = vec3(0.9, 0.66, 0.1);

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

// 1 inside |x - c| < w/2 (anti-aliased)
float band(float x, float c, float w) {
	float aa = max(fwidth(x), 1e-4) * 0.8;
	return 1.0 - smoothstep(-aa, aa, abs(x - c) - w * 0.5);
}

// 1 for `on` metres every `period` metres
float dash(float s, float on, float period, float phase) {
	float f = mod(s + phase, period);
	float aa = max(fwidth(s), 1e-4) * 0.8;
	return smoothstep(-aa, aa, f) * (1.0 - smoothstep(on - aa, on + aa, f));
}

void fragment() {
	float off = UV.x;
	float s = UV.y;
	float half_w = UV2.x;
	float total = UV2.y;
	float aoff = abs(off);
	vec2 tuv = vec2(off, s) / tile_m;

	vec3 alb = texture(albedo_tex, tuv).rgb * tint;
	vec3 arm = texture(arm_tex, tuv).rgb;
	vec3 nrm = texture(normal_tex, tuv).rgb;
	float rough = arm.g;

	// large-scale tonal variation and darker repair patches
	float n1 = vnoise(vec2(off, s) * 0.06);
	float n2 = vnoise(vec2(off * 0.35, s * 0.045) + 17.0);
	alb *= 0.86 + 0.28 * n1;
	float patch = smoothstep(0.66, 0.7, n2) * (kind == 3 ? 0.3 : 1.0);
	alb = mix(alb, alb * 0.62, patch * 0.85);
	rough = mix(rough, rough * 0.85, patch);

	// tyre tracks: polished, darker bands in each lane
	int lanes = kind == 1 ? 2 : 1;
	float lane_w = half_w / float(lanes);
	float tracks = 0.0;
	if (kind != 3) {
		for (int i = 0; i < 2; i++) {
			if (i >= lanes) break;
			float c = (float(i) + 0.5) * lane_w;
			tracks += exp(-pow((aoff - (c - 0.8)) / 0.38, 2.0)) + exp(-pow((aoff - (c + 0.8)) / 0.38, 2.0));
		}
	}
	tracks = clamp(tracks, 0.0, 1.0) * track_strength * (0.7 + 0.6 * n1);
	alb = mix(alb, alb * 0.72, tracks);
	rough = mix(rough, rough * 0.78, tracks);

	// ---- markings --------------------------------------------------------------------------
	float mw = 0.0;      // white
	float my = 0.0;      // yellow
	if (kind == 0) {
		mw += band(aoff, half_w - 0.3, 0.15);
		mw += band(off, 0.0, 0.13) * dash(s, 3.0, 9.0, 0.0);
	} else if (kind == 1) {
		mw += band(aoff, half_w - 0.35, 0.2);
		my += band(aoff, 0.16, 0.13);
		mw += band(aoff, lane_w, 0.15) * dash(s, 4.0, 13.0, 0.0);
	} else if (kind == 2) {
		mw += band(aoff, half_w - 0.3, 0.13);
		my += band(aoff, 0.12, 0.11);
	} else if (kind == 3) {
		mw += band(aoff, half_w - 1.5, 0.9);
		mw += band(off, 0.0, 0.9) * dash(s, 30.0, 50.0, 0.0) * step(80.0, s) * step(s, total - 80.0);
		// threshold "piano keys" at both ends
		float end_d = min(s, total - s);
		float keys = step(6.0, end_d) * step(end_d, 56.0);
		float k = mod(aoff - 3.0, 3.0);
		mw += keys * step(3.0, aoff) * step(aoff, half_w - 3.0) * band(k, 0.9, 1.8);
		// aiming point markers 300 m from each end
		mw += band(end_d, 320.0, 45.0) * band(aoff, 9.0, 8.0);
	} else if (kind == 4) {
		my += band(off, 0.0, 0.15);
		mw += band(aoff, half_w - 0.4, 0.15) * 0.6;
	}
	float paint_ok = mix(1.0, smoothstep(0.18, 0.55, vnoise(vec2(off * 9.0, s * 2.2))), wear);
	mw = clamp(mw, 0.0, 1.0) * paint_ok;
	my = clamp(my, 0.0, 1.0) * paint_ok;
	float m = max(mw, my);
	vec3 paint = mw >= my ? white_paint : yellow_paint;

	ALBEDO = mix(alb, paint * (0.9 + 0.1 * n1), m);
	ROUGHNESS = mix(rough, 0.5, m);
	METALLIC = 0.0;
	SPECULAR = 0.45;
	NORMAL_MAP = mix(nrm, vec3(0.5, 0.5, 1.0), m * 0.85);
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.25;
}
