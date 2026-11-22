class_name TrialHUD
extends Control
## Time-trial HUD: lap timer, last / best lap, sector splits with the delta against the best lap, countdown and messages.

var trial: TimeTrial
var _panel: PanelContainer
var _lap_label: Label
var _time_label: Label
var _last_label: Label
var _best_label: Label
var _sector_labels: Array[Label] = []
var _delta_labels: Array[Label] = []
var _center: Label
var _msg: Label
var _hint: Label


func _ready() -> void:
	theme = UIStyle.theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = PanelContainer.new()
	_panel.position = Vector2(30, 30)
	_panel.custom_minimum_size = Vector2(380, 0)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_panel.add_child(vb)
	_lap_label = UIStyle.label("", 22, UIStyle.ACCENT)
	vb.add_child(_lap_label)
	_time_label = UIStyle.label("0:00.000", 60, Color.WHITE)
	vb.add_child(_time_label)
	_last_label = UIStyle.label("", 20, UIStyle.TEXT_DIM)
	vb.add_child(_last_label)
	_best_label = UIStyle.label("", 20, Color(0.75, 0.55, 1.0))
	vb.add_child(_best_label)
	var sep := HSeparator.new()
	vb.add_child(sep)
	for i in 4:
		var row := HBoxContainer.new()
		row.visible = false
		var l := UIStyle.label("", 20)
		l.custom_minimum_size = Vector2(190, 0)
		row.add_child(l)
		var d := UIStyle.label("", 20)
		d.custom_minimum_size = Vector2(120, 0)
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(d)
		vb.add_child(row)
		_sector_labels.append(l)
		_delta_labels.append(d)
	_center = UIStyle.label("", 150, Color.WHITE)
	_center.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_center.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_center.add_theme_constant_override("outline_size", 14)
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.position = Vector2(-300, 120)
	_center.size = Vector2(600, 180)
	add_child(_center)
	_msg = UIStyle.label("", 36, Color.WHITE)
	_msg.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_msg.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_msg.add_theme_constant_override("outline_size", 8)
	_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msg.position = Vector2(-450, 300)
	_msg.size = Vector2(900, 50)
	add_child(_msg)
	_hint = UIStyle.label("R: вернуться на последний створ (круг не засчитывается)   Esc: пауза", 16, UIStyle.TEXT_DIM)
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(-330, -36)
	_hint.size = Vector2(660, 26)
	add_child(_hint)
	_hint.modulate.a = 0.0


func _process(_dt: float) -> void:
	if trial == null:
		return
	var t := trial
	var closed := t.closed
	_lap_label.text = "%s  ·  круг %d" % [t.route_title(), t.lap] if closed else "%s  ·  заезд" % t.route_title()
	var cur := t.current_time()
	_time_label.text = TrialRecords.fmt_time(cur) if t.state != TimeTrial.State.COUNTDOWN and t.state != TimeTrial.State.WAITING else "0:00.000"
	_time_label.add_theme_color_override("font_color", UIStyle.BAD if t.invalid else Color.WHITE)
	_last_label.text = "Прошлый: %s" % TrialRecords.fmt_time(t.last_time)
	_best_label.text = "Лучший:  %s" % TrialRecords.fmt_time(float(t.best["time"]))
	var bs := t.best_splits()
	var total := t.sectors
	for i in 4:
		var row := _sector_labels[i].get_parent() as Control
		row.visible = i < total
		if i >= total:
			continue
		var txt := ""
		var col := UIStyle.TEXT_DIM
		var dl := _delta_labels[i]
		dl.text = ""
		if i == total - 1:
			# last sector ends at the finish gate: shows the lap time and the delta to the best lap
			txt = "Финиш  %s" % TrialRecords.fmt_time(t.last_time) if t.last_time > 0.0 else "Финиш"
			col = UIStyle.TEXT if t.last_time > 0.0 else UIStyle.TEXT_DIM
			if i == t.splits.size() and t.state == TimeTrial.State.RUNNING:
				col = UIStyle.ACCENT
			if t.last_time > 0.0 and not is_nan(t.last_delta):
				dl.text = TrialRecords.fmt_delta(t.last_delta)
				dl.add_theme_color_override("font_color", UIStyle.GOOD if t.last_delta <= 0.0 else UIStyle.BAD)
		else:
			var name := "Сектор %d" % (i + 1)
			if i < t.splits.size():
				txt = "%s  %s" % [name, TrialRecords.fmt_time(t.splits[i])]
				col = UIStyle.TEXT
				if i < bs.size() and float(t.best["time"]) > 0.0:
					var d := t.splits[i] - bs[i]
					dl.text = TrialRecords.fmt_delta(d)
					dl.add_theme_color_override("font_color", UIStyle.GOOD if d <= 0.0 else UIStyle.BAD)
			elif i == t.splits.size() and t.state == TimeTrial.State.RUNNING:
				txt = "%s  ..." % name
				col = UIStyle.ACCENT
			else:
				txt = name
				if i < bs.size():
					txt += "  " + TrialRecords.fmt_time(bs[i])
		_sector_labels[i].text = txt
		_sector_labels[i].add_theme_color_override("font_color", col)
	# countdown / messages
	if t.state == TimeTrial.State.COUNTDOWN:
		_center.text = str(maxi(ceili(t.countdown), 1)) if t.countdown > 0.0 else ""
		_center.modulate.a = 1.0
	else:
		_center.text = ""
	if t.message_t > 0.0:
		_msg.text = t.message
		_msg.modulate.a = clampf(t.message_t / 0.5, 0.0, 1.0)
		var good := t.message.begins_with("НОВЫЙ") or t.message.begins_with("СТАРТ")
		_msg.add_theme_color_override("font_color", UIStyle.GOOD if good else (UIStyle.BAD if t.message.contains("не засчитан") else Color.WHITE))
	else:
		_msg.text = ""
	_hint.modulate.a = 0.0 if t.state == TimeTrial.State.COUNTDOWN else 0.75
