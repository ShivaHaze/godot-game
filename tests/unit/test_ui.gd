extends GutTest
## Oberfläche: Ausloggen-Menü (Rollen, Regel-Editor) und Hauptszene (Modi) laufen headless durch.

const LogoutMenuScript := preload("res://game/logout_menu.gd")
const MainScene := preload("res://game/main.tscn")
const MainScript := preload("res://game/main.gd")

var data: SimData


func before_each() -> void:
	data = SimData.load_from_dir("res://data")


func _character() -> SimCharacter:
	var c := SimCharacter.new()
	c.markers.append({"id": "m1", "name": "Marker 1", "pos": Vector2(3, 3)})
	return c


func test_menu_opens_with_roles_and_editor() -> void:
	var menu: CanvasLayer = LogoutMenuScript.new()
	add_child_autofree(menu)
	watch_signals(menu)
	var c := _character()
	menu.open(data, c, data.default_rules, "")
	assert_true(menu.visible)
	assert_eq(menu.rules.size(), 3, "Default-Regelwerk geladen")
	assert_eq(menu._role_buttons.size(), 4, "vier Rollen")
	assert_signal_emitted(menu, "rules_changed")
	menu._select_role("gatherer")
	assert_eq(menu.role_id, "gatherer")
	assert_eq(menu.rules.size(), data.roles["gatherer"]["rules"].size())
	assert_eq(menu._rules_box.get_child_count(), menu.rules.size() + 1, "eine Zeile pro Regel plus Hinzufügen-Knopf")


func test_menu_editing_keeps_else_last_and_marks_custom() -> void:
	var menu: CanvasLayer = LogoutMenuScript.new()
	add_child_autofree(menu)
	menu.open(data, _character(), data.default_rules, "")
	menu._select_role("guard")
	var count: int = menu.rules.size()
	menu._add_rule()
	assert_eq(menu.rules.size(), count + 1)
	assert_eq(menu.rules[menu.rules.size() - 1]["if"]["condition"], "else", "Sonst bleibt letzte Zeile")
	assert_eq(menu.role_id, "", "Änderung macht daraus eigene Regeln")
	menu._move_rule(0, 1)
	assert_eq(menu.rules[1]["if"]["condition"], "health_below", "Regel 1 nach unten geschoben")
	menu._move_rule(menu.rules.size() - 2, 1)
	assert_eq(menu.rules[menu.rules.size() - 1]["if"]["condition"], "else", "nichts wandert unter Sonst")
	menu._remove_rule(0)
	assert_eq(menu.rules.size(), count)


func test_menu_confirm_emits_normalized_rules() -> void:
	var menu: CanvasLayer = LogoutMenuScript.new()
	add_child_autofree(menu)
	watch_signals(menu)
	menu.open(data, _character(), data.default_rules, "")
	menu._select_role("hide")
	menu._on_confirm()
	assert_signal_emitted(menu, "confirmed")
	var params: Array = get_signal_parameters(menu, "confirmed")
	assert_eq(params[1], "hide")
	assert_eq(params[2], "Verstecken")
	assert_eq(params[0].size(), 3)
	assert_true(data.is_valid(), "Prüfung hinterlässt keine Fehler in SimData")


func test_main_scene_logout_and_login_cycle() -> void:
	var main: Node2D = MainScene.instantiate()
	main.save_path = ""
	add_child_autofree(main)
	await wait_frames(2)
	assert_not_null(main.world)
	assert_eq(main.mode, main.Mode.LIVE)
	main._open_menu()
	assert_eq(main.mode, main.Mode.MENU)
	var ticks_before: int = main.world.tick_count
	await wait_frames(3)
	assert_eq(main.world.tick_count, ticks_before, "Sim pausiert im Menü")
	main.menu._select_role("guard")
	main.menu._on_confirm()
	assert_eq(main.mode, main.Mode.OFFLINE)
	var player: SimCharacter = main.world.get_character(main.player_id)
	assert_eq(player.control, SimCharacter.Controller.RULES)
	assert_eq(player.role_id, "guard")
	await wait_seconds(0.3)
	assert_gt(main.world.tick_count, ticks_before, "Sim läuft im Offline-Modus weiter")
	assert_gte(player.chronicle.size(), 2, "Chronik füllt sich")
	main._login()
	assert_eq(main.mode, main.Mode.LIVE)
	assert_eq(player.control, SimCharacter.Controller.PLAYER)


