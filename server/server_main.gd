extends SceneTree
## Headless-Server (Netzwerk-Spike): dieselbe Simulation wie im Spiel, autoritativ, 20 Hz, ENet.
## Lädt user://server_save.dat (falls vorhanden), sonst neue Welt; füllt optional NPCs auf; speichert alle 60 s.
## Aufruf: godot --headless --path . -s server/server_main.gd [-- <Port> <NPC-Füllung> <Laufzeit s> <Karte>]
## Karte: Pfad zu einer map.json oder 'gen:120x90:7' (Generator mit Breite×Höhe:Seed); leer = data/map.json.
## Standard: Port 7777, 0 NPCs, unbegrenzt. Statistik alle 5 s auf der Konsole. Clients bekommen die Karte beim Beitritt.

const SAVE_PATH: String = "user://server_save.dat"

var port: int = 7777
var fill_npcs: int = 0
var run_seconds: float = 0.0
var map_arg: String = ""

var data: SimData
var world: SimWorld
var server := NetServer.new()
var _last_usec: int = 0
var _stats_timer: float = 0.0
var _save_timer: float = 0.0
var _elapsed: float = 0.0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		port = int(args[0])
	if args.size() > 1:
		fill_npcs = int(args[1])
	if args.size() > 2:
		run_seconds = float(args[2])
	if args.size() > 3:
		map_arg = args[3]
	data = SimData.load_from_dir("res://data")
	if not data.is_valid():
		for e: String in data.errors:
			printerr(e)
		quit(1)
		return
	if not map_arg.is_empty():
		var problems := data.apply_map(_load_map_arg(map_arg))
		if not problems.is_empty():
			printerr("Karte unbrauchbar: ", problems)
			quit(1)
			return
		print("Karte: %s (%d×%d, %d Spieler-Spawns)" % [map_arg, data.map_width, data.map_height, data.player_spawns.size()])
	var saved := SimSave.load_from_file(data, SAVE_PATH)
	if saved.is_empty():
		world = SimWorld.new(data, int(Time.get_unix_time_from_system()) % 100000)
		world.setup_new_game()
		world.characters.erase(1)  # der lokale 'Du'-Charakter gehört auf dem Server niemandem
		print("Neue Welt.")
	else:
		world = saved["world"]
		print("Welt geladen: Uhr %s, %d Charaktere." % [world.clock_string(), world.characters.size()])
	_fill_npcs()
	if server.start(data, world, port) != OK:
		quit(1)
		return
	Engine.max_fps = 60
	_last_usec = Time.get_ticks_usec()
	process_frame.connect(_on_frame)
	print("Server läuft auf Port %d (Tick %d Hz, Snapshots %d Hz). Strg+C beendet." % [port, data.bali("tick_rate"), data.bali("tick_rate") / NetProtocol.SNAPSHOT_EVERY_TICKS])


## 'gen:BxH:Seed' oder Pfad zu einer map.json.
func _load_map_arg(arg: String) -> Dictionary:
	if arg.begins_with("gen:"):
		var parts := arg.split(":")
		var size := parts[1].split("x") if parts.size() > 1 else PackedStringArray(["120", "90"])
		var seed := int(parts[2]) if parts.size() > 2 else 1
		return MapGen.generate(int(size[0]), int(size[1]) if size.size() > 1 else 90, seed)
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(arg)) != OK or not (json.data is Dictionary):
		return {}
	return json.data


func _fill_npcs() -> void:
	if fill_npcs <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var walkable: Array[Vector2i] = []
	for y in world.map.height:
		for x in world.map.width:
			if world.map.is_walkable(Vector2i(x, y)):
				walkable.append(Vector2i(x, y))
	for i in fill_npcs:
		var cell: Vector2i = walkable[rng.randi_range(0, walkable.size() - 1)]
		var c := world.spawn_player(SimMap.cell_center(cell), "füll%d" % i, "Siedler %d" % i)
		c.inventory["berries"] = 5
		var role: String = data.role_order[i % data.role_order.size()]
		world.logout(c.id, data.roles[role]["rules"], String(data.roles[role]["name"]))
		c.logout_time = -1e9


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	var delta := (now - _last_usec) / 1_000_000.0
	_last_usec = now
	delta = minf(delta, 0.25)
	server.update(delta)
	_elapsed += delta
	_stats_timer += delta
	_save_timer += delta
	if _stats_timer >= 5.0:
		print(server.stats_line(_stats_timer))
		_stats_timer = 0.0
	if _save_timer >= 60.0:
		_save_timer = 0.0
		SimSave.save_to_file(world, SAVE_PATH)
	if run_seconds > 0.0 and _elapsed >= run_seconds:
		print("Laufzeit erreicht, speichere und beende.")
		SimSave.save_to_file(world, SAVE_PATH)
		server.stop()
		quit()
