class_name TimeTrial
extends Node3D
## Time trial on a road of roads.json: start/finish arch, sector arches (emissive), lap timer with splits, best lap
## (user://records.cfg) and the ghost of the best lap.
##   Closed road (ring): flying laps, the start/finish gate is crossed again to complete a lap.
##   Open road (mountain pass): one run from the start gate to the finish gate.
## The timer starts when the car crosses the start gate (3-2-1 countdown, car held on the brakes, rolling start 40 m before it).
## R (reset) puts the car back at the last gate and marks the lap as invalid (it does not count for the record).

signal countdown_tick(n: int)               # 3,2,1,0 (0 = go)
signal sector_done(index: int, time: float, delta: float)    # delta vs the best lap (NAN without a best)
signal lap_done(time: float, new_best: bool, valid: bool)
signal started

enum State { COUNTDOWN, WAITING, RUNNING, FINISHED }

const SAMPLE_DT := 1.0 / GhostCar.RATE

var game: Game
var net: RoadNet
var route := "ring"
var road: Dictionary
var closed := false
var sectors := 3
var gates: Array[Dictionary] = []
var state: State = State.COUNTDOWN
var lap := 1
var lap_time := 0.0
var next_gate := 0
var splits := PackedFloat32Array()
var last_time := 0.0
var invalid := false
var best := {"time": 0.0, "splits": PackedFloat32Array()}
var start_idx := 40
var end_idx := 0
var countdown := 3.0
var last_delta := NAN
var message := ""
var message_t := 0.0
var respawns := 0

var ghost: GhostCar
var ghost_data := PackedFloat32Array()
var _rec := PackedFloat32Array()
var _rec_next := 0.0
var _prev_pos := Vector3.ZERO
var _have_prev := false
var _last_gate_pose := Transform3D.IDENTITY
var _mats := {}


func setup(g: Game, route_name: String, sector_count: int = 3) -> void:
	game = g
	net = g.net
	route = route_name
	sectors = sector_count
	road = net.get_road(route)
	closed = bool(road["closed"])
	var n: int = road["pts"].size()
	var m := n - 1 if closed else n
	start_idx = 40
	end_idx = start_idx + m if closed else n - 1 - 30
	_build_gates()
	best = TrialRecords.best(route)
	ghost_data = TrialRecords.load_ghost(route)
	ghost = GhostCar.new()
	ghost.name = "Ghost"
	ghost.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(ghost)
	var rest: Array[Vector3] = []
	for w in game.car.wheels:
		rest.append(w.rest_pos)
	ghost.build(load(Game.CAR_VISUAL) as PackedScene, rest)
	ghost.set_data(ghost_data)
	restart()


func _gate_index(k: int) -> int:
	if closed:
		return int(start_idx + float(k) * float(end_idx - start_idx) / float(sectors))
	return int(start_idx + float(k) * float(end_idx - start_idx) / float(sectors))


func _build_gates() -> void:
	gates.clear()
	var count := sectors if closed else sectors + 1        # open road: the last gate is the finish
	for k in count:
		var idx := _gate_index(k)
		var j := net.idx(road, idx)
		var p: Vector3 = road["pts"][j]
		var t := net.tangent(road, j)
		var fwd := Vector3(t.x, 0.0, t.z).normalized()
		var right := fwd.cross(Vector3.UP).normalized()
		var half := float(road["width"][j]) * 0.5
		var kind := "start" if k == 0 else ("finish" if (not closed and k == count - 1) else "sector")
		gates.append({"pos": p, "fwd": fwd, "right": right, "half": half, "idx": idx, "kind": kind, "tan": t})
		_make_arch(gates[k], k)


