// DRIVE1 — car lamp lens / bulb. Per-instance `lamp` (0..1+) drives emission:
//   tail lights: 0.15 = running light, 1.0 = brake; head bulbs: 0 = off, 1 = on.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 lens_color : source_color = vec3(0.45, 0.01, 0.01);
uniform vec3 emit_color : source_color = vec3(1.0, 0.05, 0.03);
uniform float emit_energy = 14.0;
uniform float base_lamp = 0.0;            // used when the instance parameter is not set
uniform float roughness : hint_range(0.0, 1.0) = 0.08;
instance uniform float lamp = -1.0;

void fragment() {
	float l = lamp < 0.0 ? base_lamp : lamp;
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	// lens looks brighter when seen face-on (light comes out through the lens)
	float facing = mix(0.45, 1.0, ndv);
	ALBEDO = lens_color;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	CLEARCOAT = 1.0;
	CLEARCOAT_ROUGHNESS = 0.02;
	EMISSION = emit_color * emit_energy * l * facing;
}
