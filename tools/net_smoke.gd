extends SceneTree
## Rauchtest des Netzwerk-Clients mit Fenster: startet die Hauptszene im Client-Modus (Argumente --connect/--name
## werden von main.gd gelesen), wartet auf den Beitritt, läuft, loggt sich über das Menü aus (Server macht den
## Charakter zum NPC), schaut zu, loggt sich wieder ein. Bildschirmfotos nach <Ausgabeordner>.
## Aufruf (Server muss laufen): godot --path . -s tools/net_smoke.gd -- <Ausgabeordner> --connect 127.0.0.1:7777 --name Anna

var out_dir: String = "user://shots"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and not args[0].begins_with("--"):
		out_dir = args[0]
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run()


func _run() -> void:
	await process_frame
	var main: Node2D = load("res://game/main.tscn").instantiate()
	main.save_path = ""
	root.add_child(main)
	var waited := 0
	while (main.net == null or not main.net.joined) and waited < 600:
		await process_frame
		waited += 1
	if main.net == null or not main.net.joined:
		print("NET SMOKE FAILED: kein Beitritt")
		quit(1)
		return
	await _frames(30)
	Input.action_press("move_right")
	await _frames(90)
	Input.action_release("move_right")
	Input.action_press("place_marker")
	await _frames(2)
	Input.action_release("place_marker")
	await _frames(30)
	await _shot("n1_online")
	main._open_menu()
	main.menu._select_role("guard")
	await _frames(5)
	await _shot("n2_menu")
	main.menu._on_confirm()
	await _frames(120)
	await _shot("n3_offline_npc")
	main._login()
	await _frames(60)
	await _shot("n4_back")
	var me: SimCharacter = main.world.get_character(main.player_id)
	print("NET SMOKE OK: Charakter %s, Kontrolle %d, Chronik %d Zeilen" % [me.name, me.control, me.chronicle.size()])
	main.net.disconnect_from_server()
	quit()


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(out_dir.path_join(name + ".png"))


func _frames(n: int) -> void:
	for i in n:
		await process_frame
