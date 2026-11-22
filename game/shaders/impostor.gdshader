// DRIVE1 — view-dependent tree impostor (atlas from pipeline/vegetation/bake_impostors.py).
// A camera-facing quad per tree; the 4 nearest baked views (azimuth x elevation) are blended, each one
// re-projected onto the billboard plane with its own frame size. Baked object-space normals give correct
// lighting, alpha coverage gives the silhouette. Works in the shadow pass too (faces the light).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D normal_atlas : filter_linear_mipmap_anisotropic, repeat_disable;
uniform int az_count = 16;
uniform vec3 elevations_deg = vec3(0.0, 25.0, 55.0);
uniform vec3 frame_scales = vec3(8.0, 8.0, 8.0);
uniform int cols = 8;
uniform int rows = 6;
uniform vec3 centre = vec3(0.0, 2.5, 0.0);
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.42;
uniform vec3 tint : source_color = vec3(1.0);
uniform float translucency : hint_range(0.0, 1.0) = 0.35;
uniform float wind_strength = 0.06;

varying vec3 q_obj;        // point on the billboard plane, object space, relative to centre
varying float v_az;
varying float v_el;

vec3 frame_dir(float az, float el) {
	return vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

void vertex() {
	vec3 cam_obj = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 d = cam_obj - centre;
	vec3 dir = normalize(d);
	float el = asin(clamp(dir.y, 0.0, 0.999));
	v_el = el;
	v_az = atan(dir.x, dir.z);
	vec3 bdir = normalize(vec3(dir.x, max(dir.y, 0.0), dir.z) + vec3(0.0, 1e-4, 0.0));
	vec3 right = cross(vec3(0.0, 1.0, 0.0), bdir);
	right = length(right) < 1e-3 ? vec3(1.0, 0.0, 0.0) : normalize(right);
	vec3 up = cross(bdir, right);
	float S = max(max(frame_scales.x, frame_scales.y), frame_scales.z);
	vec2 c = UV - 0.5;
	q_obj = (right * c.x - up * c.y) * S;
	// gentle wind sway, more at the top
	float h01 = clamp((q_obj.y + centre.y) / (2.0 * centre.y), 0.0, 1.0);
	vec3 wpos = MODEL_MATRIX[3].xyz;
	float sway = sin(TIME * 1.3 + wpos.x * 0.07 + wpos.z * 0.05) * wind_strength * h01 * h01 * S * 0.1;
	VERTEX = centre + q_obj + vec3(sway, 0.0, sway * 0.5);
	// shadow pass (directional shadows use an orthographic projection): push the caster away from the light so
	// the camera-facing quad does not shadow itself; a shift along the light direction keeps the ground shadow
	// in place (only its depth changes)
	if (PROJECTION_MATRIX[3][3] > 0.5) {
		VERTEX -= bdir * S * 0.4;
	}
	NORMAL = bdir;
	TANGENT = right;
	BINORMAL = up;
}

void sample_frame(int ai, int ei, float w, inout vec4 alb, inout vec4 nrm) {
	if (w <= 0.0) return;
	float az = TAU * float(ai) / float(az_count);
	float el = radians(elevations_deg[ei]);
	vec3 fd = frame_dir(az, el);
	vec3 r = normalize(cross(vec3(0.0, 1.0, 0.0), fd));
	vec3 u = cross(fd, r);
	float s = frame_scales[ei];
	vec2 luv = vec2(dot(q_obj, r), -dot(q_obj, u)) / s + 0.5;
	if (luv.x < 0.0 || luv.y < 0.0 || luv.x > 1.0 || luv.y > 1.0) return;
	int k = ei * az_count + ai;
	vec2 cell = vec2(float(k % cols), float(k / cols));
	vec2 auv = (cell + clamp(luv, vec2(0.002), vec2(0.998))) / vec2(float(cols), float(rows));
	alb += texture(albedo_atlas, auv) * w;
	nrm += texture(normal_atlas, auv) * w;
}

void fragment() {
	float a = v_az / TAU * float(az_count);
	a = mod(a, float(az_count));
	int a0 = int(floor(a)) % az_count;
	int a1 = (a0 + 1) % az_count;
	float fa = fract(a);
	float e1 = radians(elevations_deg.y);
	float e2 = radians(elevations_deg.z);
	int r0 = 0;
	float fe = 0.0;
	if (v_el <= e1) {
		r0 = 0;
		fe = v_el / e1;
	} else {
		r0 = 1;
		fe = clamp((v_el - e1) / (e2 - e1), 0.0, 1.0);
	}
	int r1 = r0 + 1;
	vec4 alb = vec4(0.0);
	vec4 nrm = vec4(0.0);
	sample_frame(a0, r0, (1.0 - fa) * (1.0 - fe), alb, nrm);
	sample_frame(a1, r0, fa * (1.0 - fe), alb, nrm);
	sample_frame(a0, r1, (1.0 - fa) * fe, alb, nrm);
	sample_frame(a1, r1, fa * fe, alb, nrm);
	float cov = alb.a;
	vec3 col = cov > 1e-3 ? alb.rgb / max(cov, 1e-3) * cov / max(cov, 1e-3) : vec3(0.0);
	col = alb.rgb / max(cov, 1e-3);
	vec3 n_obj = normalize(nrm.rgb / max(cov, 1e-3) * 2.0 - 1.0);
	ALBEDO = clamp(col, 0.0, 1.0) * tint;
	NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n_obj, 0.0))).xyz);
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;
	BACKLIGHT = ALBEDO * translucency;
	ALPHA = cov;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
}
