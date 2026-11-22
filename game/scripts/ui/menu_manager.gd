class_name MenuManager
extends CanvasLayer
## Owns the main menu, pause menu and settings screens (scenes in res://scenes/ui/) and routes Esc.
## The game logic lives in Game (start_free / start_trial / pause / resume / to_menu).

var game: Game
var main: MainMenu
var pause_menu: PauseMenu
var settings: SettingsMenu
var _settings_return := "main"


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate() as MainMenu
	pause_menu = (load("res://scenes/ui/pause_menu.tscn") as PackedScene).instantiate() as PauseMenu
	settings = (load("res://scenes/ui/settings_menu.tscn") as PackedScene).instantiate() as SettingsMenu
	add_child(main)
	add_child(pause_menu)
	add_child(settings)
	main.free_ride.connect(func(): game.start_free())
	main.trial_selected.connect(func(r: String): game.start_trial(r))
	main.settings_requested.connect(func(): open_settings("main"))
	main.quit_requested.connect(func(): get_tree().quit())
	pause_menu.resume.connect(func(): game.resume())
	pause_menu.restart.connect(func(): game.restart_trial())
	pause_menu.settings_requested.connect(func(): open_settings("pause"))
	pause_menu.to_menu.connect(func(): game.to_menu())
	settings.closed.connect(_on_settings_closed)


func show_main() -> void:
	pause_menu.visible = false
	settings.visible = false
	main.open()


func show_pause(trial: bool) -> void:
	main.visible = false
	settings.visible = false
	pause_menu.open(trial)


func hide_all() -> void:
	main.visible = false
	pause_menu.visible = false
	settings.visible = false


func open_settings(from: String, tab: int = -1) -> void:
	_settings_return = from
	main.visible = false
	pause_menu.visible = false
	settings.open(tab)


func _on_settings_closed() -> void:
	if _settings_return == "main":
		main.open()
	else:
		pause_menu.open(game.mode == "trial")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel") or (event is InputEventKey and (event as InputEventKey).echo):
		return
	get_viewport().set_input_as_handled()
	if settings.visible:
		settings.close()
	elif main.visible:
		main.back()
	elif pause_menu.visible:
		game.resume()
	elif game.mode != "menu":
		game.pause()
