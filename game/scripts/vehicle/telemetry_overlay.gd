class_name TelemetryOverlay
extends CanvasLayer
## F1 telemetry: speed, rpm, gear, assists, per-wheel load / slip / travel / force, g-g diagram and a scrolling
## graph of slip ratios + speed. Off in release builds (starts hidden).

@export var vehicle: Vehicle
var _label: Label
var _graph: GraphView

const HISTORY := 600     # samples (10 s at 60 Hz)


class GraphView extends Control:
	var gg: PackedVector2Array = PackedVector2Array()
	var slip: Array = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
	var speed := PackedFloat32Array()
	const COLORS := [Color(1, 0.4, 0.3), Color(1, 0.8, 0.3), Color(0.4, 0.8, 1), Color(0.5, 1, 0.5)]

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))
		# g-g diagram (left square)
		var c := Vector2(110, 120)
		var r := 90.0
		for g in [0.5, 1.0, 1.5]:
			draw_arc(c, r * g / 1.6, 0.0, TAU, 48, Color(1, 1, 1, 0.25), 1.0)
		draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(1, 1, 1, 0.3))
		draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(1, 1, 1, 0.3))
		for i in gg.size():
			var a := float(i) / float(maxi(gg.size(), 1))
			draw_circle(c + Vector2(gg[i].x, -gg[i].y) * r / 1.6, 2.0, Color(0.4, 1, 0.5, a))
		# slip graph (right)
		var o := Vector2(240, 20)
		var gs := Vector2(size.x - 260, 200)
		draw_rect(Rect2(o, gs), Color(1, 1, 1, 0.07))
		draw_line(o + Vector2(0, gs.y * 0.5), o + Vector2(gs.x, gs.y * 0.5), Color(1, 1, 1, 0.3))
		for w in 4:
			var s: PackedFloat32Array = slip[w]
			var pts := PackedVector2Array()
			for i in s.size():
				pts.append(o + Vector2(gs.x * float(i) / HISTORY, gs.y * (0.5 - clampf(s[i], -0.5, 0.5))))
			if pts.size() > 1:
				draw_polyline(pts, COLORS[w], 1.5)
		var sp := PackedVector2Array()
		for i in speed.size():
			sp.append(o + Vector2(gs.x * float(i) / HISTORY, gs.y * (1.0 - speed[i] / 100.0)))
		if sp.size() > 1:
			draw_polyline(sp, Color(1, 1, 1, 0.8), 1.0)


func _ready() -> void:
	layer = 50
	visible = false
	_label = Label.new()
	_label.position = Vector2(16, 16)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)
	_graph = GraphView.new()
	_graph.position = Vector2(16, 330)
	_graph.size = Vector2(720, 240)
	add_child(_graph)


func toggle() -> void:
	visible = not visible


func _process(_dt: float) -> void:
	if not visible or vehicle == null or vehicle.wheels.is_empty():
		return
	var v := vehicle
	var d := v.drivetrain
	var t := "%3.0f km/h   %4.0f rpm   gear %s%s   thr %.2f  brk %.2f  steer %.1f deg\n" % [v.speed_kmh, d.rpm,
		("R" if d.gear < 0 else ("N" if d.gear == 0 else str(d.gear))), (" (auto)" if d.auto else " (manual)"),
		v.throttle_pedal, v.brake_pedal, rad_to_deg(v.steer_angle_cmd)]
	t += "g lat %+.2f  long %+.2f   yaw %+.2f rad/s   clutch %s %.0f Nm   limiter %s\n" % [v.g_lat, v.g_long, v.yaw_rate,
		("lock" if d.clutch_locked else "slip"), d.clutch_torque, str(d.limiter)]
	t += "ABS %s%s  TCS %s%s(%.2f)  ESC %s%s  aero drag %.0f N  down %.0f N\n" % [
		("on" if v.assists.abs_on else "off"), ("*" if v.assists.abs_active else ""),
		("on" if v.assists.tcs_on else "off"), ("*" if v.assists.tcs_active else ""), v.assists.tcs_scale,
		("on" if v.assists.esc_on else "off"), ("*" if v.assists.esc_active else ""), v.aero.drag_n, v.aero.downforce_n]
	t += "        load[N]   kappa    alpha[deg]  travel[mm]  Fx[N]   Fy[N]   surf\n"
	for i in 4:
		var w := v.wheels[i]
		t += "%s  %7.0f  %+6.3f  %+7.2f  %+7.1f  %+7.0f  %+7.0f  %s%s\n" % [Vehicle.WHEEL_NAMES[i], w.fz, w.kappa,
			rad_to_deg(w.alpha), w.comp * 1000.0, w.fx, w.fy, w.surface_key, ("" if w.in_contact else " AIR")]
	_label.text = t
	_graph.gg.append(Vector2(v.g_lat, v.g_long))
	if _graph.gg.size() > 90:
		_graph.gg.remove_at(0)
	for i in 4:
		var s: PackedFloat32Array = _graph.slip[i]
		s.append(v.wheels[i].kappa)
		if s.size() > HISTORY:
			s.remove_at(0)
		_graph.slip[i] = s
	_graph.speed.append(v.speed_kmh / 3.6)
	if _graph.speed.size() > HISTORY:
		_graph.speed.remove_at(0)
	_graph.queue_redraw()