func _emissive(col: Color, energy: float = 3.0) -> StandardMaterial3D:
	var key := "%s_%f" % [col.to_html(), energy]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	m.roughness = 0.6
	_mats[key] = m
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _make_arch(g: Dictionary, k: int) -> void:
	var root := Node3D.new()
	root.name = "Gate%d_%s" % [k, g["kind"]]
	add_child(root)
	root.global_transform = Transform3D(Basis.looking_at(g["fwd"], Vector3.UP), g["pos"])
	var half: float = g["half"] + 1.3
	var col := Color(1.0, 0.5, 0.08)
	if g["kind"] == "start":
		col = Color(0.3, 1.0, 0.4)
	elif g["kind"] == "finish":
		col = Color(1.0, 1.0, 1.0)
	var mat := _emissive(col)
	# pillars sink into the ground a little, so the arch stands on any slope
	for s in [-1.0, 1.0]:
		_box(root, Vector3(0.7, 9.0, 0.7), Vector3(s * half, 2.0, 0.0), mat)
	var beam_y := 6.2
	if g["kind"] == "sector":
		_box(root, Vector3(half * 2.0 + 1.4, 0.7, 0.7), Vector3(0, beam_y, 0), mat)
	else:
		var seg := 14
		var w := (half * 2.0 + 1.4) / float(seg)
		var dark := _emissive(Color(0.05, 0.05, 0.05), 0.0)
		var light := _emissive(Color(1, 1, 1), 2.4)
		for i in seg:
			_box(root, Vector3(w, 0.5, 0.7), Vector3(-half - 0.7 + w * (float(i) + 0.5), beam_y + 0.0, 0.0), light if i % 2 == 0 else dark)
			_box(root, Vector3(w, 0.5, 0.7), Vector3(-half - 0.7 + w * (float(i) + 0.5), beam_y + 0.5, 0.0), dark if i % 2 == 0 else light)
	# timing line on the road
	var line_mat := _emissive(col, 1.8)
	var line := _box(root, Vector3(g["half"] * 2.0, 0.04, 0.5), Vector3(0, 0.06, 0.0), line_mat)
	# follow the road slope
	var slope := asin(clampf(g["tan"].y, -0.5, 0.5))
	line.rotation.x = slope
	# a light so the arch glows on the road at dusk
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = 1.2
	l.omni_range = 18.0
	l.position = Vector3(0, 4.0, 0)
	l.shadow_enabled = false
	root.add_child(l)


# ---- control ---------------------------------------------------------------------------------------------

func restart() -> void:
	state = State.COUNTDOWN
	countdown = 3.0
	lap = 1
	lap_time = 0.0
	next_gate = 0
	splits = PackedFloat32Array()
	invalid = false
	last_delta = NAN
	respawns = 0
	_rec = PackedFloat32Array()
	_rec_next = 0.0
	_have_prev = false
	message = ""
	var idx := start_idx - 18
	var pose := net.lane_pose(road, idx, 1, 0.5)
	if closed:
		pose = net.lane_pose(road, idx, 1, 0.5)
	_last_gate_pose = pose
	game.place_car(pose)
	if game.controller:
		game.controller.enabled = false
	ghost.visible = false
	game.hud_toast("Заезд: " + route_title())
	countdown_tick.emit(3)


func route_title() -> String:
	return "Кольцо" if route == "ring" else ("Горный перевал" if route == "mountain_pass" else route)


func respawn_pose() -> Transform3D:
	respawns += 1
	invalid = true
	message = "Круг не засчитан"
	message_t = 3.0
	_have_prev = false
	return _last_gate_pose


func sector_count_total() -> int:
	return sectors


## split times of the best lap for this route (empty when none)
func best_splits() -> PackedFloat32Array:
	return best["splits"]


