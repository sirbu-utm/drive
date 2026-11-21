// DRIVE1 — metallic car paint: base coat with procedural metal flakes + clear coat + colour flop.
// The car mesh has no meaningful UVs for paint, so flakes are generated in OBJECT space.
// Anti-aliasing: when a flake cell gets smaller than a pixel, the per-flake normal fades out and the
// base roughness is widened instead (the statistical look of flakes at distance).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.62, 0.035, 0.03);
uniform vec3 flop_color : source_color = vec3(0.16, 0.004, 0.006);   // colour at grazing angles
uniform vec3 flake_tint : source_color = vec3(1.0, 0.55, 0.45);
uniform float metallic : hint_range(0.0, 1.0) = 0.45;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.32;
uniform float flake_cells_per_m = 1400.0;
uniform float flake_density : hint_range(0.0, 1.0) = 0.35;
uniform float flake_normal_strength : hint_range(0.0, 1.0) = 0.12;
uniform float flake_brightness : hint_range(0.0, 1.0) = 0.45;
uniform float flop_power : hint_range(0.1, 4.0) = 1.4;
uniform float clearcoat : hint_range(0.0, 1.0) = 1.0;
uniform float clearcoat_roughness : hint_range(0.0, 1.0) = 0.035;
// optional dirt/dust layer (0 = showroom clean)
uniform float dirt : hint_range(0.0, 1.0) = 0.0;
uniform vec3 dirt_color : source_color = vec3(0.32, 0.27, 0.21);

varying vec3 obj_pos;
varying vec3 obj_nrm;

vec3 hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash33(i).x, n100 = hash33(i + vec3(1, 0, 0)).x;
	float n010 = hash33(i + vec3(0, 1, 0)).x, n110 = hash33(i + vec3(1, 1, 0)).x;
	float n001 = hash33(i + vec3(0, 0, 1)).x, n101 = hash33(i + vec3(1, 0, 1)).x;
	float n011 = hash33(i + vec3(0, 1, 1)).x, n111 = hash33(i + vec3(1, 1, 1)).x;
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

void vertex() {
	obj_pos = VERTEX;
	obj_nrm = NORMAL;
}

void fragment() {
	// ---- flakes -------------------------------------------------------------------------------
	vec3 p = obj_pos * flake_cells_per_m;
	vec3 rnd = hash33(floor(p));
	float footprint = length(fwidth(p));                 // flake cells per pixel
	float fade = 1.0 - smoothstep(0.35, 1.2, footprint);  // 1 = flakes resolved, 0 = sub-pixel
	float is_flake = step(1.0 - flake_density, rnd.z);
	vec3 fdir_obj = normalize(rnd * 2.0 - 1.0);
	vec3 fdir_view = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(fdir_obj, 0.0))).xyz);
	vec3 geo_n = NORMAL;
	NORMAL = normalize(geo_n + fdir_view * (flake_normal_strength * fade * is_flake));

	// ---- colour flop (face-on bright, grazing dark/deep) --------------------------------------
	float ndv = clamp(dot(geo_n, VIEW), 0.0, 1.0);
	vec3 col = mix(flop_color, base_color, pow(ndv, 1.0 / flop_power));
	col = mix(col, col * flake_tint * 1.6, flake_brightness * is_flake * fade);

	// ---- dirt: more on lower body and on upward-ish surfaces near the bottom --------------------
	float low = 1.0 - smoothstep(0.05, 0.45, obj_pos.y);
	float dmask = clamp(dirt * (0.35 + 0.65 * low) * (0.6 + 0.8 * vnoise(obj_pos * 9.0)), 0.0, 1.0);
	col = mix(col, dirt_color, dmask * 0.85);

	ALBEDO = col;
	METALLIC = metallic * (1.0 - dmask);
	// sub-pixel flakes widen the base lobe a little
	ROUGHNESS = mix(base_roughness + 0.08, base_roughness, fade) + dmask * 0.5;
	CLEARCOAT = clearcoat * (1.0 - dmask * 0.9);
	CLEARCOAT_ROUGHNESS = clearcoat_roughness + dmask * 0.4;
}
