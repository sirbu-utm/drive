// DRIVE1 — tyre rubber: matte sidewall, slightly glossier worn tread, subtle dust towards the bottom.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 rubber : source_color = vec3(0.028, 0.028, 0.03);
uniform vec3 dust : source_color = vec3(0.16, 0.145, 0.13);
uniform float dust_amount : hint_range(0.0, 1.0) = 0.25;

varying vec3 obj_pos;
varying vec3 obj_nrm;

void vertex() {
	obj_pos = VERTEX;
	obj_nrm = NORMAL;
}

void fragment() {
	float r = length(obj_pos.yz);
	float tread = 1.0 - abs(normalize(obj_nrm).x);         // 1 on the tread, 0 on the sidewall
	// sidewall: dust collects near the rim edge and the shoulder
	float sw_dust = smoothstep(0.24, 0.30, r) * (1.0 - tread);
	vec3 col = mix(rubber, dust, sw_dust * dust_amount * 0.5);
	col = mix(col, rubber * 0.85, tread);
	ALBEDO = col;
	METALLIC = 0.0;
	ROUGHNESS = mix(0.88, 0.62, tread);
	SPECULAR = 0.35;
}
