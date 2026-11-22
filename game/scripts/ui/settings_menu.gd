class_name SettingsMenu
extends Control
## Settings (Russian UI). Tabs: Графика / Экран / Помощники / Управление / Звук / Автомобиль.
## Every change is applied immediately and persisted (GraphicsSettings / GameSettings -> user://settings.cfg).

signal closed

const SWATCHES := [
	["Красный", Color(0.62, 0.035, 0.03)], ["Оранжевый", Color(0.9, 0.35, 0.03)], ["Жёлтый", Color(0.9, 0.7, 0.05)],
	["Зелёный", Color(0.05, 0.38, 0.14)], ["Синий", Color(0.04, 0.12, 0.55)], ["Белый", Color(0.9, 0.9, 0.88)],
	["Серый", Color(0.30, 0.31, 0.34)], ["Чёрный", Color(0.025, 0.025, 0.03)],
]

var tabs: TabContainer
var _updating := false
var _preset_opt: OptionButton
var _gfx_controls := {}                # key -> Control (refreshed when the preset changes)
var _graphics_tab: Control


func _ready() -> void:
	theme = UIStyle.theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1060, 720)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	vb.add_child(UIStyle.label("НАСТРОЙКИ", 34, UIStyle.ACCENT))
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(tabs)
	_build_graphics()
	_build_display()
	_build_assists()
	_build_controls()
	_build_audio()
	_build_car()
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	vb.add_child(row)
	var back := UIStyle.button("Назад", 220, 52)
	back.pressed.connect(close)
	row.add_child(back)
	visible = false


func open(tab: int = -1) -> void:
	_refresh_all()
	if tab >= 0:
		tabs.current_tab = tab
	visible = true
	tabs.get_tab_bar().grab_focus()


func close() -> void:
	visible = false
	GameSettings.save()
	closed.emit()


# ---- widgets -----------------------------------------------------------------------------------------------

func _page(title: String) -> GridContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 40)
	g.add_theme_constant_override("v_separation", 12)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(g)
	tabs.add_child(sc)
	return g


func _row_label(g: GridContainer, text: String) -> void:
	var l := UIStyle.label(text, 21)
	l.custom_minimum_size = Vector2(380, 40)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.add_child(l)


func _option(g: GridContainer, text: String, items: Array, cb: Callable) -> OptionButton:
	_row_label(g, text)
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(300, 40)
	for it in items:
		o.add_item(str(it))
	o.item_selected.connect(func(i: int): if not _updating: cb.call(i))
	g.add_child(o)
	return o


func _check(g: GridContainer, text: String, cb: Callable) -> CheckBox:
	_row_label(g, text)
	var c := CheckBox.new()
	c.text = "вкл"
	c.custom_minimum_size = Vector2(300, 40)
	c.toggled.connect(func(on: bool):
		c.text = "вкл" if on else "выкл"
		if not _updating:
			cb.call(on))
	g.add_child(c)
	return c


func _slider(g: GridContainer, text: String, lo: float, hi: float, step: float, fmt: Callable, cb: Callable) -> HSlider:
	_row_label(g, text)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size = Vector2(260, 40)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := UIStyle.label("", 20, UIStyle.TEXT_DIM)
	val.custom_minimum_size = Vector2(80, 0)
	s.value_changed.connect(func(v: float):
		val.text = fmt.call(v)
		if not _updating:
			cb.call(v))
	h.add_child(s)
	h.add_child(val)
	g.add_child(h)
	s.set_meta("val_label", val)
	s.set_meta("fmt", fmt)
	return s


func _set_slider(s: HSlider, v: float) -> void:
	s.value = v
	(s.get_meta("val_label") as Label).text = (s.get_meta("fmt") as Callable).call(v)


# ---- tabs --------------------------------------------------------------------------------------------------

