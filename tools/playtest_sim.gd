extends SceneTree
## Testabend-Nacht headless: baut die Lage auf dem Server nach und lässt sie laufen. Füll-NPCs wie
## ServerRunner._fill_npcs (zufällige begehbare Zelle, Rollen reihum, 5 Beeren, ohne Übergang), dazu 8 Test-Charaktere
## (4 Rollen × nackt mit 5 Beeren bzw. Keule + angelegter Holzpanzer mit 8 Beeren, Hunger 90) höchstens 6 Kacheln
## um den Start-Spawn, wie Freunde, die nebeneinander ausloggen. Wölfe, Leitwolf und Karawane laufen normal.
## Druckt je Berichtsintervall: Überlebende, Wölfe, Ereignisse, Beeren auf der Karte, Todesursachen, Hunger der Tests.
## Aufruf: godot --headless --path . -s tools/playtest_sim.gd -- <Karte> <Füll-NPCs> <Stunden> [Seed] [dt]
##         [Berichtsminuten] [Datenordner|-] [guild] [dump] [spread]
##   Karte: default | gen:<B>x<H>:<Seed> | Pfad zu einer Karten-JSON
##   dt: Schrittweite in Sekunden (Standard 0,05 = 20 Hz wie der Server; gröber überschätzt die Wölfe deutlich)
##   Schalter (an beliebiger Stelle): guild: alle Test-Charaktere in einer Gilde · dump: Chronik aller Tests ·
##   spread: Tests mindestens 9 Kacheln auseinander
## Beispiel: godot --headless --path . -s tools/playtest_sim.gd -- default 0 16 1

const TEST_COUNT: int = 8
const SPAWN_RADIUS: float = 6.0     # Test-Charaktere loggen so nah am Start-Spawn aus
const SPREAD_DISTANCE: float = 9.0  # 'spread': Mindestabstand der Test-Charaktere untereinander
const CHRONICLE_TAIL: int = 40      # so viele letzte Chronikzeilen je ausgegebenem Charakter

var map_arg: String = "default"
var fillers: int = 0
var hours: float = 16.0
var run_seed: int = 1
var dt: float = 0.05
var report_minutes: float = 60.0
var data_dir: String = "res://data"
var dump: bool = false
var guild: bool = false
var spread: bool = false


func _init() -> void:
	# Schalter zuerst herausziehen: sie dürfen an jeder Stelle stehen, auch direkt hinter dem Seed
	var args: Array[String] = []
	for arg: String in OS.get_cmdline_user_args():
		match arg:
			"dump":
				dump = true
			"guild":
				guild = true
			"spread":
				spread = true
			_:
				args.append(arg)
	if args.size() > 0:
		map_arg = args[0]
	if args.size() > 1:
		fillers = int(args[1])
	if args.size() > 2:
		hours = float(args[2])
	if args.size() > 3:
		run_seed = int(args[3])
	if args.size() > 4:
		dt = float(args[4])
	if args.size() > 5:
		report_minutes = float(args[5])
	if args.size() > 6 and args[6] != "-":
		data_dir = args[6]
	if dt <= 0.0 or report_minutes <= 0.0 or hours <= 0.0:
		printerr("dt, Berichtsminuten und Stunden müssen größer als 0 sein (dt %s, Berichtsminuten %s, Stunden %s)" % [dt, report_minutes, hours])
		quit(1)
		return
	var data := SimData.load_from_dir(data_dir)
	if map_arg != "default":
		var problems := data.apply_map(_load_map(map_arg))
		if not problems.is_empty():
			printerr("Karte unbrauchbar: ", problems)
			quit(1)
			return
	if not data.is_valid():
		for e: String in data.errors:
			printerr(e)
		quit(1)
		return
	var world := SimWorld.new(data, run_seed)
	world.characters.erase(world.setup_new_game())  # ohne den Einzelspieler-Charakter
	var walkable := _walkable_cells(world)
	print("Karte %s: %d×%d, begehbar %d, Spieler-Spawns %d, Wolf-Spawns %d, Depots %d" % [map_arg, world.map.width, world.map.height,
		walkable.size(), data.player_spawns.size(), data.wolf_spawns.size(), data.depot_spawns.size()])
	_fill(world, walkable)
	var tests := _spawn_tests(world, walkable)
	if guild:
		var founder := tests[0].owner_id
		world.guild_command(founder, "found", "Testgilde")
		for i in range(1, tests.size()):
			world.guild_command(founder, "invite", tests[i].owner_id)
			world.guild_command(tests[i].owner_id, "accept", "")
		print("Gilde: %d Mitglieder" % world.guilds.members_of(founder).size())
	_run(world, tests)
	quit()


## Karte aus dem Argument: gen:<B>x<H>:<Seed> erzeugt eine, sonst eine JSON-Datei.
func _load_map(arg: String) -> Dictionary:
	if arg.begins_with("gen:"):
		var parts := arg.split(":")
		var size := parts[1].split("x") if parts.size() > 1 else PackedStringArray(["120", "90"])
		return MapGen.generate(int(size[0]), int(size[1]) if size.size() > 1 else 90, int(parts[2]) if parts.size() > 2 else 1)
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(arg)) != OK or not (json.data is Dictionary):
		return {}
	return json.data


