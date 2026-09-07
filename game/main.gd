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
const TradePanelScript := preload("res://game/trade_panel.gd")
const DepotPanelScript := preload("res://game/depot_panel.gd")

const MAX_TICKS_PER_FRAME: int = 5      # Schutz gegen Aufholspiralen bei Rucklern
const SKIP_BUDGET_MSEC: int = 14        # Echtzeit pro Frame für den Zeitsprung (Fortschritt bleibt sichtbar)
const SAVE_PATH: String = "user://save.dat"
const HINT_LIVE: String = "WASD · Maus · Linksklick angreifen · E sammeln/plündern/handeln · F essen · H Verband · Q Waffe · C Werkbank · B Bauen · M Marker · Esc Ausloggen"
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
var trade_panel: CanvasLayer
var camera: Camera2D
var net: NetClient = null            # gesetzt im Netzwerk-Modus

var _accumulator: float = 0.0
var _eat_pressed: bool = false
var _heal_active: bool = false          # H: Verband anlegen (läuft bis fertig oder Angriff)
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
var _sign_edit: SimBuilding = null      # Schild, das gerade beschriftet wird
var depot_panel: CanvasLayer


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
	craft_panel.repair_requested.connect(_on_repair_requested)
	craft_panel.closed.connect(func() -> void: craft_panel.close())
	add_child(craft_panel)

	trade_panel = TradePanelScript.new()
	trade_panel.deposit_requested.connect(func(id: int, rid: String, amount: int) -> void: _trade_action("table_deposit", {"id": id, "res": rid, "amount": amount}))
	trade_panel.withdraw_requested.connect(func(id: int, rid: String, amount: int) -> void: _trade_action("table_withdraw", {"id": id, "res": rid, "amount": amount}))
	trade_panel.offers_requested.connect(func(id: int, offers: Array) -> void: _trade_action("table_offers", {"id": id, "offers": offers}))
	trade_panel.buy_requested.connect(func(id: int, index: int) -> void: _trade_action("table_buy", {"id": id, "index": index}))
	trade_panel.closed.connect(func() -> void: trade_panel.close())
	add_child(trade_panel)
	depot_panel = DepotPanelScript.new()
	depot_panel.deposit_requested.connect(func(id: int, rid: String, amount: int) -> void: _depot_action("depot_deposit", {"id": id, "res": rid, "amount": amount}))
	depot_panel.withdraw_requested.connect(func(id: int, rid: String, amount: int) -> void: _depot_action("depot_withdraw", {"id": id, "res": rid, "amount": amount}))
	depot_panel.closed.connect(func() -> void: depot_panel.close())
	add_child(depot_panel)
	hud.chat_input.text_submitted.connect(_on_chat_submitted)

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
			"chat":
				hud.add_chat_line("[%s] %s: %s" % ["global" if msg.get("scope", "") == "global" else "nah", msg.get("from", "?"), msg.get("text", "")])
			"info":
				hud.show_message(String(msg.get("text", "")), 2.0)
				craft_panel.show_status(String(msg.get("text", "")))
				if trade_panel.visible:
					trade_panel.show_status(String(msg.get("text", "")))
				if depot_panel.visible:
					depot_panel.show_status(String(msg.get("text", "")))
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
	if depot_panel.visible:
		var depot: SimBuilding = world.map.buildings.get(depot_panel.building.id) if depot_panel.building != null else null
		if depot == null or depot.center().distance_to(player.pos) > data.balf("character.interact_range") + 0.5:
			depot_panel.close()
		else:
			depot_panel.building = depot
			depot_panel.rebuild()
	if trade_panel.visible:
		var table: SimBuilding = world.map.buildings.get(trade_panel.building.id) if trade_panel.building != null else null
		if table == null or table.center().distance_to(player.pos) > data.balf("character.interact_range") + 0.5:
			trade_panel.close()
		elif net != null and _trade_signature(table) != _trade_last_signature:
			_trade_last_signature = _trade_signature(table)
			trade_panel.building = table
			trade_panel.rebuild()
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
	if Input.is_action_just_pressed("heal"):
		if world.heal_item_of(player).is_empty():
			hud.show_message("Kein Verband. Werkbank (C): 3 Fasern.", 2.0)
		elif player.hp >= player.max_hp:
			hud.show_message("Du bist gesund.", 1.5)
		else:
			_heal_active = not _heal_active
			hud.show_message("Verband anlegen … (nicht angreifen)" if _heal_active else "Verband abgebrochen.", 1.5)
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
			craft_panel.open(data, player, world)
	if hud.chat_input.visible:
		if Input.is_action_just_pressed("logout_menu"):
			_close_chat()
		return  # Tippen im Chat: keine Spielsteuerung
	if Input.is_action_just_pressed("chat") and not player.dead:
		hud.chat_input.visible = true
		hud.chat_input.grab_focus()
		return
	if Input.is_action_just_pressed("interact") and not player.dead and not _build_mode:
		if not _toggle_sign_edit(player) and not _toggle_depot_panel(player):
			_toggle_trade_panel(player)
	if Input.is_action_just_pressed("build_mode") and not player.dead:
		_toggle_build_mode(player)
	if _build_mode:
		_update_build_mode(player)
	if Input.is_action_just_pressed("logout_menu") and not player.dead and mode == Mode.LIVE:
		craft_panel.close()
		_open_menu()


