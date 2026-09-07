extends GutTest
## Schwefel (nur live) → Pulver → Kugeln; Turrets schießen auf Fremde mit Sichtlinie und brauchen Munition; Raidwaren nicht ins Depot.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 191)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _turret(origin: Vector2i = Vector2i(44, 10)) -> SimBuilding:
	player.inventory["iron"] = 4
	player.inventory["wood"] = 6
	player.inventory["wire"] = 2
	var b := world.place_building(player, "turret", origin, 0)
	assert_not_null(b, "Turret: %s" % world.can_place(player, "turret", origin, 0))
	return b


func test_sulfur_is_live_only_and_chain_to_shot() -> void:
	assert_eq(world.map.node_at(Vector2i(21, 14)).resource, "sulfur")
	player.pos = Vector2(21.5, 15.5)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "sulfur", "place": "here", "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Schürfer")
	player.logout_time = -1e9
	world.advance(20.0)
	assert_eq(int(player.inventory.get("sulfur", 0)), 0, "offline nie")
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("nur live abbaubar"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
	world.login(player.id)
	var intent := SimIntent.new()
	intent.interact = true
	for i in 20 * 3:
		world.set_intent(player.id, intent)
		world.tick()
	assert_gte(int(player.inventory.get("sulfur", 0)), 1, "live von Hand: %s" % [player.inventory])
	player.inventory["sulfur"] = 2
	player.inventory["coal"] = 2
	player.inventory["iron"] = 2
	assert_eq(world.craft(player, "powder"), "")
	assert_eq(int(player.inventory["powder"]), 2)
	assert_eq(world.craft(player, "shot"), "")
	assert_eq(int(player.inventory["shot"]), 4)
	var gen := SimData.load_from_dir("res://data")
	assert_true(gen.apply_map(MapGen.generate(120, 90, 7)).is_empty())
	var big := SimWorld.new(gen, 1)
	var sulfur := 0
	for node: SimResourceNode in big.map.nodes.values():
		if node.resource == "sulfur":
			sulfur += 1
			var edge := minf(minf(node.cell.x, big.map.width - 1 - node.cell.x) / (big.map.width * 0.5), minf(node.cell.y, big.map.height - 1 - node.cell.y) / (big.map.height * 0.5))
			assert_gte(edge, 0.6, "Zentrum: %s" % node.cell)
	assert_gt(sulfur, 0)


func test_turret_shoots_strangers_with_line_of_sight_and_uses_ammo() -> void:
	var turret := _turret()
	assert_eq(turret.label, "Turret 1")
	assert_true(player.extra_places.has("b%d" % turret.id), "Turret ist ein Ort")
	player.inventory["shot"] = 5
	player.pos = Vector2(21.2, 5.5)  # in Interaktionsreichweite (1,3 + 0,5) der Turret-Mitte (22,5, 5,5)
	var intent := SimIntent.new()
	intent.interact = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(int(turret.contents.get("shot", 0)), 5, "E lädt alle Kugeln")
	assert_eq(int(player.inventory["shot"]), 0)
	var stranger := world.spawn_player(turret.center() + Vector2(4, 0), "p2", "Fremder")
	var hp := stranger.hp
	var shots := 0
	for i in 20 * 3:
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "turret_shot":
				shots += 1
	assert_true(shots == 3 or shots == 2, "ein Schuss je Sekunde (Rundung der Tickzeit): %d" % shots)
	assert_lt(stranger.hp, hp, "Schaden")
	assert_eq(int(turret.contents["shot"]), 5 - shots, "eine Kugel je Schuss")
	assert_true(SimSensors.is_under_attack(world, stranger))
	assert_eq(player.hp, player.max_hp, "Besitzer bleibt heil")
	stranger.hp = 1.0
	world.advance(2.0)
	assert_true(stranger.dead)
	var last := SimChronicle.format_all(stranger)[SimChronicle.format_all(stranger).size() - 1]
	assert_true(last.contains("gestorben durch ein Turret"), "Chronik: %s" % last)
	# Leer: kein Schuss mehr; versteckte Fremde werden nicht gesehen
	turret.contents["shot"] = 0
	var sneaky := world.spawn_player(turret.center() + Vector2(0, 3), "p3", "Schleicher")
	world.tick()
	turret.contents["shot"] = 10
	sneaky.hidden = true
	shots = 0
	for i in 20:
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "turret_shot":
				shots += 1
	assert_eq(shots, 0, "versteckt = unsichtbar für das Turret")
	sneaky.hidden = false
	# Wand dazwischen: keine Sichtlinie
	player.pos = turret.center() + Vector2(0, -1.4)
	player.inventory["wood"] = 10
	var wall := world.place_building(player, "wood_wall", Vector2i(44, 13), 1)  # quer unter dem Turret
	assert_not_null(wall, "Wand: %s" % world.can_place(player, "wood_wall", Vector2i(44, 13), 1))
	sneaky.pos = turret.center() + Vector2(0.25, 2.2)
	world.spatial.rebuild(world.characters)
	for i in 20:
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "turret_shot":
				shots += 1
	assert_eq(shots, 0, "keine Sichtlinie durch die Wand")


func test_npc_delivers_shot_to_turret_and_depot_refuses_raid_goods() -> void:
	var turret := _turret()
	player.pos = Vector2(18.5, 5.5)
	player.inventory["shot"] = 6
	world.unlock("p1", "owned_container", player)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "shot", "place": "b%d" % turret.id, "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Versorger")
	player.logout_time = -1e9
	for i in 20 * 6:
		world.tick()
	assert_eq(int(turret.contents.get("shot", 0)), 6, "NPC lädt das Turret")
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("geliefert: Kugeln zu Turret 1 (6 Kugeln)"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
	world.login(player.id)
	player.inventory["wood"] = 3
	rules = data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "wood", "place": "b%d" % turret.id, "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Versorger")
	player.logout_time = -1e9
	world.tick()
	found = false
	for line: String in SimChronicle.format_all(player):
		if line.contains("das Turret nimmt nur Kugeln"):
			found = true
	assert_true(found)
	world.login(player.id)
	var depot: SimBuilding = null
	for b: SimBuilding in world.depots():
		if world.map.zone(SimMap.cell_of(b.center())) == "market":
			depot = b
	player.pos = depot.center() + Vector2(-1.2, 0)
	player.inventory["powder"] = 2
	assert_eq(world.depot_deposit(player, depot, "powder", 2), "Raidware: am neutralen Markt nicht handelbar")
