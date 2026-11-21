// DRIVE1 — cast-iron brake disc with radial machining marks and heat glow.
// Per-instance `heat` 0..1 (set by the vehicle from brake energy): >0.35 starts glowing dull red, 1 = orange.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 iron_color : source_color = vec3(0.42, 0.41, 0.40);
uniform float roughness : hint_range(0.0, 1.0) = 0.38;
instance uniform float heat = 0.0;

varying vec3 obj_pos;

void vertex() { obj_pos = VERTEX; }

vec3 blackbody(float t) {
	// t 0..1 mapped to ~700K..1300K, artistic approximation
	vec3 c = vec3(1.0, 0.18, 0.02);
	c = mix(c, vec3(1.0, 0.42, 0.08), smoothstep(0.4, 0.8, t));
	c = mix(c, vec3(1.0, 0.75, 0.35), smoothstep(0.8, 1.0, t));
	return c;
}

void fragment() {
	// concentric machining rings across the disc face (wheel spins about local X)
	float r = length(obj_pos.yz);
	float rings = 0.5 + 0.5 * sin(r * 2600.0);
	float fw = fwidth(r * 2600.0);
	rings = mix(rings, 0.5, smoothstep(0.5, 2.0, fw));
	ALBEDO = iron_color * (0.9 + 0.1 * rings);
	METALLIC = 1.0;
	ROUGHNESS = roughness + 0.06 * rings;
	ANISOTROPY = 0.5;
	float g = smoothstep(0.35, 1.0, heat);
	EMISSION = blackbody(heat) * g * g * 9.0;
}
