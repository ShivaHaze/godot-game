extends Node2D
## Spielsteuerung: bindet die Simulation (sim/) an Darstellung und Eingabe.
## Liest den Sim-Zustand, zeichnet ihn und schreibt nur Absichten (SimIntent) hinein.
## Modi: LIVE (Spieler steuert), MENU (Ausloggen-Menü, Sim pausiert), OFFLINE (Charakter ist NPC, Zuschauen).

enum Mode { LIVE, MENU, OFFLINE }

const WorldViewScript := preload("res://game/world_view.gd")
const HudScript := preload("res://game/hud.gd")
const LogoutMenuScript := preload("res://game/logout_menu.gd")

const MAX_TICKS_PER_FRAME: int = 5  # Schutz gegen Aufholspiralen bei Rucklern
const HINT_LIVE: String = "WASD bewegen · Maus zielen · Linksklick schießen · E halten: sammeln/plündern · F essen · M Marker · Esc Ausloggen"
const HINT_DEAD: String = "Du bist tot. R = neuer Charakter am Spawn."
const HINT_OFFLINE: String = "Dein Charakter handelt jetzt nach seinen Regeln. Du schaust nur zu."

var data: SimData
var world: SimWorld
var player_id: int = -1
var mode: Mode = Mode.LIVE

var view: Node2D
var hud: CanvasLayer
var menu: CanvasLayer
var camera: Camera2D

var _accumulator: float = 0.0
var _eat_pressed: bool = false


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
	world = SimWorld.new(data, 12345)
	player_id = world.setup_new_game()

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
	add_child(menu)

	hud.world = world
	hud.player_id = player_id
	_enter_live()


func _process(delta: float) -> void:
	if world == null:
		return
	var player := world.get_character(player_id)
	match mode:
		Mode.LIVE:
			_process_live_input(player)
		Mode.MENU:
			if Input.is_action_just_pressed("logout_menu"):
				_close_menu()
			_refresh_view(player)  # Sim pausiert, Leinen-Vorschau wird trotzdem gezeichnet
			return
		Mode.OFFLINE:
			pass

	_accumulator += delta
	var ticks := 0
	while _accumulator >= world.tick_dt and ticks < MAX_TICKS_PER_FRAME:
		if mode == Mode.LIVE and player != null and not player.dead:
			world.set_intent(player_id, _build_player_intent(player))
		world.tick()
		_handle_events()
		_accumulator -= world.tick_dt
		ticks += 1
	if ticks == MAX_TICKS_PER_FRAME:
		_accumulator = 0.0

	_refresh_view(player)


func _refresh_view(player: SimCharacter) -> void:
	view.alpha = _accumulator / world.tick_dt
	if player != null:
		camera.position = WorldViewScript.to_pixels(player.render_pos(view.alpha))
	view.queue_redraw()
	if mode == Mode.OFFLINE and player != null:
		hud.set_chronicle(SimChronicle.format_all(player))
	hud.refresh()


func _process_live_input(player: SimCharacter) -> void:
	if player == null:
		return
	if Input.is_action_just_pressed("eat"):
		_eat_pressed = true
	if Input.is_action_just_pressed("place_marker") and not player.dead:
		var marker := world.add_marker(player_id)
		hud.show_message("%s gesetzt" % marker["name"])
	if Input.is_action_just_pressed("respawn") and player.dead:
		_respawn_player()
	if Input.is_action_just_pressed("logout_menu") and not player.dead:
		_open_menu()


func _build_player_intent(player: SimCharacter) -> SimIntent:
	var intent := SimIntent.new()
	intent.move = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	intent.aim = view.mouse_world_pos() - player.pos
	intent.shoot = Input.is_action_pressed("shoot")
	intent.interact = Input.is_action_pressed("interact")
	intent.eat = _eat_pressed
	_eat_pressed = false
	return intent


# --- Modi -----------------------------------------------------------------

func _enter_live() -> void:
	mode = Mode.LIVE
	hud.mode_text = "Live"
	hud.set_hint(HINT_LIVE)
	hud.clear_buttons()
	hud.show_chronicle(false)
	view.preview_rules = []


func _open_menu() -> void:
	var player := world.get_character(player_id)
	mode = Mode.MENU
	menu.open(data, player, player.rules, player.role_id)


func _close_menu() -> void:
	menu.close()
	_enter_live()


func _on_logout_confirmed(rules: Array, role_id: String, role_name: String) -> void:
	menu.close()
	var player := world.get_character(player_id)
	player.role_id = role_id
	world.logout(player_id, rules, role_name)
	_enter_offline()


func _enter_offline() -> void:
	mode = Mode.OFFLINE
	view.preview_rules = []
	hud.mode_text = "Offline – NPC handelt nach Regeln"
	hud.set_hint(HINT_OFFLINE)
	hud.clear_buttons()
	hud.show_chronicle(true, "Chronik (live)")
	hud.add_button("Wieder einloggen", _login)


func _login() -> void:
	var player := world.get_character(player_id)
	if player == null:
		return
	world.login(player_id)
	_enter_live()
	hud.show_message("Du übernimmst deinen Charakter wieder.", 3.0)
	if player.dead:
		hud.set_hint(HINT_DEAD)


## Neuer, frischer Charakter am Spawn; die Leiche bleibt liegen.
func _respawn_player() -> void:
	var spawn := SimMap.cell_center(data.player_spawns[0])
	var fresh := world.spawn_player(spawn, "p1", "Du")
	player_id = fresh.id
	hud.player_id = player_id
	hud.set_hint(HINT_LIVE)
	hud.show_message("Neuer Charakter. Dein altes Zeug liegt bei der Leiche.")


func _handle_events() -> void:
	for event: Dictionary in world.events:
		if int(event.get("id", -1)) != player_id:
			continue
		match String(event.get("type", "")):
			"gather":
				if mode == Mode.LIVE:
					hud.show_message("%s +1" % data.resources[event["resource"]]["name"], 1.0)
			"eat":
				if mode == Mode.LIVE:
					hud.show_message("Gegessen: %s (%d→%d)" % [data.resources[event["resource"]]["name"], event["before"], event["after"]], 1.5)
			"hit":
				hud.show_message("Getroffen %s: −%d" % [SimCombat.side_name(event["side"]), int(ceilf(event["damage"]))], 1.0)
			"loot":
				var parts: PackedStringArray = []
				for rid: String in event["items"]:
					parts.append("%s %d" % [data.resources[rid]["name"], event["items"][rid]])
				hud.show_message("Geplündert: " + ", ".join(parts), 2.0)
			"death":
				var killer := world.get_character(int(event["attacker"]))
				var killer_name: String = killer.name if killer != null else "Unbekannt"
				if mode == Mode.LIVE:
					hud.set_hint(HINT_DEAD)
					hud.show_message("Du bist gestorben (%s)." % killer_name, 4.0)
				else:
					hud.show_message("Dein Charakter ist gestorben (%s)." % killer_name, 4.0)
