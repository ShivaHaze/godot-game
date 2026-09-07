extends SceneTree
## Server-Benchmark (Netzwerk-Spike, Teil 1): viele Offline-NPCs mit Rollen, Wölfe und einige Online-Spieler
## mit Zufallsbewegung, simuliert headless bei 20 Hz. Druckt Tickzeit Ø/max/p95 und ob Echtzeit erreicht wird.
## Aufruf: godot --headless --path . -s tools/server_bench.gd [-- <NPCs> <Spieler> <Sekunden>]  (Standard 300 5 60)

var npc_count: int = 300
var player_count: int = 5
var seconds: float = 60.0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		npc_count = int(args[0])
	if args.size() > 1:
		player_count = int(args[1])
	if args.size() > 2:
		seconds = float(args[2])
	var data := SimData.load_from_dir("res://data")
	if not data.is_valid():
		for e: String in data.errors:
			printerr(e)
		quit(1)
		return
	var world := SimWorld.new(data, 1)
	world.setup_new_game()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var walkable: Array[Vector2i] = []
	for y in world.map.height:
		for x in world.map.width:
			if world.map.is_walkable(Vector2i(x, y)):
				walkable.append(Vector2i(x, y))
	var roles: Array[String] = []
	roles.assign(data.role_order)
	for i in npc_count:
		var cell: Vector2i = walkable[rng.randi_range(0, walkable.size() - 1)]
		var c := world.spawn_player(SimMap.cell_center(cell), "npc%d" % i, "NPC %d" % i)
		c.inventory["berries"] = 5
		var role: String = roles[i % roles.size()]
		world.logout(c.id, data.roles[role]["rules"], String(data.roles[role]["name"]))
		c.logout_time = -1e9  # Übergang für den Benchmark überspringen
	var players: Array[SimCharacter] = []
	for i in player_count:
		var cell: Vector2i = walkable[rng.randi_range(0, walkable.size() - 1)]
		players.append(world.spawn_player(SimMap.cell_center(cell), "online%d" % i, "Spieler %d" % i))
	var directions: Array[Vector2] = []
	for i in player_count:
		directions.append(Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU)))

	var ticks := int(seconds / world.tick_dt)
	var samples := PackedFloat64Array()
	var total_started := Time.get_ticks_usec()
	for t in ticks:
		if t % 40 == 0:
			for i in player_count:
				directions[i] = Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))
		for i in player_count:
			var intent := SimIntent.new()
			intent.move = directions[i]
			intent.shoot = t % 30 == 0
			world.set_intent(players[i].id, intent)
		var started := Time.get_ticks_usec()
		world.tick()
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
	var total_ms := (Time.get_ticks_usec() - total_started) / 1000.0
	var sorted := samples.duplicate()
	sorted.sort()
	var sum := 0.0
	var max_ms := 0.0
	for v: float in samples:
		sum += v
		max_ms = maxf(max_ms, v)
	var avg := sum / samples.size()
	var p95: float = sorted[int(sorted.size() * 0.95)]
	var alive_npcs := 0
	var fine_steps := 0
	var coarse_steps := 0
	for c: SimCharacter in world.characters.values():
		if c.control == SimCharacter.Controller.RULES and not c.dead:
			alive_npcs += 1
		fine_steps += c.lod_fine_steps
		coarse_steps += c.lod_coarse_steps
	print("Server-Benchmark: %d NPCs, %d Wölfe, %d Online-Spieler, %.0f s Sim bei %d Hz" % [npc_count, world.count_alive_wolves(), player_count, seconds, data.bali("tick_rate")])
	print("Tickzeit: Ø %.2f ms · p95 %.2f ms · max %.2f ms · Budget %.1f ms" % [avg, p95, max_ms, world.tick_dt * 1000.0])
	print("Echtzeit: %.1f s Sim in %.1f s real → Faktor %.2f (%s)" % [seconds, total_ms / 1000.0, seconds / (total_ms / 1000.0), "echtzeitfähig" if avg < world.tick_dt * 1000.0 else "ZU LANGSAM"])
	print("Simulationsstufen: %d feine, %d grobe Charakterschritte · NPCs am Ende lebend: %d/%d" % [fine_steps, coarse_steps, alive_npcs, npc_count])
	quit()
