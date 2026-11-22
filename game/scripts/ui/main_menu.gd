class_name MainMenu
extends Control
## Main menu: Свободная езда / Заезд на время / Настройки / Выход. The time-trial entry opens a route selector with best laps.
## The world and the car are visible behind it (the car drives itself around the ring).

signal free_ride
signal trial_selected(route: String)
signal settings_requested
signal quit_requested

const ROUTES := [["ring", "Кольцо"], ["mountain_pass", "Горный перевал"]]

var _main: Control
var _routes: Control
var _first: Button
var _first_route: Button
var _best_labels := {}


func _ready() -> void:
	theme = UIStyle.theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# soft vignette on the left so the buttons read well over any scene
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.78))
	grad.set_color(1, Color(0, 0, 0, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0, 0.5)
	gt.fill_to = Vector2(1, 0.5)
	var vig := TextureRect.new()
	vig.texture = gt
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.anchor_right = 0.55
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vig)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 90)
	margin.add_theme_constant_override("margin_top", 70)
	margin.add_theme_constant_override("margin_bottom", 60)
	add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	margin.add_child(col)
	var title := UIStyle.label("DRIVE1", 96, Color.WHITE)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("outline_size", 10)
	col.add_child(title)
	var sub := UIStyle.label("5.0 V8  ·  открытый мир  ·  симулятор вождения", 22, UIStyle.ACCENT)
	col.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 40)
	col.add_child(gap)

	_main = VBoxContainer.new()
	(_main as VBoxContainer).add_theme_constant_override("separation", 14)
	col.add_child(_main)
	_first = _add_button(_main, "Свободная езда", func(): free_ride.emit())
	_add_button(_main, "Заезд на время", _show_routes)
	_add_button(_main, "Настройки", func(): settings_requested.emit())
	_add_button(_main, "Выход", func(): quit_requested.emit())

	_routes = VBoxContainer.new()
	(_routes as VBoxContainer).add_theme_constant_override("separation", 14)
	col.add_child(_routes)
	_routes.add_child(UIStyle.label("Выберите трассу", 28, UIStyle.TEXT))
	for r in ROUTES:
		var key: String = r[0]
		var b := _add_button(_routes, r[1], func(): trial_selected.emit(key))
		if _first_route == null:
			_first_route = b
		var l := UIStyle.label("", 19, UIStyle.TEXT_DIM)
		_best_labels[key] = l
		_routes.add_child(l)
	_add_button(_routes, "Назад", show_main, 320, 48)
	_routes.visible = false

	var hint := UIStyle.label("W/S газ и тормоз  ·  A/D руль  ·  C камера  ·  R вернуть на дорогу  ·  Esc пауза", 18, UIStyle.TEXT_DIM)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(90, -40)
	hint.size = Vector2(1200, 30)
	add_child(hint)
	visible = false


func _add_button(parent: Control, text: String, cb: Callable, w: float = 380.0, h: float = 62.0) -> Button:
	var b := UIStyle.button(text, w, h)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _refresh_best() -> void:
	for r in ROUTES:
		var rec := TrialRecords.best(r[0])
		var t: float = rec["time"]
		(_best_labels[r[0]] as Label).text = "    лучшее время: %s" % TrialRecords.fmt_time(t) if t > 0.0 else "    лучшее время: нет"


func _show_routes() -> void:
	_refresh_best()
	_main.visible = false
	_routes.visible = true
	_first_route.grab_focus()


func show_main() -> void:
	_routes.visible = false
	_main.visible = true
	_first.grab_focus()


func open() -> void:
	visible = true
	show_main()


## Esc: returns true when it closed a sub-screen
func back() -> bool:
	if _routes.visible:
		show_main()
		return true
	return false