func _walkable_cells(world: SimWorld) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in world.map.height:
		for x in world.map.width:
			if world.map.is_walkable(Vector2i(x, y)):
				result.append(Vector2i(x, y))
	return result


## Füll-NPCs wie ServerRunner._fill_npcs (gleicher Seed 7), zusätzlich mit role_id für die Statistik.
func _fill(world: SimWorld, walkable: Array[Vector2i]) -> void:
	var data := world.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in fillers:
		var cell: Vector2i = walkable[rng.randi_range(0, walkable.size() - 1)]
		var c := world.spawn_player(SimMap.cell_center(cell), "füll%d" % i, "Siedler %d" % i)
		c.inventory["berries"] = 5
		var role: String = data.role_order[i % data.role_order.size()]
		c.role_id = role
		world.logout(c.id, data.roles[role]["rules"], String(data.roles[role]["name"]))
		c.logout_time = -1e9


## Test-Charaktere: Rollen reihum, die zweite Hälfte ausgerüstet. Sie loggen normal aus (Übergang läuft).
func _spawn_tests(world: SimWorld, walkable: Array[Vector2i]) -> Array[SimCharacter]:
	var data := world.data
	var spawn: Vector2i = data.player_spawns[0]
	var near_spawn: Array[Vector2i] = []
	for cell: Vector2i in walkable:
		if Vector2(cell).distance_to(Vector2(spawn)) <= SPAWN_RADIUS and world.map.zone(cell).is_empty():
			near_spawn.append(cell)
	var rng := RandomNumberGenerator.new()
	rng.seed = 100 + run_seed
	var tests: Array[SimCharacter] = []
	for i in TEST_COUNT:
		var role: String = data.role_order[i % data.role_order.size()]
		var equipped := i * 2 >= TEST_COUNT
		var cell: Vector2i = near_spawn[rng.randi_range(0, near_spawn.size() - 1)]
		if spread:
			cell = _spread_cell(world, walkable, tests, rng, cell)
		var c := world.spawn_player(SimMap.cell_center(cell), "test%d" % i, "%s-%s" % [role, "ausger" if equipped else "nackt"])
		c.hunger = 90.0
		c.inventory["berries"] = 8 if equipped else 5
		if equipped:
			for item_id: String in ["club", "wood_armor"]:
				var durability := float(data.items[item_id]["durability"])
				c.items.append(item_id)
				c.durability[item_id] = {"left": durability, "max": durability}
			SimCrafting.equip_armor(world, c, "wood_armor")
		c.role_id = role
		world.logout(c.id, data.roles[role]["rules"], String(data.roles[role]["name"]))
		tests.append(c)
	return tests


## 'spread': eine Zelle außerhalb der Zonen, mindestens SPREAD_DISTANCE von allen bisherigen Tests; sonst fallback.
func _spread_cell(world: SimWorld, walkable: Array[Vector2i], tests: Array[SimCharacter], rng: RandomNumberGenerator, fallback: Vector2i) -> Vector2i:
	for _attempt in 2000:
		var candidate: Vector2i = walkable[rng.randi_range(0, walkable.size() - 1)]
		if not world.map.zone(candidate).is_empty():
			continue
		var free := true
		for t: SimCharacter in tests:
			if t.pos.distance_to(SimMap.cell_center(candidate)) < SPREAD_DISTANCE:
				free = false
				break
		if free:
			return candidate
	return fallback


## Todesursache aus Sicht des Angreifers: wolf, boss, caravan, npc (ein anderer Mensch) oder other (Turret, Falle …).
func _cause(world: SimWorld, attacker_id: int) -> String:
	var attacker := world.get_character(attacker_id)
	if attacker == null:
		return "other"
	if attacker.kind == SimCharacter.Kind.WOLF:
		return "boss" if attacker.boss else "wolf"
	if attacker.kind == SimCharacter.Kind.CARAVAN:
		return "caravan"
	return "npc"