func _build_player_intent(player: SimCharacter) -> SimIntent:
	var intent := SimIntent.new()
	if hud.chat_input.visible:
		return intent  # keine Bewegung, während getippt wird
	intent.move = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	intent.aim = view.mouse_world_pos() - player.pos
	intent.shoot = Input.is_action_pressed("shoot") and not craft_panel.visible and not _build_mode
	intent.interact = Input.is_action_pressed("interact") and not trade_panel.visible and not depot_panel.visible
	intent.eat = _eat_pressed
	_eat_pressed = false
	if intent.shoot or player.hp >= player.max_hp:
		_heal_active = false
	intent.heal = _heal_active
	return intent


# --- Chat und Schilder ----------------------------------------------------

func _close_chat() -> void:
	hud.chat_input.text = ""
	hud.chat_input.visible = false
	hud.chat_input.release_focus()


func _on_chat_submitted(text: String) -> void:
	var line := text.strip_edges()
	if _sign_edit != null:
		_apply_sign_text(line)
		_sign_edit = null
		hud.chat_input.placeholder_text = "Nah-Chat … (/g für global, Esc bricht ab)"
		_close_chat()
		return
	if line.is_empty():
		_close_chat()
		return
	var scope := "near"
	if line.begins_with("/g "):
		scope = "global"
		line = line.substr(3).strip_edges()
	if net != null:
		net.send({"t": "chat", "text": line, "scope": scope}, true)
	else:
		hud.add_chat_line("[%s] Du: %s (niemand hört zu – Einzelspieler)" % ["global" if scope == "global" else "nah", line])
	_close_chat()


## E neben einem eigenen Schild: Text eingeben. true, wenn ein Schild in Reichweite ist.
func _toggle_sign_edit(player: SimCharacter) -> bool:
	var sign := world.sign_near(player)
	if sign == null:
		return false
	if sign.owner_id != player.owner_id:
		hud.show_message("Schild von %s: „%s“" % [sign.owner_id, sign.label], 4.0)
		return true
	_sign_edit = sign
	hud.chat_input.placeholder_text = "Schildtext (max %d Zeichen), Enter speichert" % data.bali("building.sign_max_length")
	hud.chat_input.text = sign.label
	hud.chat_input.visible = true
	hud.chat_input.grab_focus()
	return true


func _apply_sign_text(text: String) -> void:
	if _sign_edit == null:
		return
	if net != null:
		net.send({"t": "sign_text", "id": _sign_edit.id, "text": text}, true)
		return
	var player := world.get_character(player_id)
	var reason := world.set_sign_text(player, _sign_edit, text)
	hud.show_message("Schild beschriftet." if reason.is_empty() else "Schild: %s" % reason, 2.0)


# --- Handelstisch ---------------------------------------------------------

var _trade_last_signature: int = 0


func _trade_signature(b: SimBuilding) -> int:
	return [b.contents, b.offers, world.get_character(player_id).inventory].hash()


## E (tippen) neben einem Handelstisch öffnet die Tafel; sonst bleibt E das Sammeln (halten).
## E neben einem Markt-Depot: eigene Waren einlagern/holen. true, wenn ein Depot in Reichweite ist.
func _toggle_depot_panel(player: SimCharacter) -> bool:
	if depot_panel.visible:
		depot_panel.close()
		return true
	var depot := world.depot_near(player)
	if depot == null:
		return false
	craft_panel.close()
	trade_panel.close()
	depot_panel.open(data, world, player, depot)
	return true


