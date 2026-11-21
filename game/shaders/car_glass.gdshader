// DRIVE1 — tinted automotive glass: Fresnel-driven opacity, mirror-sharp reflections.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 tint : source_color = vec3(0.015, 0.02, 0.024);
uniform float alpha_facing : hint_range(0.0, 1.0) = 0.38;
uniform float alpha_grazing : hint_range(0.0, 1.0) = 0.96;
uniform float roughness : hint_range(0.0, 1.0) = 0.015;
uniform float specular_level : hint_range(0.0, 1.0) = 0.7;

void fragment() {
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 4.0);
	ALBEDO = tint;
	ALPHA = mix(alpha_facing, alpha_grazing, fres);
	METALLIC = 0.0;
	ROUGHNESS = roughness;
	SPECULAR = specular_level;
}
