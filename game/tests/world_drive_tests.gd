extends "res://tests/vehicle_test_base.gd"
## Phase 2.5: the car on the real world (res://scenes/world/world.scn): autopilot laps with incident recovery.
## Incidents (stuck / off the road for long / flipped) are recorded with coordinates and road sample index so that
## world-side defects (road seams, overlapping roads, bad collision) can be reported precisely.

var net: RoadNet
var w3d: Node
var _cam: Camera3D

func _load_world() -> void:
	net = RoadNet.new()
	# Terrain3D wants an active camera / clipmap target at all times: the camera goes in first
	_cam = Camera3D.new()
	tree.root.add_child(_cam)
	_cam.current = true
	w3d = (load("res://scenes/world/world.scn") as PackedScene).instantiate()
	var t3 := w3d.get_node("Terrain3D")
	t3.clipmap_target = _cam            # set before entering the tree: no "no clipmap target" error
	tree.root.add_child(w3d)
	world = w3d

func _spawn_on(road_name: String, idx: int, dir: int, speed: float) -> Autopilot:
	var pose := net.lane_pose(net.get_road(road_name), idx, dir, 0.6)
	if car == null:
		car = Vehicle.new()
		car.build_visual = false
		car.contact_monitor = true
		car.max_contacts_reported = 8
		tree.root.add_child(car)
		w3d.set_focus(car)
	car.reset_to(pose, -pose.basis.z * speed)
	return null

## Drive a route with the autopilot. Returns statistics.
func _drive_route(road_name: String, dir: int, start: int, end: int, speed_cap: float, lat_g: float, max_time: float, closed_lap: bool = false) -> Dictionary:
	var road := net.get_road(road_name)
	_spawn_on(road_name, start, dir, 0.0)
	var ap := Autopilot.new(net, road_name, dir, start, speed_cap, lat_g)
	if not closed_lap:
		ap.stop_at_end = true
	var stats := {"incidents": [], "spikes": [], "surfaces": {}, "max_speed": 0.0, "dist": 0.0, "time": 0.0, "max_cte": 0.0,
		"stuck_events": 0, "fell": 0, "seam_spike_count": 0, "max_vertical_g": 0.0, "wheel_air_ticks": 0}
	# let the terrain collision and suspension settle
	for i in 120:
		car.drive(0, 0, 0)
		await tree.physics_frame
	var n := 0
	var prev_vy := car.linear_velocity.y
	var prev_pos := car.global_position
	var off_t := 0.0
	var stuck_t := 0.0
	var sum_v := 0.0
	var lap_limit: int = (road["pts"].size() - 1) if road["closed"] else (road["pts"].size())
	var last_spike_t := -1.0
	var recent_hit := ""
	while n < int(max_time * 240.0) and not ap.finished:
		var c := ap.update(car)
		car.drive(c.x, c.y, c.z)
		await tree.physics_frame
		n += 1
		var dt := 1.0 / 240.0
		stats["dist"] += car.global_position.distance_to(prev_pos)
		prev_pos = car.global_position
		sum_v += car.speed
		stats["max_speed"] = maxf(stats["max_speed"], car.speed)
		stats["max_cte"] = maxf(stats["max_cte"], absf(ap.cte))
		for wh in car.wheels:
			stats["surfaces"][wh.surface_key] = stats["surfaces"].get(wh.surface_key, 0) + 1
		var az := absf(car.linear_velocity.y - prev_vy) / dt / 9.81
		prev_vy = car.linear_velocity.y
		if not car.airborne and car.speed > 3.0 and az < 40.0:
			stats["max_vertical_g"] = maxf(stats["max_vertical_g"], az)
		if az > 2.5 and not car.airborne and car.speed > 3.0:
			var t_now := n * dt
			if t_now - last_spike_t > 0.05:
				var cb := ""
				for b in car.get_colliding_bodies():
					cb += "%s/%s " % [b.get_parent().name, b.name]
				stats["spikes"].append({"g": snappedf(az, 0.1), "pos": car.global_position.snapped(Vector3(0.1, 0.1, 0.1)), "idx": ap.i_cur % maxi(ap.m, 1),
					"v": snappedf(car.speed, 0.1), "contact": cb})
			last_spike_t = t_now
		# incident detection
		var road_y: float = (road["pts"][ap.i_cur % maxi(road["pts"].size() - 1, 1)] as Vector3).y if road["closed"] else (road["pts"][clampi(ap.i_cur, 0, road["pts"].size() - 1)] as Vector3).y
		if car.global_position.y < road_y - 6.0:
			stats["fell"] += 1
		var flipped := car.global_basis.y.y < 0.25
		off_t = off_t + dt if absf(ap.cte) > 7.0 else 0.0
		stuck_t = stuck_t + dt if (car.speed < 0.8 and ap.v_target > 4.0) else 0.0
		if flipped or off_t > 1.5 or stuck_t > 3.0 or car.global_position.y < road_y - 6.0:
			var cb2 := ""
			for b in car.get_colliding_bodies():
				cb2 += "%s/%s " % [b.get_parent().name, b.name]
			stats["incidents"].append({"kind": "flipped" if flipped else ("stuck" if stuck_t > 3.0 else ("fell" if car.global_position.y < road_y - 6.0 else "off_road")),
				"pos": car.global_position.snapped(Vector3(0.1, 0.1, 0.1)), "idx": ap.i_cur % maxi(ap.m, 1), "t": snappedf(n * dt, 0.1), "contact": cb2})
			# recover: respawn 40 samples ahead
			var next_i := ap.i_cur + 40
			if not road["closed"] and next_i >= ap.m - 2:
				break
			var pose := net.lane_pose(road, ap.i_cur + 40 if dir > 0 else (ap.m - 1 - (ap.i_cur + 40)), dir, 0.6)
			car.reset_to(pose, -pose.basis.z * 12.0)
			ap.i_cur += 40
			off_t = 0.0
			stuck_t = 0.0
			prev_vy = car.linear_velocity.y
			for k in 60:
				car.drive(0.2, 0, 0)
				await tree.physics_frame
	stats["time"] = n / 240.0
	stats["avg_speed"] = sum_v / maxf(float(n), 1.0)
	stats["finished"] = ap.finished
	stats["progress_samples"] = ap.i_cur - start
	stats["total_samples"] = lap_limit
	var tot := 0.0
	for k in stats["surfaces"]:
		tot += stats["surfaces"][k]
	var share := {}
	for k in stats["surfaces"]:
		share[k] = snappedf(100.0 * stats["surfaces"][k] / maxf(tot, 1.0), 0.1)
	stats["surfaces"] = share
	return stats

