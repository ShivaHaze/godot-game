extends Node2D
## Spielsteuerung: bindet die Simulation (sim/) an Darstellung und Eingabe.
## Liest den Sim-Zustand, zeichnet ihn und schreibt nur Absichten (SimIntent) hinein.
## Modi: LIVE (Spieler steuert) · MENU (Ausloggen-Menü, Sim pausiert) · OFFLINE (Charakter ist NPC, Zuschauen)
## · SKIPPING (Zeitsprung läuft beschleunigt) · VERSUS (frischer Charakter gegen den eigenen NPC von gestern).

enum Mode { LIVE, MENU, OFFLINE, SKIPPING, VERSUS }

## Netzwerk: `godot --path . -- --connect 127.0.0.1:7777 --name Anna` verbindet mit einem Server (server/server_main.gd).
## Dann ist `world` eine Spiegelwelt aus Snapshots, Eingaben gehen als Nachrichten an den Server.

const WorldViewScript := preload("res://game/world_view.gd")
const HudScript := preload("res://game/hud.gd")
const LogoutMenuScript := preload("res://game/logout_menu.gd")
const CraftPanelScript := preload("res://game/craft_panel.gd")

const MAX_TICKS_PER_FRAME: int = 5      # Schutz gegen Aufholspiralen bei Rucklern
const SKIP_BUDGET_MSEC: int = 14        # Echtzeit pro Frame für den Zeitsprung (Fortschritt bleibt sichtbar)
const SAVE_PATH: String = "user://save.dat"
const HINT_LIVE: String = "WASD · Maus zielen · Linksklick angreifen · E halten: sammeln/plündern · F essen · Q Waffe · C Werkbank · B Bauen · M Marker · Esc Ausloggen"
const HINT_DEAD: String = "Du bist tot. R = neuer Charakter am Spawn."
const HINT_OFFLINE: String = "Dein Charakter handelt jetzt nach seinen Regeln. Du schaust nur zu."
const HINT_SKIPPING: String = "Zeitsprung läuft …"
const HINT_VERSUS: String = "Finde deinen Charakter von gestern und besiege ihn – er handelt nach deinen Regeln. Leiche plündern mit E."

var data: SimData
var world: SimWorld
var player_id: int = -1
var mode: Mode = Mode.LIVE
var skip_hours: float = 8.0
var save_path: String = SAVE_PATH   # leer = nicht speichern/laden (Tests, Werkzeuge)

var view: Node2D
var hud: CanvasLayer
var menu: CanvasLayer
var craft_panel: CanvasLayer
var camera: Camera2D
var net: NetClient = null            # gesetzt im Netzwerk-Modus

var _accumulator: float = 0.0
var _eat_pressed: bool = false
var _skip_start: float = 0.0
var _skip_target: float = 0.0
var _chronicle_id: int = -1          # Wessen Chronik die Tafel zeigt (-1 = keine)
var _yesterday_id: int = -1          # Im Versus-Modus: der eigene NPC von gestern
var _new_game_armed_until: float = 0.0  # Doppelklick-Schutz für 'Neues Spiel'
var _net_saw_rules: bool = false        # Online: Server hat den eigenen Charakter als NPC gemeldet
var _build_mode: bool = false
var _build_part: String = ""
var _build_rot: int = 0
var _build_click: bool = false


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.07))
	data = SimData.load_from_dir("res://data")
	hud = HudScript.new()
	add_child(hud)
	if not data.is_valid():
		for e: String in data.errors:
			push_error(e)
		hud.set_hint("Datenfehler, siehe Konsole: " + data.errors[0])
		return
	skip_hours = data.balf("time_skip_hours")
	var net_target := _parse_connect_args()
	var saved: Dictionary = {}
	var saved_game: Dictionary = {}
	if not net_target.is_empty():
		net = NetClient.new()
		var err := net.connect_to(data, String(net_target["host"]), int(net_target["port"]), String(net_target["name"]))
		if err != OK:
			hud.set_hint("Verbindung zu %s fehlgeschlagen: %s" % [net_target["host"], error_string(err)])
			net = null
		else:
			world = net.mirror
			save_path = ""
	if net == null:
		saved = SimSave.load_from_file(data, save_path) if not save_path.is_empty() else {}
		saved_game = saved.get("game", {})
		if saved.is_empty():
			world = SimWorld.new(data, 12345)
			player_id = world.setup_new_game()
		else:
			world = saved["world"]
			player_id = int(saved_game.get("player_id", 1))

	view = WorldViewScript.new()
	view.world = world
	add_child(view)

	camera = Camera2D.new()
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(world.map.width * WorldViewScript.TILE)
	camera.limit_bottom = int(world.map.height * WorldViewScript.TILE)
	add_child(camera)
	camera.make_current()

	menu = LogoutMenuScript.new()
	menu.confirmed.connect(_on_logout_confirmed)
	menu.cancelled.connect(_close_menu)
	menu.rules_changed.connect(func(rules: Array) -> void: view.preview_rules = rules)
	menu.marker_renamed.connect(func(marker_id: String, new_name: String) -> void:
		if net != null:
			net.send({"t": "marker_rename", "id": marker_id, "name": new_name}, true)
		else:
			world.rename_marker(player_id, marker_id, new_name))
	menu.marker_removed.connect(_on_marker_removed)
	add_child(menu)

	craft_panel = CraftPanelScript.new()
	craft_panel.craft_requested.connect(_on_craft_requested)
	craft_panel.closed.connect(func() -> void: craft_panel.close())
	add_child(craft_panel)

	hud.world = world
	hud.player_id = player_id
	if net != null:
		_enter_live()
		hud.mode_text = "Online – verbinde …"
		hud.set_hint("Verbinde mit dem Server …")
	else:
		_restore_mode(saved_game)


