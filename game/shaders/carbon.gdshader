// DRIVE1 — 2x2 twill carbon fibre under clear coat. UVs are metric (1 UV unit = 1 m, box projected in the
// car pipeline), so the weave has a constant physical size. Anisotropic highlight follows the tow direction.
// The weave fades to its average when a tow becomes smaller than ~1 px (no moire).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float tows_per_m = 170.0;
uniform vec3 fiber_color : source_color = vec3(0.022, 0.023, 0.026);
uniform vec3 fiber_sheen : source_color = vec3(0.06, 0.062, 0.07);
uniform float fiber_roughness : hint_range(0.0, 1.0) = 0.32;
uniform float anisotropy_amount : hint_range(0.0, 1.0) = 0.75;
uniform float bump : hint_range(0.0, 1.0) = 0.22;
uniform float clearcoat : hint_range(0.0, 1.0) = 1.0;
uniform float clearcoat_roughness : hint_range(0.0, 1.0) = 0.05;
uniform bool matte = false;   // matte (dry) carbon for underbody parts

void fragment() {
	vec2 w = UV * tows_per_m;
	vec2 cell = floor(w);
	vec2 f = fract(w);
	float footprint = length(fwidth(w));
	float fade = 1.0 - smoothstep(0.5, 1.6, footprint);

	bool horiz = mod(cell.x + cell.y, 4.0) < 2.0;
	float across = horiz ? f.y : f.x;
	float along = horiz ? f.x : f.y;
	float bundle = sin(across * PI);
	// tow crown + slight dip where it passes under the crossing tow
	float crown = bundle * (0.85 + 0.15 * sin(along * PI));
	vec2 slope = horiz ? vec2(0.0, cos(across * PI)) : vec2(cos(across * PI), 0.0);

	vec3 col = mix(fiber_color, fiber_sheen, crown * 0.35);
	col = mix(mix(fiber_color, fiber_sheen, 0.3), col, fade);

	ALBEDO = col;
	METALLIC = 0.0;
	ROUGHNESS = matte ? 0.6 : fiber_roughness;
	NORMAL_MAP = normalize(vec3(slope * bump * fade, 1.0)) * 0.5 + 0.5;
	ANISOTROPY = anisotropy_amount * fade * (matte ? 0.3 : 1.0);
	ANISOTROPY_FLOW = horiz ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	CLEARCOAT = matte ? 0.0 : clearcoat;
	CLEARCOAT_ROUGHNESS = clearcoat_roughness;
}
