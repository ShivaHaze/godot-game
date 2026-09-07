extends Node2D
## Spielsteuerung: bindet die Simulation (sim/) an Darstellung und Eingabe.
## Liest den Sim-Zustand, zeichnet ihn und schreibt nur Absichten (SimIntent) hinein.

const WorldViewScript := preload("res://game/world_view.gd")
const HudScript := preload("res://game/hud.gd")

const MAX_TICKS_PER_FRAME: int = 5  # Schutz gegen Aufholspiralen bei Rucklern
const HINT_LIVE: String = "WASD bewegen · Maus zielen · Linksklick schießen · E halten: sammeln/plündern · F essen · M Marker · Esc Ausloggen"
const HINT_DEAD: String = "Du bist tot. R = neuer Charakter am Spawn."

var data: SimData
var world: SimWorld
var player_id: int = -1

var view: Node2D
var hud: CanvasLayer
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

	hud.world = world
	hud.player_id = player_id
	hud.set_hint(HINT_LIVE)


func _process(delta: float) -> void:
	if world == null:
		return
	var player := world.get_character(player_id)
	if Input.is_action_just_pressed("eat"):
		_eat_pressed = true
	if Input.is_action_just_pressed("place_marker") and player != null and not player.dead:
		var marker := world.add_marker(player_id)
		hud.show_message("%s gesetzt" % marker["name"])
	if Input.is_action_just_pressed("respawn") and player != null and player.dead:
		_respawn_player()
		player = world.get_character(player_id)

	_accumulator += delta
	var ticks := 0
	while _accumulator >= world.tick_dt and ticks < MAX_TICKS_PER_FRAME:
		if player != null and not player.dead:
			world.set_intent(player_id, _build_player_intent(player))
		world.tick()
		_handle_events()
		_accumulator -= world.tick_dt
		ticks += 1
	if ticks == MAX_TICKS_PER_FRAME:
		_accumulator = 0.0

	view.alpha = _accumulator / world.tick_dt
	if player != null:
		camera.position = WorldViewScript.to_pixels(player.render_pos(view.alpha))
	view.queue_redraw()
	hud.refresh()


func _build_player_intent(player: SimCharacter) -> SimIntent:
	var intent := SimIntent.new()
	intent.move = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	intent.aim = view.mouse_world_pos() - player.pos
	intent.shoot = Input.is_action_pressed("shoot")
	intent.interact = Input.is_action_pressed("interact")
	intent.eat = _eat_pressed
	_eat_pressed = false
	return intent


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
				hud.show_message("%s +1" % data.resources[event["resource"]]["name"], 1.0)
			"eat":
				hud.show_message("Gegessen: %s (%d→%d)" % [data.resources[event["resource"]]["name"], event["before"], event["after"]], 1.5)
			"hit":
				hud.show_message("Getroffen %s: −%d" % [SimCombat.side_name(event["side"]), int(ceilf(event["damage"]))], 1.0)
			"loot":
				var parts: PackedStringArray = []
				for rid: String in event["items"]:
					parts.append("%s %d" % [data.resources[rid]["name"], event["items"][rid]])
				hud.show_message("Geplündert: " + ", ".join(parts), 2.0)
			"death":
				hud.set_hint(HINT_DEAD)
				var killer := world.get_character(int(event["attacker"]))
				hud.show_message("Du bist gestorben (%s)." % (killer.name if killer != null else "Unbekannt"), 4.0)