func _build_graphics() -> void:
	var g := _page("Графика")
	_graphics_tab = g
	_preset_opt = _option(g, "Пресет качества", GraphicsSettings.PRESET_NAMES, func(i: int):
		if i <= 3:
			GraphicsSettings.set_preset(i)
			_refresh_graphics())
	var gs := GraphicsSettings
	_gfx_controls["msaa"] = _option(g, "Сглаживание MSAA", gs.MSAA_NAMES, func(i: int): gs.set_option("msaa", i))
	_gfx_controls["aa"] = _option(g, "Сглаживание экрана", gs.AA_NAMES, func(i: int): gs.set_option("aa", i))
	_gfx_controls["aniso"] = _option(g, "Анизотропная фильтрация", gs.ANISO_NAMES, func(i: int): gs.set_option("aniso", i))
	_gfx_controls["shadow_size"] = _option(g, "Качество теней", gs.SHADOW_NAMES, func(i: int):
		gs.set_option("shadow_size", i)
		gs.set_option("shadow_quality", [1, 2, 3, 4][i]))
	_gfx_controls["shadow_distance"] = _slider(g, "Дальность теней", 80.0, 800.0, 10.0, func(v: float): return "%d м" % int(v), func(v: float): gs.set_option("shadow_distance", v))
	_gfx_controls["ssao"] = _check(g, "Затенение SSAO", func(on: bool): gs.set_option("ssao", on))
	_gfx_controls["ssil"] = _check(g, "Непрямое освещение SSIL", func(on: bool): gs.set_option("ssil", on))
	_gfx_controls["ssr"] = _check(g, "Отражения SSR", func(on: bool): gs.set_option("ssr", on))
	_gfx_controls["sdfgi"] = _check(g, "Глобальное освещение SDFGI", func(on: bool): gs.set_option("sdfgi", on))
	_gfx_controls["glow"] = _check(g, "Свечение (Glow)", func(on: bool): gs.set_option("glow", on))
	_gfx_controls["vfog"] = _check(g, "Объёмный туман", func(on: bool): gs.set_option("vfog", on))
	_gfx_controls["grass"] = _check(g, "Трава (GPU)", func(on: bool): gs.set_option("grass", on))
	_gfx_controls["motion_blur"] = _slider(g, "Размытие в движении", 0.0, 1.0, 0.05, func(v: float): return "выкл" if v < 0.01 else "%d %%" % int(round(v * 100.0)), func(v: float): gs.set_option("motion_blur", v))
	_gfx_controls["sharpen"] = _slider(g, "Резкость", 0.0, 1.0, 0.05, func(v: float): return "выкл" if v < 0.01 else "%d %%" % int(round(v * 100.0)), func(v: float): gs.set_option("sharpen", v))
	_gfx_controls["car_reflections"] = _option(g, "Отражения на машине", gs.CAR_REFLECTION_NAMES, func(i: int): gs.set_option("car_reflections", i))
	_gfx_controls["tree_distance"] = _slider(g, "Дальность прорисовки деревьев", 0.2, 2.0, 0.05, func(v: float): return "%d %%" % int(v * 100.0), func(v: float): gs.set_option("tree_distance", v))


func _build_display() -> void:
	var g := _page("Экран")
	var gs := GraphicsSettings
	_gfx_controls["window_mode"] = _option(g, "Режим окна", ["Окно", "Полный экран"], func(i: int): gs.set_option("window_mode", i))
	var rs: Array = []
	for r in gs.RESOLUTIONS:
		rs.append("%dx%d" % [r.x, r.y])
	_gfx_controls["resolution"] = _option(g, "Разрешение (оконный режим)", rs, func(i: int): gs.set_option("resolution", i))
	_gfx_controls["vsync"] = _check(g, "Вертикальная синхронизация", func(on: bool): gs.set_option("vsync", on))
	_gfx_controls["fps_cap"] = _option(g, "Ограничение FPS", ["Без ограничения", "60", "120", "144", "240"], func(i: int): gs.set_option("fps_cap", [0, 60, 120, 144, 240][i]))
	_gfx_controls["scale"] = _slider(g, "Масштаб рендера", 0.5, 1.0, 0.01, func(v: float): return "%d %%" % int(round(v * 100.0)), func(v: float): gs.set_option("scale", v))
	_gfx_controls["upscaler"] = _option(g, "Апскейлер (при масштабе < 100 %)", gs.UPSCALER_NAMES, func(i: int): gs.set_option("upscaler", i))
	g.add_child(Control.new())
	var note := UIStyle.label("FSR 2 восстанавливает детали при сниженном масштабе рендера.", 17, UIStyle.TEXT_DIM)
	g.add_child(note)


