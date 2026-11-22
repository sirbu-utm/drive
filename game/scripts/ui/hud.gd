class_name HUD
extends CanvasLayer
## Minimal driving HUD: analog tachometer with redline, speed (km/h), gear, ABS/TCS/ESC indicators, minimap.
## Labels are in Russian. All values come from the Vehicle (speed_kmh, rpm, gear, assists).

@export var vehicle: Vehicle
var dial: Dial
var minimap: Minimap
var _toast: Label
var _toast_t := 0.0
var _mode_label: Label
var _net: RoadNet


class Dial extends Control:
	var vehicle: Vehicle
	var rpm_max := 9500.0
	var redline := 8500.0
	var rpm_shown := 1000.0
	const A0 := PI * 0.75
	const SWEEP := PI * 1.5

	func _ang(rpm: float) -> float:
		return A0 + SWEEP * clampf(rpm / rpm_max, 0.0, 1.0)

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 6.0
		draw_circle(c, r + 4.0, Color(0, 0, 0, 0.55))
		draw_arc(c, r, A0, A0 + SWEEP, 96, Color(1, 1, 1, 0.35), 2.0, true)
		draw_arc(c, r - 5.0, _ang(redline), _ang(rpm_max), 24, Color(0.95, 0.12, 0.1), 9.0, true)
		var font := ThemeDB.fallback_font
		for k in range(0, 20):
			var rpm := k * 500.0
			if rpm > rpm_max:
				break
			var a := _ang(rpm)
			var big := k % 2 == 0
			var d := Vector2(cos(a), sin(a))
			var col := Color(0.95, 0.15, 0.12) if rpm >= redline else Color(1, 1, 1)
			draw_line(c + d * (r - (16.0 if big else 9.0)), c + d * (r - 1.0), col, 3.0 if big else 1.5, true)
			if big:
				var t := str(int(rpm / 1000.0))
				var ts := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 17)
				draw_string(font, c + d * (r - 32.0) - Vector2(ts.x * 0.5, -ts.y * 0.3), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, col)
		# labels
		var lbl := "об/мин x1000"
		var ls := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		draw_string(font, c + Vector2(-ls.x * 0.5, -r * 0.42), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.65))
		# needle
		var a2 := _ang(rpm_shown)
		var nd := Vector2(cos(a2), sin(a2))
		var ncol := Color(1.0, 0.25, 0.1) if rpm_shown >= redline else Color(1.0, 0.72, 0.15)
		draw_line(c - nd * 14.0, c + nd * (r - 12.0), ncol, 4.0, true)
		draw_circle(c, 9.0, Color(0.1, 0.1, 0.1))
		draw_circle(c, 5.0, ncol)
		# gear
		var g := vehicle.gear if vehicle != null else 0
		var gs := "R" if g < 0 else ("N" if g == 0 else str(g))
		var gsz := font.get_string_size(gs, HORIZONTAL_ALIGNMENT_LEFT, -1, 52)
		draw_string(font, c + Vector2(-gsz.x * 0.5, r * 0.40), gs, HORIZONTAL_ALIGNMENT_LEFT, -1, 52, Color(1, 1, 1))
		# speed
		var spd := str(int(round(absf(vehicle.speed_kmh)))) if vehicle != null else "0"
		var ssz := font.get_string_size(spd, HORIZONTAL_ALIGNMENT_LEFT, -1, 34)
		draw_string(font, c + Vector2(-ssz.x * 0.5, r * 0.40 + 38.0), spd, HORIZONTAL_ALIGNMENT_LEFT, -1, 34, Color(1, 1, 1))
		var ku := "км/ч"
		var kus := font.get_string_size(ku, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
		draw_string(font, c + Vector2(-kus.x * 0.5, r * 0.40 + 58.0), ku, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.7))


class Indicators extends Control:
	var vehicle: Vehicle
	var blink := 0.0

	func _draw() -> void:
		if vehicle == null:
			return
		var font := ThemeDB.fallback_font
		var a := vehicle.assists
		var items := [["ABS", a.abs_on, a.abs_active], ["TCS", a.tcs_on, a.tcs_active], ["ESC", a.esc_on, a.esc_active]]
		var w := 66.0
		for i in items.size():
			var it: Array = items[i]
			var x := float(i) * (w + 8.0)
			var r := Rect2(x, 0, w, 30)
			var on: bool = it[1]
			var act: bool = it[2]
			var bg := Color(0.05, 0.05, 0.05, 0.6)
			var fg := Color(0.5, 0.5, 0.5)
			if on:
				fg = Color(0.4, 0.95, 0.5)
			if act:
				bg = Color(0.95, 0.6, 0.05, 0.95)
				fg = Color(0.05, 0.05, 0.05)
			draw_rect(r, bg, true)
			draw_rect(r, Color(1, 1, 1, 0.25), false, 1.0)
			var ts := font.get_string_size(it[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 17)
			draw_string(font, Vector2(x + (w - ts.x) * 0.5, 21.0), it[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, fg)
			if not on:
				draw_line(Vector2(x + 6, 24), Vector2(x + w - 6, 6), Color(1, 0.3, 0.2, 0.8), 2.0)
		# manual gearbox / handbrake marks
		var xm := 3.0 * (w + 8.0)
		var man := not vehicle.drivetrain.auto
		var hb := vehicle.handbrake > 0.3
		if man:
			draw_rect(Rect2(xm, 0, w, 30), Color(0.05, 0.05, 0.05, 0.6), true)
			draw_string(font, Vector2(xm + 10, 21.0), "МКПП", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.4, 0.8, 1.0))
		if hb:
			draw_rect(Rect2(xm + (w + 8.0 if man else 0.0), 0, w, 30), Color(0.9, 0.1, 0.1, 0.85), true)
			draw_string(font, Vector2(xm + (w + 8.0 if man else 0.0) + 8, 21.0), "РУЧНИК", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1))


var indicators: Indicators


func _ready() -> void:
	layer = 20
	_net = RoadNet.new()
	dial = Dial.new()
	dial.vehicle = vehicle
	dial.custom_minimum_size = Vector2(270, 270)
	dial.size = Vector2(270, 270)
	dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	dial.position = Vector2(-300, -330)
	add_child(dial)
	indicators = Indicators.new()
	indicators.vehicle = vehicle
	indicators.size = Vector2(300, 30)
	indicators.mouse_filter = Control.MOUSE_FILTER_IGNORE
	indicators.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	indicators.position = Vector2(-325, -50)
	add_child(indicators)
	minimap = Minimap.new()
	minimap.net = _net
	minimap.vehicle = vehicle
	minimap.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	minimap.position = Vector2(30, -260)
	add_child(minimap)
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.position = Vector2(-220, 40)
	_toast.size = Vector2(440, 40)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", 26)
	_toast.add_theme_color_override("font_color", Color(1, 1, 1))
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.modulate.a = 0.0
	add_child(_toast)


func show_toast(text: String) -> void:
	_toast.text = text
	_toast_t = 2.2


func set_vehicle(v: Vehicle) -> void:
	vehicle = v
	if dial:
		dial.vehicle = v
		indicators.vehicle = v
		minimap.vehicle = v


func _process(dt: float) -> void:
	if vehicle == null or dial == null:
		return
	# the needle follows the engine with a little smoothing so it does not flicker
	dial.rpm_shown = lerpf(dial.rpm_shown, vehicle.rpm, 1.0 - exp(-dt * 25.0))
	dial.queue_redraw()
	indicators.queue_redraw()
	if _toast_t > 0.0:
		_toast_t -= dt
		_toast.modulate.a = clampf(_toast_t / 0.5, 0.0, 1.0)
