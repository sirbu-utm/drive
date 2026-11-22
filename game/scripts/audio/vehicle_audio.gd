class_name VehicleAudio
extends Node3D
## All car sounds, driven by the Vehicle:
##   * engine: 8 rpm loops x (throttle on / off). Neighbouring loops are cross-faded (equal power) and pitch-scaled to the real
##     rpm; on/off loops are cross-faded by the throttle load. Rev limiter = fuel-cut gating, overrun pops after a lift at
##     high rpm, gear-shift clunk on every shift.
##   * transmission whine (pitch from road speed), tyre squeal (per-wheel slip, tarmac / loose ground variants),
##     surface rumble (asphalt / gravel / grass by the wheels' contact), wind (by speed), suspension bump thumps and body impacts.
##   * 3D (positional, Doppler) for external cameras; with the cockpit / hood camera the mix goes "interior":
##     low-passed engine, different levels, attenuation off.
## Sounds live on the buses created by AudioBuses (Engine / Effects / Ambience), volumes come from GameSettings.

const DIR := "res://assets/audio/"

var vehicle: Vehicle
var rig: CameraRig

var _rpms: PackedFloat32Array = PackedFloat32Array()
var _on: Array[AudioStreamPlayer3D] = []
var _off: Array[AudioStreamPlayer3D] = []
var _whine: AudioStreamPlayer3D
var _squeal_a: AudioStreamPlayer3D
var _squeal_b: AudioStreamPlayer3D
var _slide: AudioStreamPlayer3D
var _road := {}                       # "asphalt"/"gravel"/"grass" -> player
var _wind: AudioStreamPlayer3D
var _pops: Array[AudioStreamPlayer3D] = []
var _shifts: Array[AudioStreamPlayer3D] = []
var _impacts: Array[AudioStreamPlayer3D] = []
var _bump: AudioStreamPlayer3D
var _bump_pool: Array[AudioStreamPlayer3D] = []
var _starter: AudioStreamPlayer3D
var _pop_streams: Array[AudioStream] = []
var _shift_streams: Array[AudioStream] = []
var _impact_light: Array[AudioStream] = []
var _impact_heavy: Array[AudioStream] = []

var _rpm := 1000.0
var _load := 0.0
var _lim_t := 0.0
var _lift_t := 99.0                   # seconds since the throttle was lifted at high rpm
var _was_on := false
var _pop_timer := 0.0
var _interior := false
var _lp_engine := 20000.0
var _lp_fx := 20000.0
var _lp_amb := 20000.0
var _shelf := 1.0
var _prev_v := Vector3.ZERO
var _prev_pos := Vector3.ZERO
var _imp_cool := 0.0
var _bump_cool := 0.0
var _rng := RandomNumberGenerator.new()
var enabled := true

## debug read-outs (tests)
var dbg := {}


func _ready() -> void:
	AudioBuses.ensure()
	GameSettings.apply_audio()
	_rng.seed = 4242
	position = Vector3(0.0, 0.55, 0.85)               # engine bay (behind the seats)
	_build()
	if vehicle != null:
		vehicle.shifted.connect(_on_shifted)
		_prev_v = vehicle.linear_velocity


func _res(name: String) -> AudioStream:
	return load(DIR + name) as AudioStream


func _player(stream: AudioStream, bus: String, unit: float = 9.0, loop: bool = true) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = bus
	p.unit_size = unit
	p.max_distance = 500.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
	p.volume_db = -80.0
	p.max_polyphony = 1
	add_child(p)
	if loop:
		p.play()
		p.stream_paused = true
	return p