func _report(prefix: String, s: Dictionary) -> void:
	metric(prefix + "_finished", s["finished"])
	metric(prefix + "_time_s", s["time"])
	metric(prefix + "_avg_kmh", s["avg_speed"] * 3.6)
	metric(prefix + "_max_kmh", s["max_speed"] * 3.6)
	metric(prefix + "_dist_m", s["dist"])
	metric(prefix + "_max_cross_track_m", s["max_cte"])
	metric(prefix + "_max_vertical_g", s["max_vertical_g"])
	metric(prefix + "_spikes_over_2p5g", s["spikes"].size())
	metric(prefix + "_incidents", s["incidents"].size())
	metric(prefix + "_surface_share_pct", s["surfaces"])
	for k in range(mini(s["incidents"].size(), 6)):
		metric(prefix + "_incident_%d" % k, s["incidents"][k])
	var worst: Array = s["spikes"].duplicate()
	worst.sort_custom(func(a, b): return a["g"] > b["g"])
	for k in range(mini(worst.size(), 6)):
		metric(prefix + "_spike_%d" % k, worst[k])

func test_world_ring_lap() -> void:
	_load_world()
	var s := await _drive_route("ring", 1, 20, 0, 75.0, 0.75, 420.0, true)
	_report("ring", s)
	check(s["finished"], "ring: a full lap was completed")
	check(s["fell"] == 0, "ring: never fell through the world")
	check(s["incidents"].size() <= 3, "ring: at most 3 incidents (%d)" % s["incidents"].size())
	check(s["avg_speed"] * 3.6 > 90.0, "ring: average speed > 90 km/h (%.0f)" % (s["avg_speed"] * 3.6))
	check(s["surfaces"].has("asphalt"), "ring: asphalt under the wheels")
	await cleanup_world()

func cleanup_world() -> void:
	if w3d != null and _cam != null:
		_cam.global_position = car.global_position if car != null else Vector3.ZERO
		w3d.set_focus(_cam)
		await tree.physics_frame
	if car != null:
		car.queue_free()
		car = null
	if w3d != null:
		w3d.queue_free()
		w3d = null
	await tree.physics_frame
	await tree.physics_frame
	if _cam != null:
		_cam.queue_free()
		_cam = null
	world = null
	await tree.physics_frame

func test_world_mountain_pass() -> void:
	_load_world()
	var s := await _drive_route("mountain_pass", 1, 4, 0, 40.0, 0.6, 400.0)
	_report("pass", s)
	check(s["finished"] or s["progress_samples"] > 0.9 * s["total_samples"], "pass: driven to the end (%d/%d samples)" % [s["progress_samples"], s["total_samples"]])
	check(s["fell"] == 0, "pass: never fell through the world")
	check(s["incidents"].size() <= 3, "pass: at most 3 incidents (%d)" % s["incidents"].size())
	await cleanup_world()