func _build_assists() -> void:
	var g := _page("Помощники")
	var gm := GameSettings
	_gfx_controls["a_abs"] = _check(g, "ABS (антиблокировка тормозов)", func(on: bool): gm.set_value("assists", "abs", on))
	_gfx_controls["a_tcs"] = _check(g, "TCS (контроль тяги)", func(on: bool): gm.set_value("assists", "tcs", on))
	_gfx_controls["a_esc"] = _check(g, "ESC (курсовая устойчивость)", func(on: bool): gm.set_value("assists", "esc", on))
	_gfx_controls["a_cs"] = _check(g, "Помощь при контрсвале", func(on: bool): gm.set_value("assists", "countersteer", on))
	_gfx_controls["a_gear"] = _option(g, "Коробка передач", ["Автомат", "Механика (E / Q)"], func(i: int): gm.set_value("controls", "manual_gearbox", i == 1))


func _build_controls() -> void:
	var g := _page("Управление")
	var gm := GameSettings
	_gfx_controls["c_sens"] = _slider(g, "Чувствительность руля", 0.5, 1.5, 0.05, func(v: float): return "%d %%" % int(round(v * 100.0)), func(v: float): gm.set_value("controls", "steer_sensitivity", v))
	_gfx_controls["c_lin"] = _slider(g, "Линейность руля (1 = прямая)", 1.0, 2.5, 0.05, func(v: float): return "%.2f" % v, func(v: float): gm.set_value("controls", "steer_linearity", v))
	_gfx_controls["c_dz"] = _slider(g, "Мёртвая зона стика", 0.0, 0.25, 0.01, func(v: float): return "%d %%" % int(round(v * 100.0)), func(v: float): gm.set_value("controls", "deadzone", v))
	var keys := [
		["Газ / тормоз и задний ход", "W / S  или  стрелки;  геймпад: правый / левый триггер"],
		["Руль", "A / D  или  стрелки;  геймпад: левый стик"],
		["Ручной тормоз", "Пробел;  геймпад: A"],
		["Передачи (механика)", "E / Q  или  Shift / Ctrl;  геймпад: RB / LB"],
		["Камера", "C;  геймпад: Y;  ПКМ + мышь: обзор вокруг машины"],
		["Вернуть на дорогу", "R;  геймпад: Back"],
		["Фары (по умолчанию автоматически)", "L;  геймпад: D-pad вверх"],
		["Телеметрия", "F1"],
		["ABS / TCS / ESC / контрсвал", "F2 / F3 / F4 / F6"],
		["Автомат / механика", "F5;  геймпад: X"],
		["Пауза / меню", "Esc"],
	]
	var sep := Control.new()
	g.add_child(sep)
	g.add_child(UIStyle.label("Клавиши", 24, UIStyle.ACCENT))
	for k in keys:
		_row_label(g, k[0])
		g.add_child(UIStyle.label(k[1], 18, UIStyle.TEXT_DIM))


func _build_audio() -> void:
	var g := _page("Звук")
	var pct := func(v: float): return "%d %%" % int(round(v * 100.0))
	for it in [["Общая громкость", "master"], ["Двигатель", "engine"], ["Шины, удары, трансмиссия", "effects"], ["Ветер и окружение", "ambience"]]:
		var key: String = it[1]
		_gfx_controls["s_" + key] = _slider(g, it[0], 0.0, 1.0, 0.01, pct, func(v: float):
			GameSettings.set_value("audio", key, v)
			GameSettings.apply_audio())


func _build_car() -> void:
	var g := _page("Автомобиль")
	_row_label(g, "Цвет кузова")
	var sw := GridContainer.new()
	sw.columns = 4
	sw.add_theme_constant_override("h_separation", 10)
	sw.add_theme_constant_override("v_separation", 10)
	for s in SWATCHES:
		var b := Button.new()
		b.custom_minimum_size = Vector2(110, 44)
		b.text = s[0]
		b.add_theme_font_size_override("font_size", 16)
		var c: Color = s[1]
		b.add_theme_stylebox_override("normal", UIStyle.box(c, Color(1, 1, 1, 0.35), 6, 1))
		b.add_theme_stylebox_override("hover", UIStyle.box(c.lightened(0.15), UIStyle.ACCENT, 6, 2))
		b.add_theme_stylebox_override("pressed", UIStyle.box(c, UIStyle.ACCENT, 6, 2))
		b.add_theme_stylebox_override("focus", UIStyle.box(c, UIStyle.ACCENT, 6, 3))
		b.add_theme_color_override("font_color", Color.WHITE if c.get_luminance() < 0.5 else Color.BLACK)
		b.add_theme_color_override("font_hover_color", Color.WHITE if c.get_luminance() < 0.5 else Color.BLACK)
		b.pressed.connect(func(): _set_paint(c))
		sw.add_child(b)
	g.add_child(sw)
	_row_label(g, "Свой цвет")
	var cp := ColorPickerButton.new()
	cp.custom_minimum_size = Vector2(300, 44)
	cp.edit_alpha = false
	cp.color_changed.connect(func(c: Color): if not _updating: _set_paint(c, false))
	g.add_child(cp)
	_gfx_controls["car_color"] = cp