func test_main_scene_skip_and_versus() -> void:
	var main: Node2D = MainScene.instantiate()
	main.save_path = ""
	add_child_autofree(main)
	await wait_frames(2)
	main._open_menu()
	main.menu._select_role("guard")
	main.menu._on_confirm()
	assert_eq(main.mode, main.Mode.OFFLINE)
	var npc_id: int = main.player_id
	main.skip_hours = 0.02  # 72 Sim-Sekunden, damit der Test schnell bleibt
	var before: float = main.world.time
	main._start_skip()
	assert_eq(main.mode, main.Mode.SKIPPING)
	await wait_until(func() -> bool: return main.mode != main.Mode.SKIPPING, 20.0)
	assert_eq(main.mode, main.Mode.OFFLINE, "Zeitsprung fertig")
	assert_gte(main.world.time - before, 72.0 - 0.001, "Ziel erreicht")
	assert_lt(main.world.time - before, 73.0, "danach nur normale Ticks")
	main._start_versus()
	assert_eq(main.mode, main.Mode.VERSUS)
	assert_ne(main.player_id, npc_id, "frischer Charakter")
	var fresh: SimCharacter = main.world.get_character(main.player_id)
	assert_eq(fresh.owner_id, "p2")
	assert_eq(main.view.viewer_owner, "p2")
	var yesterday: SimCharacter = main.world.get_character(npc_id)
	assert_eq(yesterday.control, SimCharacter.Controller.RULES, "NPC von gestern bleibt in der Welt")
	assert_eq(yesterday.name, "Du (gestern)")
	main._toggle_yesterday_chronicle()
	assert_eq(main._chronicle_id, npc_id)
	await wait_frames(3)


## Baumodus: was ein neuer Spieler braucht, liegt auf 1–9 (Anker, Kacheln, Wand, Tür, Werkbank …), und die Meldung nach
## dem Claim nennt die richtige Taste (vorher "B, dann 3" – das war die Steinwand – obwohl man da schon im Baumodus ist).
func test_build_choices_put_starter_parts_first() -> void:
	var main: Node2D = MainScene.instantiate()
	main.save_path = ""
	add_child_autofree(main)
	await wait_frames(2)
	var choices: Array[String] = main._build_choices()
	assert_eq(choices.slice(0, 8), ["anchor", "claim_tile", "wood_wall", "wood_door", "workbench", "campfire", "trade_table", "sign"] as Array[String])
	assert_eq(main._build_choice_hint("claim_tile"), "B, dann 2")
	assert_eq(main._build_choice_hint("workbench"), "B, dann 5")
	assert_eq(main._build_choice_hint("turret"), "B, dann Tab bis „Turret“", "jenseits von 9: blättern")
	# Die Meldung "Claim gegründet" kommt beim Setzen des Ankers, also im Baumodus: dort würde B ihn beenden
	main._build_mode = true
	assert_eq(main._build_choice_hint("claim_tile"), "Taste 2")
	assert_eq(main._build_choice_hint("turret"), "Tab bis „Turret“")
	main._build_mode = false


func _live_main() -> Node2D:
	var main: Node2D = MainScene.instantiate()
	main.save_path = ""
	add_child_autofree(main)
	await wait_frames(2)
	await get_tree().process_frame  # weiter im Prozess-Frame: dort wertet main.gd "gerade gedrückt" aus (wait_frames endet im Physik-Frame)
	return main


func _key(keycode: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)