func _build() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIR + "engine_loops.json"))
	var by_rpm := {}
	for l in meta["loops"]:
		var r: int = int(l["nominal_rpm"])
		if not by_rpm.has(r):
			by_rpm[r] = {}
		by_rpm[r][l["load"]] = l
	var keys := by_rpm.keys()
	keys.sort()
	for r in keys:
		var on: Dictionary = by_rpm[r]["on"]
		var off: Dictionary = by_rpm[r]["off"]
		_rpms.append(float(on["rpm"]))
		_on.append(_player(_res(on["file"]), "Engine", 9.0))
		_off.append(_player(_res(off["file"]), "Engine", 9.0))
	_whine = _player(_res("whine.wav"), "Engine", 7.0)
	_squeal_a = _player(_res("squeal_a.wav"), "Effects", 10.0)
	_squeal_b = _player(_res("squeal_b.wav"), "Effects", 10.0)
	_slide = _player(_res("slide_loose.wav"), "Effects", 10.0)
	_road["asphalt"] = _player(_res("road_asphalt.wav"), "Effects", 10.0)
	_road["gravel"] = _player(_res("road_gravel.wav"), "Effects", 10.0)
	_road["grass"] = _player(_res("road_grass.wav"), "Effects", 10.0)
	_wind = _player(_res("wind.wav"), "Ambience", 12.0)
	for i in 5:
		_pop_streams.append(_res("pop_%d.wav" % (i + 1)))
	for i in 3:
		_shift_streams.append(_res("shift_%d.wav" % (i + 1)))
		_impact_light.append(_res("impact_light_%d.wav" % (i + 1)))
	for i in 2:
		_impact_heavy.append(_res("impact_heavy_%d.wav" % (i + 1)))
	for i in 3:
		_pops.append(_player(_pop_streams[0], "Effects", 8.0, false))
	for i in 2:
		_shifts.append(_player(_shift_streams[0], "Effects", 6.0, false))
	for i in 3:
		_impacts.append(_player(_impact_light[0], "Effects", 12.0, false))
	_bump = _player(_res("bump.wav"), "Effects", 8.0, false)
	_bump_pool.append(_bump)
	_starter = _player(_res("starter.wav"), "Engine", 6.0, false)


func _exit_tree() -> void:
	for c in get_children():
		if c is AudioStreamPlayer3D:
			(c as AudioStreamPlayer3D).stop()
			(c as AudioStreamPlayer3D).stream = null


func start_engine() -> void:
	if _starter != null:
		_starter.volume_db = -6.0
		_starter.play()


func _voice(p: AudioStreamPlayer3D, vol_lin: float, pitch: float = 1.0) -> void:
	if vol_lin < 0.0008:
		if not p.stream_paused:
			p.stream_paused = true
		p.volume_db = -80.0
		return
	p.stream_paused = false
	p.volume_db = linear_to_db(vol_lin)
	p.pitch_scale = clampf(pitch, 0.1, 8.0)


func _play_one(pool: Array[AudioStreamPlayer3D], stream: AudioStream, vol_lin: float, pitch: float = 1.0) -> void:
	for p in pool:
		if not p.playing:
			p.stream = stream
			p.volume_db = linear_to_db(maxf(vol_lin, 0.001))
			p.pitch_scale = pitch
			p.play()
			return
	# all busy: steal the first one
	var q := pool[0]
	q.stream = stream
	q.volume_db = linear_to_db(maxf(vol_lin, 0.001))
	q.pitch_scale = pitch
	q.play()


func _on_shifted(_g: int) -> void:
	if not enabled or _shifts.is_empty():
		return
	dbg["shifts"] = int(dbg.get("shifts", 0)) + 1
	_play_one(_shifts, _shift_streams[_rng.randi() % _shift_streams.size()], 0.55 if _interior else 0.4, _rng.randf_range(0.95, 1.05))


func _physics_process(dt: float) -> void:
	if vehicle == null or not enabled:
		return
	var v := vehicle.linear_velocity
	_imp_cool = maxf(_imp_cool - dt, 0.0)
	_bump_cool = maxf(_bump_cool - dt, 0.0)
	# impacts: sudden change of the velocity vector within one physics step (a wall / hard landing: > ~8 g)
	var dv := ((v - _prev_v) - Vector3(0, -9.81 * dt, 0)).length()
	var pos := vehicle.global_position
	var was_fast := _prev_v.length() > 3.0 and pos.distance_to(_prev_pos) < 1.5      # a teleport (reset / respawn) is not an impact
	_prev_v = v
	_prev_pos = pos
	if dv > 0.35 and _imp_cool <= 0.0 and was_fast:
		var strength := clampf((dv - 0.35) / 1.4, 0.0, 1.0)
		var s: AudioStream
		if strength > 0.45:
			s = _impact_heavy[_rng.randi() % _impact_heavy.size()]
		else:
			s = _impact_light[_rng.randi() % _impact_light.size()]
		_play_one(_impacts, s, lerpf(0.35, 1.0, strength), _rng.randf_range(0.9, 1.1))
		_imp_cool = 0.3
		dbg["impact"] = dv
		dbg["impacts"] = int(dbg.get("impacts", 0)) + 1
	if _bump_cool <= 0.0:
		for w in vehicle.wheels:
			if w.in_contact and w.comp > vehicle.params.travel_bump - 0.006 and w.comp_vel > 0.5:
				_play_one(_bump_pool, _bump.stream, clampf(w.comp_vel / 3.0, 0.2, 0.9), _rng.randf_range(0.9, 1.1))
				_bump_cool = 0.2
				dbg["bump"] = w.comp_vel
				dbg["bumps"] = int(dbg.get("bumps", 0)) + 1
				break