func _physics_process(dt: float) -> void:
	if game == null or game.car == null:
		return
	var car := game.car
	if message_t > 0.0:
		message_t -= dt
	if state == State.COUNTDOWN:
		var prev := ceili(countdown)
		countdown -= dt
		car.drive(0.0, 1.0, 0.0, 1.0)
		var cur := ceili(countdown)
		if cur != prev and cur >= 0:
			countdown_tick.emit(cur)
		if countdown <= 0.0:
			state = State.WAITING
			if game.controller:
				game.controller.enabled = true
			started.emit()
			message = "СТАРТ!"
			message_t = 1.2
			_have_prev = false
		return
	if state == State.FINISHED:
		return
	var pos := car.global_position
	if not _have_prev:
		_prev_pos = pos
		_have_prev = true
	if state == State.RUNNING:
		lap_time += dt
	var gi := next_gate if state == State.RUNNING else 0
	var g: Dictionary = gates[gi]
	var rel0: Vector3 = _prev_pos - g["pos"]
	var rel1: Vector3 = pos - g["pos"]
	var d0: float = rel0.dot(g["fwd"])
	var d1: float = rel1.dot(g["fwd"])
	if d0 < 0.0 and d1 >= 0.0:
		var lat: float = rel1.dot(g["right"])
		if absf(lat) < float(g["half"]) + 3.0 and absf(rel1.y) < 12.0:
			var f := -d0 / maxf(d1 - d0, 1e-6)
			_crossed(gi, (1.0 - f) * dt)
	_prev_pos = pos
	if state == State.RUNNING:
		# record the lap at 60 Hz
		while lap_time >= _rec_next:
			GhostCar.record(_rec, car)
			_rec_next += SAMPLE_DT


func _crossed(gi: int, since: float) -> void:
	var g: Dictionary = gates[gi]
	_last_gate_pose = Transform3D(Basis.looking_at(g["fwd"], Vector3.UP), g["pos"] + g["right"] * float(g["half"]) * 0.5 + Vector3(0, 0.6, 0))
	if state == State.WAITING:
		# first crossing of the start gate
		state = State.RUNNING
		lap_time = since
		next_gate = 1 % gates.size() if gates.size() > 1 else 0
		splits = PackedFloat32Array()
		_rec = PackedFloat32Array()
		_rec_next = 0.0
		GhostCar.record(_rec, game.car)
		_rec_next = SAMPLE_DT
		message = "Круг %d" % lap if closed else "Старт"
		message_t = 1.2
		return
	var t := lap_time - since
	var is_finish := (closed and gi == 0) or (not closed and gi == gates.size() - 1)
	if is_finish:
		_finish_lap(t, since)
	else:
		splits.append(t)
		var idx := splits.size() - 1
		var bs: PackedFloat32Array = best["splits"]
		var d := NAN
		if idx < bs.size() and float(best["time"]) > 0.0:
			d = t - bs[idx]
		last_delta = d
		sector_done.emit(idx, t, d)
		next_gate = gi + 1 if gi + 1 < gates.size() else 0


func _finish_lap(t: float, since: float) -> void:
	last_time = t
	var valid := not invalid
	var bt: float = best["time"]
	var new_best := valid and (bt <= 0.0 or t < bt)
	var d := NAN
	if bt > 0.0:
		d = t - bt
	last_delta = d
	if new_best:
		var sp := splits.duplicate()
		best = {"time": t, "splits": sp}
		TrialRecords.save_best(route, t, sp)
		GhostCar.record(_rec, game.car)
		ghost_data = _rec.duplicate()
		TrialRecords.save_ghost(route, ghost_data)
		ghost.set_data(ghost_data)
		message = "НОВЫЙ РЕКОРД  " + TrialRecords.fmt_time(t)
	elif valid:
		message = "Круг: " + TrialRecords.fmt_time(t)
	else:
		message = "Круг не засчитан  " + TrialRecords.fmt_time(t)
	message_t = 4.0
	lap_done.emit(t, new_best, valid)
	if closed:
		lap += 1
		lap_time = since
		next_gate = 1 % gates.size()
		splits = PackedFloat32Array()
		invalid = false
		_rec = PackedFloat32Array()
		_rec_next = 0.0
		GhostCar.record(_rec, game.car)
		_rec_next = SAMPLE_DT
	else:
		state = State.FINISHED
		next_gate = 0


func _process(_dt: float) -> void:
	if ghost == null or game == null:
		return
	if state == State.RUNNING and ghost.data.size() > 0:
		ghost.show_at(lap_time + Engine.get_physics_interpolation_fraction() / float(Engine.physics_ticks_per_second))
	elif state == State.FINISHED:
		ghost.visible = false
	else:
		ghost.visible = false


## elapsed time of the current lap (for the HUD)
func current_time() -> float:
	return lap_time if state == State.RUNNING else (last_time if state == State.FINISHED else 0.0)


## the sector the player is in (0-based), for highlighting
func current_sector() -> int:
	return splits.size()
