extends GutTest
## Einstieg des exportierten Programms: Argumente, Startbildschirm, Serveradresse, Server-Runner.

const BootScript := preload("res://game/boot.gd")
const StartMenuScript := preload("res://game/start_menu.gd")


func test_parse_args_server_connect_and_menu() -> void:
	assert_eq(BootScript.parse_args(PackedStringArray()), {"mode": "menu"})
	var server := BootScript.parse_args(PackedStringArray(["--server", "7788", "50", "0", "gen:60x40:3"]))
	assert_eq(String(server["mode"]), "server")
	assert_eq(server["server_args"], PackedStringArray(["7788", "50", "0", "gen:60x40:3"]))
	assert_eq(String(BootScript.parse_args(PackedStringArray(["--server"]))["mode"]), "server")
	var client := BootScript.parse_args(PackedStringArray(["--connect", "203.0.113.5:7790", "--name", "Anna", "--password", "geheim"]))
	assert_eq(String(client["mode"]), "connect")
	assert_eq(client["target"], {"host": "203.0.113.5", "port": 7790, "name": "Anna", "password": "geheim"})
	var no_name := BootScript.parse_args(PackedStringArray(["--connect", "localhost"]))
	assert_eq(int(no_name["target"]["port"]), StartMenuScript.DEFAULT_PORT, "Standardport")
	assert_true(String(no_name["target"]["name"]).begins_with("Spieler"), "Notname")


func test_parse_address() -> void:
	assert_eq(StartMenuScript.parse_address("127.0.0.1:7777"), {"host": "127.0.0.1", "port": 7777})
	assert_eq(StartMenuScript.parse_address(" spiel.example.org "), {"host": "spiel.example.org", "port": 7777})
	assert_eq(StartMenuScript.parse_address("host:abc"), {})
	assert_eq(StartMenuScript.parse_address(":7777"), {})
	assert_eq(StartMenuScript.parse_address(""), {})
	assert_eq(StartMenuScript.parse_address("h:70000"), {})


func test_start_menu_validates_and_emits() -> void:
	var menu: CanvasLayer = StartMenuScript.new()
	add_child_autofree(menu)
	var received := []
	menu.connect_requested.connect(func(host: String, port: int, player_name: String, password: String) -> void:
		received.append([host, port, player_name, password]))
	menu._name.text = "A"
	menu._on_connect()
	assert_true(received.is_empty(), "Name zu kurz")
	assert_true(menu._status.text.contains("Namen"))
	menu._name.text = "Anna"
	menu._address.text = "nix:kaputt"
	menu._on_connect()
	assert_true(received.is_empty(), "Adresse ungültig")
	menu._address.text = "203.0.113.5:7777"
	menu._password.text = "geheim"
	menu._on_connect()
	assert_eq(received, [["203.0.113.5", 7777, "Anna", "geheim"]])
	# Einstellungen gemerkt (ohne Passwort)
	var config := ConfigFile.new()
	assert_eq(config.load(StartMenuScript.SETTINGS_PATH), OK)
	assert_eq(String(config.get_value("player", "name", "")), "Anna")
	assert_eq(String(config.get_value("server", "address", "")), "203.0.113.5:7777")
	assert_false(config.has_section_key("player", "password"))
	DirAccess.remove_absolute(StartMenuScript.SETTINGS_PATH)


func test_server_runner_starts_and_stops_headless() -> void:
	var runner := ServerRunner.new()
	runner.save_path = ""  # frische Welt, kein Spielstand des Rechners
	runner.configure(PackedStringArray(["7791", "3", "0"]))
	assert_eq(runner.start(), OK)
	assert_true(runner.running)
	assert_eq(runner.port, 7791)
	var npcs := 0
	for c: SimCharacter in runner.world.characters.values():
		if c.control == SimCharacter.Controller.RULES:
			npcs += 1
	assert_eq(npcs, 3, "NPC-Füllung")
	assert_true(runner.update(0.05), "läuft weiter")
	runner.stop()
	assert_false(runner.running)
	assert_false(runner.update(0.05), "gestoppt")