func _depot_action(kind: String, payload: Dictionary) -> void:
	var player := world.get_character(player_id)
	if player == null:
		return
	if net != null:
		var msg := payload.duplicate()
		msg["t"] = kind
		net.send(msg, true)
		return
	var b: SimBuilding = world.map.buildings.get(int(payload["id"]))
	var reason := world.depot_deposit(player, b, String(payload["res"]), int(payload["amount"])) if kind == "depot_deposit" else world.depot_withdraw(player, b, String(payload["res"]), int(payload["amount"]))
	depot_panel.show_status("" if reason.is_empty() else "Geht nicht: %s" % reason)
	depot_panel.rebuild()


func _toggle_trade_panel(player: SimCharacter) -> void:
	if trade_panel.visible:
		trade_panel.close()
		return
	var table := world.trade_table_near(player)
	if table == null:
		return
	craft_panel.close()
	_trade_last_signature = _trade_signature(table)
	trade_panel.open(data, world, player, table)


func _trade_action(kind: String, payload: Dictionary) -> void:
	var player := world.get_character(player_id)
	if player == null:
		return
	if net != null:
		var msg := payload.duplicate()
		msg["t"] = kind
		net.send(msg, true)
		return
	var b: SimBuilding = world.map.buildings.get(int(payload["id"]))
	var reason := ""
	match kind:
		"table_deposit":
			reason = world.table_deposit(player, b, String(payload["res"]), int(payload["amount"]))
		"table_withdraw":
			reason = world.table_withdraw(player, b, String(payload["res"]), int(payload["amount"]))
		"table_offers":
			reason = world.table_set_offers(player, b, payload["offers"])
			if reason.is_empty():
				trade_panel.show_status("Angebote gespeichert.")
		"table_buy":
			reason = world.table_buy(player, b, int(payload["index"]))
			if reason.is_empty():
				trade_panel.show_status("Gekauft.")
	if not reason.is_empty():
		trade_panel.show_status("Geht nicht: %s" % reason)
	trade_panel.rebuild()


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
	parts.append("%d Kachel beanspruchen (%d Holz)%s" % [data.building_order.size() + 1, data.bali("claim.tile_cost_wood"), " ◄" if _build_part == CLAIM_TOOL else ""])
	return "Bauen: " + " · ".join(parts) + " · T drehen · Linksklick setzen · X abreißen/freigeben · B beenden"


func _unhandled_input(event: InputEvent) -> void:
	if not _build_mode or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var index := int(event.keycode) - int(KEY_1)
	if index >= 0 and index < data.building_order.size():
		_build_part = data.building_order[index]
		hud.set_hint(_build_hint())
	elif index == data.building_order.size():
		_build_part = CLAIM_TOOL
		hud.set_hint(_build_hint())


func _update_build_mode(player: SimCharacter) -> void:
	if Input.is_action_just_pressed("rotate_build"):
		_build_rot = (_build_rot + 1) % 2
	if _build_part == CLAIM_TOOL:
		_update_claim_tool(player)
		return
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


const CLAIM_TOOL: String = "claim_tile"


func _update_claim_tool(player: SimCharacter) -> void:
	var tile := SimMap.cell_of(view.mouse_world_pos())
	var reason := world.claims.claim_tile_reason(world, player, tile)
	var cells: Array[Vector2i] = [Vector2i(tile.x * 2, tile.y * 2), Vector2i(tile.x * 2 + 1, tile.y * 2), Vector2i(tile.x * 2, tile.y * 2 + 1), Vector2i(tile.x * 2 + 1, tile.y * 2 + 1)]
	view.ghost = {"cells": cells, "valid": reason.is_empty()}
	if Input.is_action_just_pressed("shoot"):
		if net != null:
			net.send({"t": "claim_tile", "x": tile.x, "y": tile.y}, true)
		elif reason.is_empty():
			world.claims.claim_tile(world, player, tile)
		else:
			hud.show_message("Beanspruchen geht nicht: %s" % reason, 1.5)
	if Input.is_action_just_pressed("demolish"):
		if net != null:
			net.send({"t": "release_tile", "x": tile.x, "y": tile.y}, true)
		elif world.claims.release_tile(world, player, tile):
			hud.show_message("Kachel freigegeben.", 1.0)
		else:
			hud.show_message("Keine eigene Kachel (die Ankerkachel bleibt).", 1.5)


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