## Liest `--connect host[:port]` und `--name X` aus den Programmargumenten (nach `--`).
func _parse_connect_args() -> Dictionary:
	var args := OS.get_cmdline_user_args()
	var result := {}
	for i in args.size():
		if args[i] == "--connect" and i + 1 < args.size():
			var parts := String(args[i + 1]).split(":")
			result["host"] = parts[0]
			result["port"] = int(parts[1]) if parts.size() > 1 else 7777
		if args[i] == "--name" and i + 1 < args.size():
			result["name"] = args[i + 1]
	if result.has("host") and not result.has("name"):
		result["name"] = "Spieler%d" % (Time.get_ticks_msec() % 1000)
	return result


func _process_net(delta: float) -> void:
	net.poll()
	for msg: Dictionary in net.messages:
		match String(msg.get("t", "")):
			"welcome":
				player_id = net.my_id
				hud.player_id = player_id
				view.viewer_owner = net.player_name
				camera.limit_right = int(world.map.width * WorldViewScript.TILE)
				camera.limit_bottom = int(world.map.height * WorldViewScript.TILE)
				hud.mode_text = "Online als %s" % net.player_name
				hud.set_hint(HINT_LIVE)
				hud.show_message("Verbunden. Dein Charakter wartet auf dem Server.", 3.0)
			"info":
				hud.show_message(String(msg.get("text", "")), 2.0)
				craft_panel.show_status(String(msg.get("text", "")))
	net.messages.clear()
	if not net.connected and player_id >= 0:
		hud.mode_text = "Verbindung verloren"
		hud.set_hint("Verbindung zum Server verloren. Dein Charakter handelt dort nach seinen Regeln weiter.")
	var player := world.get_character(player_id)
	match mode:
		Mode.LIVE:
			_process_live_input(player)
			_accumulator += delta
			while _accumulator >= world.tick_dt:
				_accumulator -= world.tick_dt
				if player != null and not player.dead and player.control == SimCharacter.Controller.PLAYER:
					net.send_intent(_build_player_intent(player))
		Mode.MENU:
			if Input.is_action_just_pressed("logout_menu"):
				_close_menu()
		Mode.OFFLINE:
			pass
	_chronicle_id = player_id if mode == Mode.OFFLINE else _chronicle_id
	view.alpha = net.render_alpha()
	if player != null:
		camera.position = WorldViewScript.to_pixels(player.render_pos(view.alpha))
	view.trail_character_id = _chronicle_id
	view.queue_redraw()
	var chronicle_owner := world.get_character(_chronicle_id)
	if chronicle_owner != null:
		hud.set_chronicle(SimChronicle.format_numbered(chronicle_owner))
	hud.refresh()
	if craft_panel.visible:
		craft_panel.refresh()
	if mode == Mode.OFFLINE and player != null:
		if player.control == SimCharacter.Controller.RULES:
			_net_saw_rules = true
		elif _net_saw_rules and player.control == SimCharacter.Controller.PLAYER:
			_net_saw_rules = false
			_enter_live(true)  # Server hat uns wieder eingeloggt


