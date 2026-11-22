extends Node
## Autoload "GameSettings": persistent settings (user://settings.cfg) for everything except graphics, plus the session
## (what the player chose in the menu). Sections: audio, assists, controls, car, game.

signal changed(section: String, key: String)

const PATH := "user://settings.cfg"

const DEFAULTS := {
	"audio": {"master": 0.85, "engine": 1.0, "effects": 1.0, "ambience": 1.0},
	"assists": {"abs": true, "tcs": true, "esc": false, "countersteer": false},
	"controls": {"manual_gearbox": false, "steer_sensitivity": 1.0, "steer_linearity": 1.4, "deadzone": 0.08},
	"car": {"color": Color(0.62, 0.035, 0.03)},
	"game": {"hour": 17.0, "show_minimap": true},
}

## session state (not persisted)
var mode := "menu"                 # "menu" | "free" | "trial"
var trial_route := "ring"          # "ring" | "mountain_pass"

var cfg := ConfigFile.new()
var _dirty := false
var transient := false             # benchmark / screenshots: never write the file


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()


func load_settings() -> void:
	cfg = ConfigFile.new()
	if not _headless():
		cfg.load(PATH)


## tests / servers: settings are not read from or written to the user's file
func _headless() -> bool:
	return transient or DisplayServer.get_name() == "headless"


func get_value(section: String, key: String) -> Variant:
	var d: Variant = DEFAULTS.get(section, {}).get(key)
	return cfg.get_value(section, key, d)


## value with an explicit fallback (for settings that have no entry in DEFAULTS)
func get_value_or(section: String, key: String, fallback: Variant) -> Variant:
	return cfg.get_value(section, key, fallback)


func set_value(section: String, key: String, value: Variant) -> void:
	cfg.set_value(section, key, value)
	_dirty = true
	changed.emit(section, key)


func save() -> void:
	if not _headless():
		cfg.save(PATH)
	_dirty = false


func _process(_dt: float) -> void:
	if _dirty and Engine.get_frames_drawn() % 30 == 0:
		save()


func _exit_tree() -> void:
	if _dirty:
		save()


# ---- audio ---------------------------------------------------------------------------------------------------

## volume sliders (0..1) -> bus volumes. Buses are created by AudioBuses.
func apply_audio() -> void:
	AudioBuses.ensure()
	AudioBuses.set_volume("Master", float(get_value("audio", "master")))
	AudioBuses.set_volume("Engine", float(get_value("audio", "engine")))
	AudioBuses.set_volume("Effects", float(get_value("audio", "effects")))
	AudioBuses.set_volume("Ambience", float(get_value("audio", "ambience")))


## apply persisted driver settings to a vehicle + input filter
func apply_to_vehicle(v: Vehicle) -> void:
	v.assists.abs_on = bool(get_value("assists", "abs"))
	v.assists.tcs_on = bool(get_value("assists", "tcs"))
	v.assists.esc_on = bool(get_value("assists", "esc"))
	v.assists.countersteer_on = bool(get_value("assists", "countersteer"))
	v.set_auto_gearbox(not bool(get_value("controls", "manual_gearbox")))


func apply_to_controller(pc: PlayerController) -> void:
	pc.manual_gearbox = bool(get_value("controls", "manual_gearbox"))
	if pc.filter != null:
		pc.filter.deadzone = float(get_value("controls", "deadzone"))
		pc.filter.linearity = float(get_value("controls", "steer_linearity"))
	pc.steer_sensitivity = float(get_value("controls", "steer_sensitivity"))