func _process(dt: float) -> void:
	if vehicle == null or not enabled or _rpms.is_empty():
		return
	var d := vehicle.drivetrain
	var spd := vehicle.speed
	var sp01 := clampf(spd / 80.0, 0.0, 1.0)
	_interior = rig != null and rig.is_interior()

	# ---- camera dependent mix ------------------------------------------------------------------------
	var t_lp_e := 2600.0 if _interior else 20000.0
	var t_lp_f := 5200.0 if _interior else 20000.0
	var t_lp_a := (2400.0 + 3500.0 * sp01) if _interior else (5000.0 + 9000.0 * sp01)
	var k := 1.0 - exp(-dt * 8.0)
	_lp_engine = lerpf(_lp_engine, t_lp_e, k)
	_lp_fx = lerpf(_lp_fx, t_lp_f, k)
	_lp_amb = lerpf(_lp_amb, t_lp_a, k)
	_shelf = lerpf(_shelf, 1.9 if _interior else 1.0, k)
	AudioBuses.set_lowpass("Engine", _lp_engine)
	AudioBuses.set_lowpass("Effects", _lp_fx)
	AudioBuses.set_lowpass("Ambience", _lp_amb)
	AudioBuses.set_engine_shelf(_shelf)
	var att := AudioStreamPlayer3D.ATTENUATION_DISABLED if _interior else AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	if _on[0].attenuation_model != att:
		for p in get_children():
			(p as AudioStreamPlayer3D).attenuation_model = att
	var level_engine := 0.78 if _interior else 0.62
	var level_fx := 1.0 if _interior else 0.85

	# ---- engine ---------------------------------------------------------------------------------------
	var rpm_target := d.rpm
	_rpm = lerpf(_rpm, rpm_target, 1.0 - exp(-dt * 40.0))
	var load_target := clampf(d.throttle, 0.0, 1.0)
	if d.engine_torque < -5.0 and d.throttle < 0.12:
		load_target = 0.0
	var rate := 9.0 if load_target > _load else 5.0
	_load = move_toward(_load, load_target, rate * dt)
	var on_w := sin(_load * PI * 0.5)
	var off_w := cos(_load * PI * 0.5) * 0.92 + 0.08
	if d.limiter and _load > 0.5:
		_lim_t += dt
		if fmod(_lim_t * 16.0, 1.0) < 0.5:
			on_w *= 0.10
			off_w = maxf(off_w, 0.5)
	else:
		_lim_t = 0.0
	# rpm interval
	var n := _rpms.size()
	var r := clampf(_rpm, _rpms[0], _rpms[n - 1])
	var i := 0
	while i < n - 2 and r > _rpms[i + 1]:
		i += 1
	var t := clampf((r - _rpms[i]) / (_rpms[i + 1] - _rpms[i]), 0.0, 1.0)
	var wi := cos(t * PI * 0.5)
	var wj := sin(t * PI * 0.5)
	for idx in n:
		var w := 0.0
		if idx == i:
			w = wi
		elif idx == i + 1:
			w = wj
		var pitch := clampf(_rpm / _rpms[idx], 0.45, 2.2)
		_voice(_on[idx], w * on_w * level_engine, pitch)
		_voice(_off[idx], w * off_w * level_engine * 0.9, pitch)
	dbg["rpm"] = _rpm
	dbg["rpm_i"] = i
	dbg["rpm_t"] = t
	dbg["load"] = _load

	# ---- overrun pops --------------------------------------------------------------------------------
	var loaded := d.throttle > 0.6 and _rpm > 4000.0
	if loaded:
		_was_on = true
	elif _was_on and d.throttle < 0.12:
		_was_on = false
		_lift_t = 0.0
	_lift_t += dt
	if _lift_t < 1.6 and d.throttle < 0.12 and _rpm > 4200.0:
		_pop_timer -= dt
		if _pop_timer <= 0.0:
			var q := clampf((_rpm - 4000.0) / 5000.0, 0.0, 1.0)
			_play_one(_pops, _pop_streams[_rng.randi() % _pop_streams.size()], lerpf(0.2, 0.7, q) * level_fx, _rng.randf_range(0.85, 1.15))
			_pop_timer = _rng.randf_range(0.05, 0.28) / (0.4 + q)
			dbg["pop"] = _lift_t
			dbg["pops"] = int(dbg.get("pops", 0)) + 1

	# ---- transmission whine ----------------------------------------------------------------------------
	var whine_pitch := clampf((spd * 12.0 + 60.0) / 600.0, 0.15, 4.0)
	var drive := clampf(0.35 + 0.65 * d.throttle, 0.0, 1.0)
	_voice(_whine, clampf(sp01 * 0.55, 0.0, 0.5) * drive * (0.9 if _interior else 0.3) * (1.0 if d.gear != 0 else 0.0), whine_pitch)

	# ---- tyres ---------------------------------------------------------------------------------------
	var slip := 0.0
	var loose := 0.0
	var counts := {"asphalt": 0, "gravel": 0, "grass": 0}
	var grounded := 0
	for w in vehicle.wheels:
		if not w.is_grounded:
			continue
		grounded += 1
		var kk: float = absf(w.slip_ratio) / maxf(vehicle.tire.kappa_peak, 0.01)
		var aa: float = absf(tan(w.slip_angle)) / maxf(tan(vehicle.tire.alpha_peak), 0.01)
		slip = maxf(slip, sqrt(kk * kk + aa * aa) * clampf(w.load / 1500.0, 0.0, 1.0))
		var key: String = w.surface_key
		var cls := "asphalt"
		if key in ["gravel", "dirt", "sand", "rock"]:
			cls = "gravel"
		elif key == "grass":
			cls = "grass"
		counts[cls] += 1
		if cls != "asphalt":
			loose += 1.0
	var q_sq := clampf((slip - 0.9) / 0.7, 0.0, 1.0) * clampf((spd - 1.5) / 4.0, 0.0, 1.0)
	var loose_frac := loose / maxf(float(grounded), 1.0)
	var tarmac_q := q_sq * (1.0 - loose_frac)
	var pitch_sq := 0.85 + 0.30 * q_sq + spd * 0.0012
	_voice(_squeal_a, pow(tarmac_q, 0.8) * 0.55 * level_fx * (1.0 - 0.4 * q_sq * q_sq), pitch_sq)
	_voice(_squeal_b, pow(clampf(tarmac_q * 1.3 - 0.35, 0.0, 1.0), 1.0) * 0.45 * level_fx, pitch_sq * 0.97)
	_voice(_slide, pow(q_sq * loose_frac, 0.8) * 0.8 * level_fx, 0.8 + 0.3 * q_sq)
	dbg["slip"] = slip
	dbg["squeal"] = q_sq

	# ---- surface rumble --------------------------------------------------------------------------------
	var sp_l := clampf(spd / 55.0, 0.0, 1.0)
	for key in _road:
		var share := float(counts[key]) / maxf(float(grounded), 1.0)
		var base := 0.55 if key == "asphalt" else (0.95 if key == "gravel" else 0.6)
		_voice(_road[key], share * pow(sp_l, 0.85) * base * level_fx * (0.7 if _interior else 1.0), 0.65 + 0.9 * sp_l)

	# ---- wind -----------------------------------------------------------------------------------------
	_voice(_wind, pow(clampf(spd / 90.0, 0.0, 1.0), 1.7) * (0.8 if _interior else 1.0), 0.8 + 0.5 * sp01)