## Stellt nach dem Laden den passenden Modus wieder her.
func _restore_mode(saved_game: Dictionary) -> void:
	var saved_mode := int(saved_game.get("mode", Mode.LIVE))
	_yesterday_id = int(saved_game.get("yesterday_id", -1))
	view.viewer_owner = String(saved_game.get("viewer_owner", "p1"))
	match saved_mode:
		Mode.OFFLINE, Mode.SKIPPING:
			_enter_offline()
			hud.show_message("Spielstand geladen: dein Charakter ist noch offline.", 4.0)
		Mode.VERSUS:
			_enter_versus()
			hud.show_message("Spielstand geladen: du trittst gegen dich selbst an.", 4.0)
		_:
			_enter_live()
			if not saved_game.is_empty():
				hud.show_message("Spielstand geladen.", 3.0)


func _save() -> void:
	if world == null or save_path.is_empty():
		return
	var err := SimSave.save_to_file(world, save_path, {
		"mode": mode, "player_id": player_id, "yesterday_id": _yesterday_id, "viewer_owner": view.viewer_owner,
	})
	if err != OK:
		push_error("Spielstand konnte nicht gespeichert werden: %s" % error_string(err))


func _new_game() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now > _new_game_armed_until:
		_new_game_armed_until = now + 3.0
		hud.show_message("Wirklich neu anfangen? Nochmal klicken.", 3.0)
		return
	if not save_path.is_empty() and FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
	world = null
	get_tree().reload_current_scene()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if net != null:
			net.disconnect_from_server()
		elif mode != Mode.MENU:
			_save()


func _process(delta: float) -> void:
	if world == null:
		return
	if net != null:
		_process_net(delta)
		return
	var player := world.get_character(player_id)
	match mode:
		Mode.LIVE, Mode.VERSUS:
			_process_live_input(player)
		Mode.MENU:
			if Input.is_action_just_pressed("logout_menu"):
				_close_menu()
			_refresh_view(player)  # Sim pausiert, Leinen-Vorschau wird trotzdem gezeichnet
			return
		Mode.SKIPPING:
			_process_skip()
			_refresh_view(player)
			return
		Mode.OFFLINE:
			pass

	_accumulator += delta
	var ticks := 0
	while _accumulator >= world.tick_dt and ticks < MAX_TICKS_PER_FRAME:
		if (mode == Mode.LIVE or mode == Mode.VERSUS) and player != null and not player.dead:
			world.set_intent(player_id, _build_player_intent(player))
		world.tick()
		_handle_events()
		_accumulator -= world.tick_dt
		ticks += 1
	if ticks == MAX_TICKS_PER_FRAME:
		_accumulator = 0.0

	_refresh_view(player)


func _refresh_view(player: SimCharacter) -> void:
	view.alpha = clampf(_accumulator / world.tick_dt, 0.0, 1.0)
	if player != null:
		camera.position = WorldViewScript.to_pixels(player.render_pos(view.alpha))
	view.trail_character_id = _chronicle_id
	view.queue_redraw()
	var chronicle_owner := world.get_character(_chronicle_id)
	if chronicle_owner != null:
		hud.set_chronicle(SimChronicle.format_numbered(chronicle_owner))
	hud.refresh()
	if craft_panel.visible:
		craft_panel.refresh()


func _process_live_input(player: SimCharacter) -> void:
	if player == null:
		return
	if Input.is_action_just_pressed("eat"):
		_eat_pressed = true
	if Input.is_action_just_pressed("place_marker") and not player.dead:
		if net != null:
			net.send({"t": "marker"}, true)
			hud.show_message("Marker gesetzt")
		else:
			var marker := world.add_marker(player_id)
			hud.show_message("%s gesetzt" % marker["name"])
	if Input.is_action_just_pressed("respawn") and player.dead:
		if net != null:
			net.send({"t": "respawn"}, true)
		else:
			_respawn_player()
	if Input.is_action_just_pressed("switch_weapon") and not player.dead:
		_switch_weapon(player)
	if Input.is_action_just_pressed("craft_menu") and not player.dead:
		if craft_panel.visible:
			craft_panel.close()
		else:
			craft_panel.open(data, player)
	if Input.is_action_just_pressed("build_mode") and not player.dead:
		_toggle_build_mode(player)
	if _build_mode:
		_update_build_mode(player)
	if Input.is_action_just_pressed("logout_menu") and not player.dead and mode == Mode.LIVE:
		craft_panel.close()
		_open_menu()