func _move_mouse(main: Node2D, pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	main.get_viewport().push_input(motion)


## Befund Schritt 55: die Tasten F, H, M, Q und C wurden vor der Chat-Prüfung ausgewertet – wer "Holz für Fasern"
## tippte, aß, legte einen Verband an, setzte Marker, wechselte die Waffe und öffnete die Werkbank.
func test_typing_in_chat_triggers_no_game_keys() -> void:
	var main := await _live_main()
	var player: SimCharacter = main.world.get_character(main.player_id)
	player.inventory["berries"] = 3
	var actions: Array[String] = ["eat", "place_marker", "switch_weapon", "craft_menu", "heal", "interact", "build_mode"]
	# Gegenprobe ohne Chat: F wird als Essen gemerkt
	Input.action_press("eat")
	main._process_live_input(player)
	Input.action_release("eat")
	assert_true(main._eat_pressed, "ohne Chat: F isst")
	main._eat_pressed = false
	main.hud.chat_input.visible = true
	var markers := player.markers.size()
	for action: String in actions:
		Input.action_press(action)
	main._process_live_input(player)
	for action: String in actions:
		Input.action_release(action)
	assert_false(main._eat_pressed, "F im Chat isst nicht")
	assert_eq(player.markers.size(), markers, "M im Chat setzt keinen Marker")
	assert_false(main.craft_panel.visible, "C im Chat öffnet keine Werkbank")
	assert_false(main._heal_active, "H im Chat legt keinen Verband an")
	assert_false(main._build_mode, "B im Chat startet keinen Baumodus")
	assert_true(main.hud.chat_input.visible, "der Chat bleibt offen")
	Input.action_press("logout_menu")
	main._process_live_input(player)
	Input.action_release("logout_menu")
	assert_false(main.hud.chat_input.visible, "Esc schließt den Chat")
	assert_eq(main.mode, main.Mode.LIVE, "und öffnet nicht das Ausloggen-Menü")


## Befund Schritt 55: Enter schickte die Zeile ab und öffnete sie im selben Frame wieder – danach tippte WASD in den Chat.
func test_enter_sends_chat_and_keeps_it_closed() -> void:
	var main := await _live_main()
	main.hud.chat_input.visible = true
	main.hud.chat_input.grab_focus()
	main.hud.chat_input.text = "hallo"
	await wait_frames(1)
	_key(KEY_ENTER, true)
	await wait_frames(5)
	_key(KEY_ENTER, false)
	await wait_frames(2)
	assert_eq(main.hud._chat_lines.size(), 1, "abgeschickt")
	assert_false(main.hud.chat_input.visible, "und zu")


## Befund Schritt 55: nur die Werkbank sperrte den Schuss – ein Klick auf "verkaufe" in der Karawanen-Tafel schoss.
func test_open_panels_block_shooting_and_interacting() -> void:
	var main := await _live_main()
	var player: SimCharacter = main.world.get_character(main.player_id)
	Input.action_press("shoot")
	Input.action_press("interact")
	var intent: SimIntent = main._build_player_intent(player)
	assert_true(intent.shoot, "ohne Tafel: Klick schießt")
	assert_true(intent.interact, "ohne Tafel: E sammelt")
	for panel: CanvasLayer in [main.craft_panel, main.trade_panel, main.depot_panel, main.caravan_panel, main.menu]:
		panel.visible = true
		intent = main._build_player_intent(player)
		assert_false(intent.shoot, "%s offen: kein Schuss" % panel.get_script().resource_path.get_file())
		assert_false(intent.interact, "%s offen: kein Sammeln" % panel.get_script().resource_path.get_file())
		panel.visible = false
	Input.action_release("shoot")
	Input.action_release("interact")


## Maus über einem Bedienelement (Knopf, Eingabezeile, Bildlaufleiste): der Klick gehört dem Element, nicht der Waffe.
## Reine Anzeigen sperren nicht – Review Schritt 55: die offene Chronik (rechtes Drittel des Bildschirms, bleibt nach dem
## Einloggen offen) sperrte jeden Schuss darüber. Geprüft an den Elementen selbst: headless ist das Fenster 64×64 Pixel
## groß, und darüber liegt die Oberfläche von GUT (Ebene 128) – die Maus trifft dort nie die Elemente des Spiels.
func test_only_controls_block_the_shot_not_displays() -> void:
	var main := await _live_main()
	var player: SimCharacter = main.world.get_character(main.player_id)
	var hud: CanvasLayer = main.hud
	hud.show_chronicle(true)
	hud.set_chronicle(PackedStringArray(["08:00 – hungrig, Regel 1: gegessen (Beeren 4→3)"]))
	var button := Button.new()
	var caption := Label.new()
	button.add_child(caption)
	add_child_autofree(button)
	assert_true(MainScript.gui_blocks_world_click(button), "Knopf")
	assert_true(MainScript.gui_blocks_world_click(caption), "Beschriftung auf einem Knopf")
	assert_true(MainScript.gui_blocks_world_click(hud.chat_input), "Chatzeile")
	assert_true(MainScript.gui_blocks_world_click(hud._chronicle_scroll.get_v_scroll_bar()), "Bildlaufleiste der Chronik")
	assert_false(MainScript.gui_blocks_world_click(hud._chronicle_panel), "Chroniktafel")
	assert_false(MainScript.gui_blocks_world_click(hud._chronicle_scroll), "Chronik-Bildlauf")
	assert_false(MainScript.gui_blocks_world_click(hud._chronicle_label), "Chroniktext")
	assert_false(MainScript.gui_blocks_world_click(null), "nichts unter der Maus")
	_move_mouse(main, Vector2(-500, -500))  # außerhalb: nichts darunter
	assert_null(main.get_viewport().gui_get_hovered_control())
	Input.action_press("shoot")
	assert_true(main._build_player_intent(player).shoot, "der Klick schießt, auch bei offener Chronik")
	Input.action_release("shoot")
	hud.show_chronicle(false)


## Review Schritt 55: E am eigenen Schild, dann Esc – die nächste Chatnachricht landete auf dem Schild statt im Chat.
func test_esc_ends_sign_editing() -> void:
	var main := await _live_main()
	var player: SimCharacter = main.world.get_character(main.player_id)
	player.pos = Vector2(20.5, 5.5)
	player.inventory["wood"] = 10
	var sign := SimConstruction.place_building(main.world, player, "sign", Vector2i(42, 11), 0)
	assert_not_null(sign)
	SimConstruction.set_sign_text(main.world, player, sign, "Alt")
	assert_true(main._toggle_sign_edit(player), "E am eigenen Schild")
	assert_true(main.hud.chat_input.visible, "Schildtext wird eingegeben")
	Input.action_press("logout_menu")
	main._process_live_input(player)
	Input.action_release("logout_menu")
	assert_false(main.hud.chat_input.visible, "Esc bricht ab")
	assert_eq(main.hud.chat_input.placeholder_text, main.hud.CHAT_PLACEHOLDER, "wieder die Chatzeile")
	main.hud.chat_input.visible = true
	main._on_chat_submitted("hallo")
	assert_eq(sign.label, "Alt", "das Schild bleibt, wie es war")
	assert_eq(main.hud._chat_lines.size(), 1, "die Zeile ging in den Chat")
