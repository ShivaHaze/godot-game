extends GutTest
## Oberfläche: Ausloggen-Menü (Rollen, Regel-Editor) und Hauptszene (Modi) laufen headless durch.

const LogoutMenuScript := preload("res://game/logout_menu.gd")
const MainScene := preload("res://game/main.tscn")

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