func _build_player_intent(player: SimCharacter) -> SimIntent:
	var intent := SimIntent.new()
	intent.move = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	intent.aim = view.mouse_world_pos() - player.pos
	intent.shoot = Input.is_action_pressed("shoot") and not craft_panel.visible and not _build_mode
	intent.interact = Input.is_action_pressed("interact")
	intent.eat = _eat_pressed
	_eat_pressed = false
	return intent


# --- Bauen ----------------------------------------------------------------

func _toggle_build_mode(player: SimCharacter) -> void:
	_build_mode = not _build_mode
	if _build_mode:
		if _build_part.is_empty() and not data.building_order.is_empty():
			_build_part = data.building_order[0]
		hud.set_hint(_build_hint())
	else:
		view.ghost = {}
		hud.set_hint(HINT_VERSUS if mode == Mode.VERSUS else HINT_LIVE)


func _build_hint() -> String:
	var parts: PackedStringArray = []
	for i in data.building_order.size():
		var def: Dictionary = data.buildings[data.building_order[i]]
		var cost: PackedStringArray = []
		for rid: String in def["cost"]:
			cost.append("%d %s" % [int(def["cost"][rid]), data.resources[rid]["name"]])
		parts.append("%d %s (%s)%s" % [i + 1, def["name"], ", ".join(cost), " ◄" if data.building_order[i] == _build_part else ""])
	return "Bauen: " + " · ".join(parts) + " · T drehen · Linksklick setzen · X eigenes Teil abreißen · B beenden"


func _unhandled_input(event: InputEvent) -> void:
	if not _build_mode or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var index := int(event.keycode) - int(KEY_1)
	if index >= 0 and index < data.building_order.size():
		_build_part = data.building_order[index]
		hud.set_hint(_build_hint())


func _update_build_mode(player: SimCharacter) -> void:
	if Input.is_action_just_pressed("rotate_build"):
		_build_rot = (_build_rot + 1) % 2
	var def: Dictionary = data.buildings.get(_build_part, {})
	if def.is_empty():
		return
	var origin := SimBuilding.half_cell_of(view.mouse_world_pos())
	var reason := world.can_place(player, _build_part, origin, _build_rot)
	view.ghost = {"cells": SimBuilding.cells_for(def["size"], origin, _build_rot), "valid": reason.is_empty()}
	if Input.is_action_just_pressed("shoot"):
		if net != null:
			net.send({"t": "build", "part": _build_part, "x": origin.x, "y": origin.y, "rot": _build_rot}, true)
		elif reason.is_empty():
			world.place_building(player, _build_part, origin, _build_rot)
			hud.show_message("%s gesetzt" % def["name"], 1.0)
		else:
			hud.show_message("Bauen geht nicht: %s" % reason, 1.5)
	if Input.is_action_just_pressed("demolish"):
		var b := world.map.building_at(view.mouse_world_pos())
		if b == null:
			hud.show_message("Kein Bauteil unter der Maus.", 1.0)
		elif net != null:
			net.send({"t": "demolish", "id": b.id}, true)
		elif world.can_demolish(player, b):
			world.remove_building(b.id, player)
			hud.show_message("Abgerissen, %d %% der Kosten zurück." % int(data.balf("building.refund_fraction") * 100.0), 1.5)
		else:
			hud.show_message("Nicht dein Bauteil oder zu weit weg.", 1.5)


## Q: nächste besessene Waffe.
func _switch_weapon(player: SimCharacter) -> void:
	var weapons := world.owned_weapons(player)
	if weapons.size() < 2:
		hud.show_message("Nur eine Waffe. Keule gibt es an der Werkbank (C).", 2.0)
		return
	var index := weapons.find(player.active_weapon)
	var next_id: String = weapons[(index + 1) % weapons.size()]
	if net != null:
		net.send({"t": "weapon", "item": next_id}, true)
	else:
		world.set_active_weapon(player, next_id)
	hud.show_message("Waffe: %s" % data.items[next_id]["name"], 1.5)


