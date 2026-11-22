class_name PauseMenu
extends Control
## Pause (Esc): Продолжить / Перезапустить заезд (only in the time trial) / Настройки / В главное меню.

signal resume
signal restart
signal settings_requested
signal to_menu

var _restart_btn: Button
var _first: Button
var _title: Label


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
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	_title = UIStyle.label("ПАУЗА", 40, UIStyle.ACCENT)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_title)
	_first = _btn(vb, "Продолжить", func(): resume.emit())
	_restart_btn = _btn(vb, "Перезапустить заезд", func(): restart.emit())
	_btn(vb, "Настройки", func(): settings_requested.emit())
	_btn(vb, "В главное меню", func(): to_menu.emit())
	visible = false


func _btn(parent: Control, text: String, cb: Callable) -> Button:
	var b := UIStyle.button(text, 380, 58)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func open(trial: bool) -> void:
	_restart_btn.visible = trial
	visible = true
	_first.grab_focus()
