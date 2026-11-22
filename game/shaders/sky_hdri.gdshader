// DRIVE1 — photographic sky: cross-fades two equirectangular HDRIs (time-of-day keyframes).
// The sun/moon disc baked into the photos is clamped out (direct light comes from the DirectionalLight3D,
// so it must not be counted twice in ambient/reflections); a procedural disc is drawn for the visible
// background only. Below the horizon the photo is replaced by a ground tone so reflections on the car's
// lower body look like terrain, not sky.
shader_type sky;
render_mode use_debanding;

uniform sampler2D sky_a : filter_linear, repeat_enable, hint_default_black;
uniform sampler2D sky_b : filter_linear, repeat_enable, hint_default_black;
uniform float blend : hint_range(0.0, 1.0) = 0.0;
uniform float energy_a = 1.0;
uniform float energy_b = 1.0;
uniform float rotation = 0.0;           // radians about +Y, same for both photos (same location)
uniform float radiance_clamp = 40.0;    // must match pipeline/hdri_sun.py CLAMP
uniform vec3 ground_color : source_color = vec3(0.30, 0.38, 0.44);   // distant sea haze
uniform float ground_energy = 0.55;      // multiplied by the sky's own brightness near the horizon
uniform float horizon_blend = 0.035;    // width of the horizon transition (in dir.y)
uniform float sun_disc_deg = 0.55;      // apparent diameter of the drawn disc
uniform float sun_disc_energy = 30.0;
uniform bool draw_sun_disc = true;

vec3 sample_pano(sampler2D tex, vec3 d) {
	vec2 st = vec2(atan(d.x, d.z), acos(clamp(d.y, -1.0, 1.0)));
	if (st.x < 0.0) {
		st.x += TAU;
	}
	st /= vec2(TAU, PI);
	return min(textureLod(tex, st, 0.0).rgb, vec3(radiance_clamp));
}

void sky() {
	vec3 d = EYEDIR;
	float c = cos(rotation), s = sin(rotation);
	vec3 rd = vec3(c * d.x + s * d.z, d.y, -s * d.x + c * d.z);
	// sample the upper hemisphere; for directions below the horizon mirror to the horizon band
	vec3 up = vec3(rd.x, max(rd.y, 0.002), rd.z);
	vec3 a = sample_pano(sky_a, normalize(up)) * energy_a;
	vec3 b = sample_pano(sky_b, normalize(up)) * energy_b;
	vec3 skyc = mix(a, b, blend);

	// ground tone below the horizon, lit like the horizon sky
	vec3 hz_dir = normalize(vec3(rd.x, 0.002, rd.z));
	vec3 hz = mix(sample_pano(sky_a, hz_dir) * energy_a, sample_pano(sky_b, hz_dir) * energy_b, blend);
	float hz_lum = dot(hz, vec3(0.2126, 0.7152, 0.0722));
	vec3 ground = ground_color * hz_lum * ground_energy * 2.0;
	float t = smoothstep(-horizon_blend, horizon_blend * 0.3, d.y);
	vec3 col = mix(ground, skyc, t);

	if (draw_sun_disc && !AT_CUBEMAP_PASS && LIGHT0_ENABLED) {
		float cd = dot(d, LIGHT0_DIRECTION);
		float r = radians(sun_disc_deg * 0.5);
		float disc = smoothstep(cos(r * 1.15), cos(r * 0.85), cd);
		col += LIGHT0_COLOR * LIGHT0_ENERGY * sun_disc_energy * disc * t;
	}
	COLOR = col;
}