func _on_craft_requested(item_id: String) -> void:
	var player := world.get_character(player_id)
	if player == null:
		return
	if net != null:
		net.send({"t": "craft", "item": item_id}, true)
		return
	var reason := world.craft(player, item_id)
	if reason.is_empty():
		craft_panel.show_status("%s gebaut." % data.items[item_id]["name"])
		hud.show_message("%s gebaut." % data.items[item_id]["name"], 2.0)
	else:
		craft_panel.show_status("Geht nicht: %s" % reason)
	craft_panel.refresh()


func _on_marker_removed(marker_id: String) -> void:
	if net != null:
		net.send({"t": "marker_remove", "id": marker_id}, true)
	else:
		world.remove_marker(player_id, marker_id)
	menu.on_marker_removed(marker_id)


# --- Modi -----------------------------------------------------------------

func _enter_live(keep_chronicle: bool = false) -> void:
	mode = Mode.LIVE
	world.observer_ids = []
	hud.mode_text = "Live"
	hud.set_hint(HINT_LIVE)
	hud.clear_buttons()
	view.preview_rules = []
	if keep_chronicle:
		hud.add_button("Chronik schließen", _hide_chronicle)
	else:
		_chronicle_id = -1
		hud.show_chronicle(false)
	if net == null:
		hud.add_button("Neues Spiel", _new_game)


func _hide_chronicle() -> void:
	_chronicle_id = -1
	hud.show_chronicle(false)
	if mode == Mode.LIVE:
		hud.clear_buttons()
		if net == null:
			hud.add_button("Neues Spiel", _new_game)


func _open_menu() -> void:
	var player := world.get_character(player_id)
	mode = Mode.MENU
	craft_panel.close()
	menu.open(data, player, player.rules, player.role_id, world.unlocks_of(player.owner_id))


func _close_menu() -> void:
	menu.close()
	_enter_live()


func _on_logout_confirmed(rules: Array, role_id: String, role_name: String) -> void:
	menu.close()
	var player := world.get_character(player_id)
	player.role_id = role_id
	if net != null:
		net.send({"t": "logout", "rules": rules, "role": role_id}, true)
		_enter_offline()
		return
	world.logout(player_id, rules, role_name)
	_enter_offline()
	_save()


func _enter_offline() -> void:
	mode = Mode.OFFLINE
	if net == null:
		world.observer_ids = [player_id]  # Zuschauer-Kamera: der eigene NPC und seine Umgebung laufen fein
	view.preview_rules = []
	hud.mode_text = "Offline – NPC handelt nach Regeln"
	hud.set_hint(HINT_OFFLINE)
	hud.clear_buttons()
	_chronicle_id = player_id
	hud.show_chronicle(true, "Chronik (live)")
	if net == null:
		hud.add_button("%d Stunden überspringen" % int(skip_hours), _start_skip)
	hud.add_button("Wieder einloggen", _login)


func _start_skip() -> void:
	mode = Mode.SKIPPING
	_skip_start = world.time
	_skip_target = world.time + skip_hours * 3600.0
	hud.mode_text = "Zeitsprung"
	hud.set_hint(HINT_SKIPPING)
	hud.clear_buttons()


func _process_skip() -> void:
	var done := world.advance_until(_skip_target, SKIP_BUDGET_MSEC)
	var elapsed := world.time - _skip_start
	@warning_ignore("integer_division")
	hud.show_message("Simuliere … %d:%02d h von %d h" % [int(elapsed) / 3600, (int(elapsed) % 3600) / 60, int(skip_hours)], 1.0)
	if done:
		_finish_skip()


func _finish_skip() -> void:
	mode = Mode.OFFLINE
	var player := world.get_character(player_id)
	hud.mode_text = "Offline – %d Stunden später" % int(skip_hours)
	hud.show_chronicle(true, "Chronik der letzten %d Stunden" % int(skip_hours))
	if player.dead:
		hud.set_hint("Dein Charakter ist gestorben. Lies die Chronik – und ändere die Regeln beim nächsten Mal.")
		hud.show_message("Dein Charakter hat es nicht geschafft.", 4.0)
	else:
		hud.set_hint("Du findest deinen Charakter dort, wo er jetzt steht. Lies die Chronik.")
		hud.show_message("%d Stunden sind vergangen." % int(skip_hours), 3.0)
	hud.clear_buttons()
	hud.add_button("Charakter übernehmen", _login)
	hud.add_button("Gegen mich selbst antreten", _start_versus)
	hud.add_button("Weitere %d Stunden" % int(skip_hours), _start_skip)
	_save()


