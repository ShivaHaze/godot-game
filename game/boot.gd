extends Node
## Einstieg des Programms (Hauptszene). Entscheidet nach Argumenten und Export-Merkmalen, was läuft:
##   --server [Port] [NPC-Füllung] [Laufzeit s] [Karte]   Server ohne Fenster (dazu --headless), auch bei Export
##                                                        als 'dedicated_server' automatisch
##   --connect host[:port] --name X [--password P]        direkt als Client verbinden (Werkzeuge, Bots)
##   sonst                                                Startbildschirm: Name, Passwort, Server, Einzelspieler
## Argumente stehen hinter `--`: Prototyp-Server.exe --headless -- --server 7777 200

const MainScene := preload("res://game/main.tscn")
const StartMenuScript := preload("res://game/start_menu.gd")
const BootScenePath: String = "res://game/boot.tscn"

var runner: ServerRunner = null
var menu: CanvasLayer = null
var main: Node = null
var _last_usec: int = 0


func _ready() -> void:
	var options := parse_args(OS.get_cmdline_user_args())
	if String(options["mode"]) == "server" or OS.has_feature("dedicated_server"):
		_start_server(options.get("server_args", PackedStringArray()))
	elif String(options["mode"]) == "connect":
		_start_game(options["target"])
	else:
		_show_menu()


## Argumente hinter `--` auswerten. Rückgabe: {"mode": "server"|"connect"|"menu", ...}.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var result := {"mode": "menu"}
	for i in args.size():
		match args[i]:
			"--server":
				result["mode"] = "server"
				var server_args := PackedStringArray()
				for j in range(i + 1, args.size()):
					if args[j].begins_with("--"):
						break
					server_args.append(args[j])
				result["server_args"] = server_args
				return result
	var target := {}
	for i in args.size():
		if i + 1 >= args.size():
			break
		match args[i]:
			"--connect":
				var address := StartMenuScript.parse_address(args[i + 1])
				if not address.is_empty():
					target["host"] = address["host"]
					target["port"] = address["port"]
			"--name":
				target["name"] = args[i + 1]
			"--password":
				target["password"] = args[i + 1]
	if target.has("host"):
		if not target.has("name"):
			target["name"] = "Spieler%d" % (Time.get_ticks_msec() % 1000)
		result["mode"] = "connect"
		result["target"] = target
	return result


func _show_menu() -> void:
	menu = StartMenuScript.new()
	menu.title_text = String(ProjectSettings.get_setting("application/config/name", "Prototyp"))
	menu.version_text = "Version %s" % String(ProjectSettings.get_setting("application/config/version", ""))
	menu.connect_requested.connect(func(host: String, port: int, player_name: String, password: String) -> void:
		_start_game({"host": host, "port": port, "name": player_name, "password": password}))
	menu.singleplayer_requested.connect(func() -> void: _start_game({}))
	menu.quit_requested.connect(func() -> void: get_tree().quit())
	add_child(menu)


## Hauptszene starten; leeres Ziel = Einzelspieler mit lokalem Spielstand.
func _start_game(target: Dictionary) -> void:
	if menu != null:
		menu.queue_free()
		menu = null
	main = MainScene.instantiate()
	main.connect_target = target
	add_child(main)


func _start_server(args: PackedStringArray) -> void:
	runner = ServerRunner.new()
	runner.configure(args)
	if runner.start() != OK:
		get_tree().quit(1)
		return
	Engine.max_fps = 60
	_last_usec = Time.get_ticks_usec()


func _process(_delta: float) -> void:
	if runner == null:
		return
	var now := Time.get_ticks_usec()
	var delta := (now - _last_usec) / 1_000_000.0
	_last_usec = now
	if not runner.update(delta):
		get_tree().quit()


## Fenster schließen oder Strg+C: Welt speichern, Port freigeben.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and runner != null:
		runner.stop()


func _exit_tree() -> void:
	if runner != null:
		runner.stop()
