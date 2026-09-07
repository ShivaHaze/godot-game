extends SceneTree
## Macht Bildschirmfotos der wichtigsten Ansichten (Live, Marker, Menü, Advanced, Offline, Zeitsprung, danach, Versus).
## Aufruf: godot --path . -s tools/screenshot_run.gd -- <Ausgabeordner>   (Standard: user://shots)

var out_dir: String = "user://shots"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run()


func _run() -> void:
	await process_frame
	var main: Node2D = load("res://game/main.tscn").instantiate()
	main.save_path = ""  # echten Spielstand nicht anfassen
	root.add_child(main)
	await _frames(30)
	await _shot("1_live")
	Input.action_press("move_right")
	await _frames(45)
	Input.action_release("move_right")
	Input.action_press("place_marker")
	await _frames(2)
	Input.action_release("place_marker")
	Input.action_press("move_down")
	await _frames(30)
	Input.action_release("move_down")
	await _frames(5)
	await _shot("2_live_marker")
	var builder: SimCharacter = main.world.get_character(main.player_id)
	builder.inventory["wood"] = 20
	main.world.place_building(builder, "wood_wall", SimBuilding.half_cell_of(builder.pos + Vector2(1.5, -1.0)), 0)
	main.world.place_building(builder, "wood_door", SimBuilding.half_cell_of(builder.pos + Vector2(1.5, 0.0)), 0)
	main.world.place_building(builder, "wood_wall", SimBuilding.half_cell_of(builder.pos + Vector2(1.5, 1.0)), 0)
	main._toggle_build_mode(builder)
	await _frames(5)
	await _shot("2a_bauen")
	main._toggle_build_mode(builder)
	var sign: SimBuilding = main.world.place_building(builder, "sign", SimBuilding.half_cell_of(builder.pos + Vector2(-1.5, 0.0)), 0)
	main.world.set_sign_text(builder, sign, "Fremde zahlen Zoll: 2 Beeren")
	main.hud.add_chat_line("[nah] Ben: Hallo Nachbar")
	main.hud.add_chat_line("[global] Cleo: Kauft Beeren am Markt!")
	main.hud.chat_input.visible = true
	main.hud.chat_input.text = "/g Wer hat Stein?"
	await _frames(5)
	await _shot("2a2_schild_chat")
	main.hud.chat_input.visible = false
	main.craft_panel.open(main.data, main.world.get_character(main.player_id), main.world)
	await _frames(5)
	await _shot("2b_werkbank")
	main.craft_panel.close()
	var depot: SimBuilding = main.world.depots()[main.world.depots().size() - 1]
	builder.pos = depot.center() + Vector2(-1.2, 0.0)
	builder.prev_pos = builder.pos
	builder.inventory["berries"] = 7
	main.world.depot_deposit(builder, depot, "wood", 5)
	main._toggle_depot_panel(builder)
	await _frames(5)
	await _shot("2c_markt_depot")
	main.depot_panel.close()
	builder.pos = Vector2(20.5, 5.5)
	builder.prev_pos = builder.pos
	main._open_menu()
	await _frames(5)
	await _shot("3_menu_roles")
	main.menu._select_role("gatherer")
	main.menu._advanced.button_pressed = true
	await _frames(5)
	await _shot("4_menu_advanced")
	main.menu._on_confirm()
	await _frames(150)
	await _shot("5_offline")
	main._start_skip()
	await _frames(20)
	await _shot("6_skipping")
	while main.mode == main.Mode.SKIPPING:
		await process_frame
	await _frames(5)
	await _shot("7_after_skip")
	main._start_versus()
	await _frames(30)
	await _shot("8_versus")
	print("SHOTS OK: ", out_dir)
	quit()


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	image.save_png(out_dir.path_join(name + ".png"))


func _frames(n: int) -> void:
	for i in n:
		await process_frame