func _login() -> void:
	var player := world.get_character(player_id)
	if player == null:
		return
	if net != null:
		net.send({"t": "login"}, true)
		hud.show_message("Einloggen angefragt …", 2.0)
		return
	world.login(player_id)
	_enter_live(true)
	hud.show_message("Du übernimmst deinen Charakter wieder.", 3.0)
	if player.dead:
		hud.set_hint(HINT_DEAD)
	_save()


## Gegen sich selbst: der NPC von gestern bleibt in der Welt, ein frischer Charakter startet am Spawn.
func _start_versus() -> void:
	var yesterday := world.get_character(player_id)
	yesterday.name = "Du (gestern)"
	_yesterday_id = yesterday.id
	var fresh := world.spawn_player(SimMap.cell_center(data.player_spawns[0]), "p2", "Du (heute)")
	player_id = fresh.id
	hud.player_id = player_id
	view.viewer_owner = fresh.owner_id
	_enter_versus()
	hud.show_message("Dein Charakter von gestern ist irgendwo da draußen.", 4.0)
	_save()


func _enter_versus() -> void:
	mode = Mode.VERSUS
	world.observer_ids = []
	hud.mode_text = "Gegen dich selbst"
	hud.set_hint(HINT_VERSUS)
	_hide_chronicle()
	hud.clear_buttons()
	hud.add_button("Chronik von gestern", _toggle_yesterday_chronicle)
	hud.add_button("Neues Spiel", _new_game)


func _toggle_yesterday_chronicle() -> void:
	if _chronicle_id == _yesterday_id:
		_chronicle_id = -1
		hud.show_chronicle(false)
	else:
		_chronicle_id = _yesterday_id
		hud.show_chronicle(true, "Chronik von gestern")


## Neuer, frischer Charakter am Spawn; die Leiche bleibt liegen.
func _respawn_player() -> void:
	var old := world.get_character(player_id)
	var spawn := SimMap.cell_center(data.player_spawns[0])
	var fresh := world.spawn_player(spawn, old.owner_id if old != null else "p1", old.name if old != null else "Du")
	player_id = fresh.id
	hud.player_id = player_id
	hud.set_hint(HINT_VERSUS if mode == Mode.VERSUS else HINT_LIVE)
	hud.show_message("Neuer Charakter. Dein altes Zeug liegt bei der Leiche.")


func _handle_events() -> void:
	for event: Dictionary in world.events:
		var id := int(event.get("id", -1))
		if mode == Mode.VERSUS and id == _yesterday_id and String(event.get("type", "")) == "death":
			hud.show_message("Du hast deinen Charakter von gestern besiegt. Plündere ihn mit E.", 5.0)
			continue
		if id != player_id:
			continue
		match String(event.get("type", "")):
			"gather":
				if mode != Mode.OFFLINE:
					hud.show_message("%s +1" % data.resources[event["resource"]]["name"], 1.0)
			"eat":
				if mode != Mode.OFFLINE:
					hud.show_message("Gegessen: %s (%d→%d)" % [data.resources[event["resource"]]["name"], event["before"], event["after"]], 1.5)
			"hit":
				hud.show_message("Getroffen %s: −%d" % [SimCombat.side_name(event["side"]), int(ceilf(event["damage"]))], 1.0)
			"loot":
				var parts: PackedStringArray = []
				for rid: String in event["items"]:
					parts.append("%s %d" % [data.resources[rid]["name"], event["items"][rid]])
				hud.show_message("Geplündert: " + ", ".join(parts), 2.0)
			"unlock":
				hud.show_message("Neuer Regel-Baustein freigeschaltet: %s" % event["label"], 5.0)
			"building_hit":
				pass
			"death":
				var killer := world.get_character(int(event["attacker"]))
				var killer_name: String = killer.name if killer != null else "Unbekannt"
				if mode == Mode.OFFLINE:
					hud.show_message("Dein Charakter ist gestorben (%s)." % killer_name, 4.0)
				else:
					hud.set_hint(HINT_DEAD)
					hud.show_message("Du bist gestorben (%s)." % killer_name, 4.0)