func _set_paint(c: Color, update_picker: bool = true) -> void:
	GameSettings.set_value("car", "color", c)
	if update_picker:
		_updating = true
		(_gfx_controls["car_color"] as ColorPickerButton).color = c
		_updating = false


# ---- refresh -----------------------------------------------------------------------------------------------

func _refresh_all() -> void:
	_refresh_graphics()
	_updating = true
	var gm := GameSettings
	(_gfx_controls["a_abs"] as CheckBox).button_pressed = bool(gm.get_value("assists", "abs"))
	(_gfx_controls["a_tcs"] as CheckBox).button_pressed = bool(gm.get_value("assists", "tcs"))
	(_gfx_controls["a_esc"] as CheckBox).button_pressed = bool(gm.get_value("assists", "esc"))
	(_gfx_controls["a_cs"] as CheckBox).button_pressed = bool(gm.get_value("assists", "countersteer"))
	(_gfx_controls["a_gear"] as OptionButton).select(1 if bool(gm.get_value("controls", "manual_gearbox")) else 0)
	_set_slider(_gfx_controls["c_sens"], float(gm.get_value("controls", "steer_sensitivity")))
	_set_slider(_gfx_controls["c_lin"], float(gm.get_value("controls", "steer_linearity")))
	_set_slider(_gfx_controls["c_dz"], float(gm.get_value("controls", "deadzone")))
	for key in ["master", "engine", "effects", "ambience"]:
		_set_slider(_gfx_controls["s_" + key], float(gm.get_value("audio", key)))
	(_gfx_controls["car_color"] as ColorPickerButton).color = gm.get_value("car", "color")
	for k in ["a_abs", "a_tcs", "a_esc", "a_cs"]:
		var c := _gfx_controls[k] as CheckBox
		c.text = "вкл" if c.button_pressed else "выкл"
	_updating = false


func _refresh_graphics() -> void:
	_updating = true
	var gs := GraphicsSettings
	var v := gs.values
	_preset_opt.select(clampi(gs.preset, 0, 4))
	for k in ["msaa", "aa", "aniso"]:
		(_gfx_controls[k] as OptionButton).select(clampi(int(v[k]), 0, (_gfx_controls[k] as OptionButton).item_count - 1))
	(_gfx_controls["shadow_size"] as OptionButton).select(clampi(int(v["shadow_size"]), 0, 3))
	_set_slider(_gfx_controls["shadow_distance"], float(v["shadow_distance"]))
	for k in ["ssao", "ssil", "ssr", "sdfgi", "glow", "vfog", "grass"]:
		var c := _gfx_controls[k] as CheckBox
		c.button_pressed = bool(v[k])
		c.text = "вкл" if c.button_pressed else "выкл"
	_set_slider(_gfx_controls["tree_distance"], float(v["tree_distance"]))
	_set_slider(_gfx_controls["motion_blur"], float(v["motion_blur"]))
	_set_slider(_gfx_controls["sharpen"], float(v["sharpen"]))
	(_gfx_controls["car_reflections"] as OptionButton).select(clampi(int(v["car_reflections"]), 0, 2))
	var d := gs.display
	(_gfx_controls["window_mode"] as OptionButton).select(int(d["window_mode"]))
	(_gfx_controls["resolution"] as OptionButton).select(clampi(int(d["resolution"]), 0, gs.RESOLUTIONS.size() - 1))
	var vs := _gfx_controls["vsync"] as CheckBox
	vs.button_pressed = bool(d["vsync"])
	vs.text = "вкл" if vs.button_pressed else "выкл"
	(_gfx_controls["fps_cap"] as OptionButton).select(maxi(0, [0, 60, 120, 144, 240].find(int(d["fps_cap"]))))
	_set_slider(_gfx_controls["scale"], float(v["scale"]))
	(_gfx_controls["upscaler"] as OptionButton).select(int(v["upscaler"]))
	_updating = false