func _on_repair_requested(item_id: String) -> void:
	var player := world.get_character(player_id)
	if player == null:
		return
	if net != null:
		net.send({"t": "repair", "item": item_id}, true)
		return
	var reason := world.repair(player, item_id)
	var label := String(data.items[item_id]["name"])
	craft_panel.show_status(("%s repariert (Maximum sinkt je Reparatur)." % label) if reason.is_empty() else "Geht nicht: %s" % reason)
	craft_panel.refresh()


func _on_craft_requested(item_id: String) -> void:
	var player := world.get_character(player_id)
	if player == null:
		return
	if net != null:
		net.send({"t": "craft", "item": item_id}, true)
		return
	var reason := world.craft(player, item_id)
	if reason.is_empty():
		var label := String((data.items.get(item_id, data.resources.get(item_id, {})))["name"])
		craft_panel.show_status("%s gebaut." % label)
		hud.show_message("%s gebaut." % label, 2.0)
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
	var owner_id := old.owner_id if old != null else "p1"
	var fresh := world.spawn_player(world.spawn_point_for(owner_id), owner_id, old.name if old != null else "Du")
	player_id = fresh.id
	hud.player_id = player_id
	hud.set_hint(HINT_VERSUS if mode == Mode.VERSUS else HINT_LIVE)
	hud.show_message("Neuer Charakter. Dein altes Zeug liegt bei der Leiche.")


func _handle_events() -> void:
	for event: Dictionary in world.events:
		var id := int(event.get("id", -1))
		var player_owner: String = world.get_character(player_id).owner_id if world.get_character(player_id) != null else ""
		if String(event.get("owner", "")) == player_owner and not player_owner.is_empty():
			match String(event.get("type", "")):
				"claim_created":
					hud.show_message("Claim gegründet. Kacheln beanspruchen: B, dann 3. Holz am Anker abliefern: E daneben.", 5.0)
				"claim_starving":
					hud.show_message("Dein Claim hat keinen Vorrat mehr, er schrumpft von außen!", 4.0)
				"claim_shrink":
					hud.show_message("Claim geschrumpft: noch %d Kacheln." % event["tiles"], 3.0)
				"claim_anchor_lost":
					hud.show_message("Dein Anker ist weg! Neu verankern, bevor die Schonfrist endet.", 5.0)
				"claim_dissolved":
					hud.show_message("Dein Claim ist aufgelöst (%s)." % event["reason"], 5.0)
				"claim_restored":
					hud.show_message("Anker wiederhergestellt, Claim gerettet.", 3.0)
				"sensor_triggered":
					hud.show_message("%s ausgelöst!" % event["label"], 2.5)
				"trap_triggered":
					hud.show_message("Deine Falle hat zugeschnappt.", 2.5)
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
			"deposit":
				hud.show_message("%d Holz am Anker abgeliefert, Vorrat %d." % [event["amount"], int(event["stock"])], 2.0)
			"trap_triggered":
				hud.show_message("In eine Falle getreten!", 2.0)
			"depot_deposit":
				hud.show_message("Eingelagert: %d %s (Gebühr %d)." % [event["kept"], data.resources[event["resource"]]["name"], event["fee"]], 2.0)
			"depot_withdraw":
				hud.show_message("Geholt: %d %s." % [event["amount"], data.resources[event["resource"]]["name"]], 2.0)
			"market_peace":
				hud.show_message("Neutraler Markt: hier gibt es keinen Kampf.", 1.5)
			"item_broken":
				hud.show_message("%s zerbrochen!" % data.items[event["item"]]["name"], 3.0)
			"no_ammo":
				hud.show_message("Keine %s mehr." % data.resources[world.ammo_of(event["weapon"])]["name"], 1.5)
			"healed":
				_heal_active = false
				hud.show_message("Verband angelegt: +%d Leben (%d übrig)." % [int(event["amount"]), event["left"]], 2.0)
			"trade":
				hud.show_message("Gekauft: %d %s für %d %s." % [event["sell_amount"], data.resources[event["sell"]]["name"], event["price_amount"], data.resources[event["price"]]["name"]], 2.0)
			"theft":
				hud.show_message("Diebstahl! Das ist der Claim von %s." % event["owner"], 2.0)
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
