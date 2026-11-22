class_name UIStyle
extends RefCounted
## Shared look of the menus: dark glass panels, orange accent, big readable text. One Theme built in code.

const ACCENT := Color(1.0, 0.46, 0.10)
const ACCENT_DIM := Color(0.78, 0.33, 0.07)
const BG := Color(0.05, 0.055, 0.07, 0.86)
const BG_LIGHT := Color(0.12, 0.13, 0.16, 0.92)
const TEXT := Color(0.94, 0.95, 0.97)
const TEXT_DIM := Color(0.62, 0.65, 0.72)
const GOOD := Color(0.35, 0.95, 0.50)
const BAD := Color(1.0, 0.32, 0.28)

static var _theme: Theme


static func box(bg: Color, border: Color = Color(0, 0, 0, 0), radius: int = 6, bw: int = 0, margin: Vector4 = Vector4(14, 8, 14, 8)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = margin.x
	s.content_margin_top = margin.y
	s.content_margin_right = margin.z
	s.content_margin_bottom = margin.w
	return s


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = 20
	# labels
	t.set_color("font_color", "Label", TEXT)
	# buttons
	t.set_stylebox("normal", "Button", box(Color(0.13, 0.14, 0.18, 0.92), Color(1, 1, 1, 0.10), 6, 1))
	t.set_stylebox("hover", "Button", box(Color(0.20, 0.17, 0.15, 0.96), ACCENT, 6, 2))
	t.set_stylebox("pressed", "Button", box(ACCENT_DIM, ACCENT, 6, 2))
	t.set_stylebox("focus", "Button", box(Color(0.20, 0.17, 0.15, 0.96), ACCENT, 6, 2))
	t.set_stylebox("disabled", "Button", box(Color(0.1, 0.1, 0.12, 0.6), Color(1, 1, 1, 0.05), 6, 1))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color(1, 1, 1))
	t.set_color("font_focus_color", "Button", Color(1, 1, 1))
	t.set_color("font_pressed_color", "Button", Color(1, 1, 1))
	t.set_color("font_disabled_color", "Button", TEXT_DIM)
	t.set_font_size("font_size", "Button", 24)
	for cls in ["OptionButton", "CheckBox", "CheckButton", "MenuButton"]:
		t.set_stylebox("normal", cls, box(Color(0.13, 0.14, 0.18, 0.92), Color(1, 1, 1, 0.10), 6, 1))
		t.set_stylebox("hover", cls, box(Color(0.20, 0.17, 0.15, 0.96), ACCENT, 6, 1))
		t.set_stylebox("pressed", cls, box(Color(0.20, 0.17, 0.15, 0.96), ACCENT, 6, 1))
		t.set_stylebox("focus", cls, box(Color(0.20, 0.17, 0.15, 0.96), ACCENT, 6, 2))
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_hover_color", cls, Color(1, 1, 1))
		t.set_font_size("font_size", cls, 20)
	# checkboxes keep a flat look with a plain box
	t.set_stylebox("normal", "CheckBox", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 0))
	t.set_stylebox("hover", "CheckBox", box(Color(1, 1, 1, 0.06), Color(0, 0, 0, 0), 4, 0))
	t.set_stylebox("pressed", "CheckBox", box(Color(1, 1, 1, 0.06), Color(0, 0, 0, 0), 4, 0))
	t.set_stylebox("focus", "CheckBox", box(Color(1, 1, 1, 0.08), ACCENT, 4, 1))
	# panels
	t.set_stylebox("panel", "PanelContainer", box(BG, Color(1, 1, 1, 0.08), 10, 1, Vector4(22, 18, 22, 18)))
	t.set_stylebox("panel", "Panel", box(BG, Color(1, 1, 1, 0.08), 10, 1))
	# tabs
	t.set_stylebox("panel", "TabContainer", box(Color(0.08, 0.09, 0.11, 0.8), Color(1, 1, 1, 0.08), 8, 1, Vector4(18, 14, 18, 14)))
	t.set_stylebox("tab_selected", "TabContainer", box(ACCENT_DIM, ACCENT, 6, 1, Vector4(16, 8, 16, 8)))
	t.set_stylebox("tab_unselected", "TabContainer", box(Color(0.12, 0.13, 0.16, 0.9), Color(1, 1, 1, 0.08), 6, 1, Vector4(16, 8, 16, 8)))
	t.set_stylebox("tab_hovered", "TabContainer", box(Color(0.2, 0.17, 0.15, 0.95), ACCENT, 6, 1, Vector4(16, 8, 16, 8)))
	t.set_stylebox("tab_focus", "TabContainer", box(Color(0, 0, 0, 0), ACCENT, 6, 2, Vector4(16, 8, 16, 8)))
	t.set_color("font_selected_color", "TabContainer", Color(1, 1, 1))
	t.set_color("font_unselected_color", "TabContainer", TEXT_DIM)
	t.set_color("font_hovered_color", "TabContainer", Color(1, 1, 1))
	t.set_font_size("font_size", "TabContainer", 21)
	# sliders
	var groove := box(Color(1, 1, 1, 0.14), Color(0, 0, 0, 0), 3, 0, Vector4(0, 4, 0, 4))
	groove.content_margin_top = 4
	groove.content_margin_bottom = 4
	t.set_stylebox("slider", "HSlider", groove)
	t.set_stylebox("grabber_area", "HSlider", box(ACCENT, Color(0, 0, 0, 0), 3, 0, Vector4(0, 4, 0, 4)))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(Color(1.0, 0.6, 0.25), Color(0, 0, 0, 0), 3, 0, Vector4(0, 4, 0, 4)))
	t.set_constant("center_grabber", "HSlider", 1)
	# popup menu (OptionButton list)
	t.set_stylebox("panel", "PopupMenu", box(Color(0.08, 0.09, 0.12, 0.98), ACCENT, 6, 1, Vector4(8, 6, 8, 6)))
	t.set_stylebox("hover", "PopupMenu", box(ACCENT_DIM, Color(0, 0, 0, 0), 4, 0))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_font_size("font_size", "PopupMenu", 20)
	_theme = t
	return t


static func label(text: String, size: int = 20, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, min_w: float = 320.0, min_h: float = 56.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, min_h)
	b.focus_mode = Control.FOCUS_ALL
	return b