func test_world_runway_max_speed() -> void:
	_load_world()
	var s := await _drive_route("runway", 1, 4, 0, 120.0, 0.8, 120.0)
	_report("runway", s)
	check(s["fell"] == 0, "runway: never fell through the world")
	check(s["incidents"].size() == 0, "runway: no incidents (%d)" % s["incidents"].size())
	check(s["max_speed"] * 3.6 > 250.0, "runway: reaches > 250 km/h (%.0f)" % (s["max_speed"] * 3.6))
	check(s["max_vertical_g"] < 2.0, "runway: smooth surface (%.2f g max vertical)" % s["max_vertical_g"])
	await cleanup_world()


## Road collision QA: for each road, ray columns at the centre and both lane lines every 1 m. Reports where the terrain
## collision is ABOVE the road collision (the car then drives on terrain: wrong surface, steps) and road-vs-road steps.
func test_world_road_surface_scan() -> void:
	_load_world()
	var focus := Node3D.new()
	tree.root.add_child(focus)
	w3d.set_focus(focus)
	var space := tree.root.get_world_3d().direct_space_state
	for rn in ["ring", "mountain_pass", "runway", "taxiway", "dirt_loop"]:
		var road := net.get_road(rn)
		if not road["paved"]:
			continue
		var n: int = road["pts"].size() - (1 if road["closed"] else 0)
		var samples := 0
		var over := 0
		var worst := 0.0
		var runs: Array = []
		var cur_run: Dictionary = {}
		var steps: Array = []
		var prev_road_h := {}
		var prev2_road_h := {}
		for k in range(0, n, 2):
			if k % 20 == 0:
				focus.global_position = net.lane_point(road, k, 1, 0.0)
				await tree.physics_frame
			for lane in [0.25, -0.25]:
				var p := net.lane_point(road, k, 1, lane)
				var ex: Array[RID] = []
				var road_h := NAN
				var terr_h := NAN
				var road_name := ""
				for j in 6:
					var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 5, 0), p - Vector3(0, 8, 0))
					q.exclude = ex
					var hit := space.intersect_ray(q)
					if hit.is_empty():
						break
					var col := hit["collider"] as Node
					if col.get_parent().name == road["name"] or String(col.name).begins_with("col"):
						if is_nan(road_h):
							road_h = hit["position"].y
							road_name = col.get_parent().name + "/" + col.name
					elif is_nan(terr_h):
						terr_h = hit["position"].y
					ex.append(hit["rid"])
				samples += 1
				if is_nan(road_h):
					continue
				var excess := (terr_h - road_h) if not is_nan(terr_h) else -1.0
				if excess > 0.005:
					over += 1
					worst = maxf(worst, excess)
					if cur_run.is_empty() or cur_run["lane"] != lane or k - cur_run["end"] > 3:
						if not cur_run.is_empty():
							runs.append(cur_run)
						cur_run = {"start": k, "end": k, "lane": lane, "max": excess, "pos": p.snapped(Vector3(0.1, 0.1, 0.1)), "on": road_name}
					else:
						cur_run["end"] = k
						cur_run["max"] = maxf(cur_run["max"], excess)
				# road-vs-road second difference along the lane (1-2 m spacing)
				var key := str(lane)
				if prev2_road_h.has(key) and not is_nan(prev2_road_h[key]):
					var d2: float = road_h - 2.0 * float(prev_road_h[key]) + float(prev2_road_h[key])
					if absf(d2) > 0.04:
						steps.append({"d2": snappedf(d2, 0.001), "pos": p.snapped(Vector3(0.1, 0.1, 0.1)), "idx": k, "on": road_name})
				prev2_road_h[key] = prev_road_h.get(key, NAN)
				prev_road_h[key] = road_h
		if not cur_run.is_empty():
			runs.append(cur_run)
		metric(rn + "_columns", samples)
		metric(rn + "_terrain_above_road_pct", 100.0 * over / maxf(samples, 1.0))
		metric(rn + "_terrain_above_road_max_m", worst)
		metric(rn + "_terrain_over_road_runs", runs.size())
		runs.sort_custom(func(a, b): return a["max"] > b["max"])
		for j in range(mini(runs.size(), 8)):
			metric(rn + "_over_run_%d" % j, runs[j])
		metric(rn + "_road_steps_over_4cm", steps.size())
		steps.sort_custom(func(a, b): return absf(a["d2"]) > absf(b["d2"]))
		for j in range(mini(steps.size(), 5)):
			metric(rn + "_road_step_%d" % j, steps[j])
	check(true, "scan done")
	focus.queue_free()
	await cleanup_world()