func _run(world: SimWorld, tests: Array[SimCharacter]) -> void:
	var data := world.data
	var berry_max := 0
	for node: SimResourceNode in world.map.nodes.values():
		if node.resource == "berries":
			berry_max += node.max_amount
	print("Beeren-Quellen: %d Stück Vorrat, Nachwuchs bis %.0f/h" % [berry_max, berry_max / 4.0 * 3600.0 / data.balf("gathering.node_regrow_time")])
	print("Spalten: Stunde · Füll-NPCs lebend [Verstecken/Wache/Sammler/Händler] · Tests lebend · Wölfe · Leitwolf · Karawane · Beeren auf der Karte · Beeren in Depots · Tode im Intervall nach Ursache (Wolf Leitwolf Mensch Karawane sonst) · Hunger Ø der Tests / geschwächt · ms")
	var deaths := {"wolf": 0, "boss": 0, "npc": 0, "caravan": 0, "other": 0}
	var total_deaths := deaths.duplicate()
	var victims := {"filler": 0, "test": 0, "wolf": 0, "boss": 0, "caravan": 0}
	var event_log: Array[String] = []
	var next_report := report_minutes * 60.0
	var end_time := hours * 3600.0
	var started := Time.get_ticks_msec()
	var chunk_started := started
	while world.time < end_time - 1e-6:
		world.step(dt)
		for e: Dictionary in world.events:
			var type := String(e.get("type", ""))
			if type == "death":
				var victim := world.get_character(int(e["id"]))
				if victim == null:
					continue
				var cause := _cause(world, int(e.get("attacker", -1)))
				if victim.kind == SimCharacter.Kind.PLAYER:
					deaths[cause] += 1
					total_deaths[cause] += 1
					if victim.owner_id.begins_with("test"):
						victims["test"] += 1
						event_log.append("%s  %s gestorben (%s)" % [world.clock_string(), victim.name, cause])
					else:
						victims["filler"] += 1
				elif victim.kind == SimCharacter.Kind.WOLF:
					victims["boss" if victim.boss else "wolf"] += 1
				else:
					victims["caravan"] += 1
			elif SimEvents.GLOBAL_EVENTS.has(type):
				event_log.append("%s (t=%.2f h) %s" % [world.clock_string(), world.time / 3600.0, type])
		if world.time >= next_report - 1e-6:
			next_report += report_minutes * 60.0
			var now := Time.get_ticks_msec()
			print(_report_line(world, deaths, berry_max, now - chunk_started))
			chunk_started = now
			for k: String in deaths:
				deaths[k] = 0
	print("Laufzeit gesamt %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	print("Tode (Menschen) nach Ursache: %s; Opfer: %s" % [str(total_deaths), str(victims)])
	print("--- Ereignisse ---")
	for line: String in event_log:
		print(line)
	print("--- Test-Charaktere ---")
	for c: SimCharacter in tests:
		var attacked := 0
		for line: String in SimChronicle.format_all(c):
			if line.contains("angegriffen"):
				attacked += 1
		print("%-16s %s  Leben %.0f  Hunger %.0f%s  Beeren %d  Chronik %d Zeilen, %d× angegriffen, Rüstung %s" % [c.name,
			"TOT " if c.dead else "lebt", c.hp, c.hunger, " (geschwächt)" if c.is_weakened() else "",
			int(c.inventory.get("berries", 0)), c.chronicle.size(), attacked, c.worn_armor if not c.worn_armor.is_empty() else "-"])
	# Chronik: alle Tests mit 'dump', sonst nur der nackte Händler (die riskante Rolle)
	var samples: Array[SimCharacter] = []
	if dump:
		samples = tests
	else:
		samples.append(tests[maxi(0, data.role_order.find("trader"))])
	for sample: SimCharacter in samples:
		print("--- Chronik %s (ausgeloggt bei %s) ---" % [sample.name, str(sample.logout_pos)])
		var lines := SimChronicle.format_all(sample)
		for i in range(maxi(0, lines.size() - CHRONICLE_TAIL), lines.size()):
			print(lines[i])


func _report_line(world: SimWorld, deaths: Dictionary, berry_max: int, ms: int) -> String:
	var alive_roles := {"hide": 0, "guard": 0, "gatherer": 0, "trader": 0}
	var hunger_sum := 0.0
	var weakened := 0
	var tests_alive := 0
	var wolves := 0
	var boss := "-"
	for c: SimCharacter in world.characters.values():
		if c.dead:
			continue
		if c.kind == SimCharacter.Kind.WOLF:
			if c.boss:
				boss = "ja"
			else:
				wolves += 1
		elif c.kind == SimCharacter.Kind.PLAYER:
			if c.owner_id.begins_with("test"):
				tests_alive += 1
				hunger_sum += c.hunger
				if c.is_weakened():
					weakened += 1
			else:
				alive_roles[c.role_id] = int(alive_roles.get(c.role_id, 0)) + 1
	var berries := 0
	for node: SimResourceNode in world.map.nodes.values():
		if node.resource == "berries":
			berries += node.amount
	var depot_berries := 0
	for b: SimBuilding in SimTrade.depots(world):
		for owner: Variant in b.stores:
			depot_berries += int(b.stores[owner].get("berries", 0))
	var caravan := "-"
	for cv: Dictionary in world.caravans.values():
		caravan = String(cv["leg"])
	var fillers_alive := int(alive_roles["hide"]) + int(alive_roles["guard"]) + int(alive_roles["gatherer"]) + int(alive_roles["trader"])
	return "%5.2f h  Füll %d [%d/%d/%d/%d]  Tests %d/%d  Wölfe %d  Leitwolf %s  Karawane %s  Beeren %d/%d  Depot %d  † %d %d %d %d %d  Hunger %.0f / %d  %d ms" % [
		world.time / 3600.0, fillers_alive, alive_roles["hide"], alive_roles["guard"], alive_roles["gatherer"], alive_roles["trader"],
		tests_alive, TEST_COUNT, wolves, boss, caravan, berries, berry_max, depot_berries,
		deaths["wolf"], deaths["boss"], deaths["npc"], deaths["caravan"], deaths["other"],
		hunger_sum / maxf(1.0, float(tests_alive)), weakened, ms]
