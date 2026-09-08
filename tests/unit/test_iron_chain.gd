extends GutTest
## Eisen und Kohle (Mitte): offline nur mit Mine daneben, Eisen braucht Kohle, Eisenaxt bricht Stein, Eisenrüstung macht langsam.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 181)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_ore_in_the_middle_hand_map_and_generator() -> void:
	assert_eq(world.map.node_at(Vector2i(19, 13)).resource, "iron_ore")
	assert_eq(world.map.node_at(Vector2i(20, 16)).resource, "coal")
	var gen := SimData.load_from_dir("res://data")
	assert_true(gen.apply_map(MapGen.generate(120, 90, 7)).is_empty())
	var big := SimWorld.new(gen, 1)
	var iron := 0
	var coal := 0
	for node: SimResourceNode in big.map.nodes.values():
		if node.resource != "iron_ore" and node.resource != "coal":
			continue
		if node.resource == "iron_ore":
			iron += 1
		else:
			coal += 1
		var edge := minf(minf(node.cell.x, big.map.width - 1 - node.cell.x) / (big.map.width * 0.5), minf(node.cell.y, big.map.height - 1 - node.cell.y) / (big.map.height * 0.5))
		assert_gte(edge, 0.35, "innen (Randabstand ≥ 40 %% der halben Kartengröße): %s" % node.cell)
	assert_gt(iron, 0)
	assert_gt(coal, 0)
	assert_lt(coal, iron, "Kohle ist der Engpass")


func test_offline_mining_needs_a_mine_live_does_not() -> void:
	player.pos = Vector2(18.5, 13.5)  # neben der Eisenader (19, 13)
	# Live von Hand
	var intent := SimIntent.new()
	intent.interact = true
	for i in 20 * 3:
		world.set_intent(player.id, intent)
		world.tick()
	assert_gte(int(player.inventory.get("iron_ore", 0)), 1, "live von Hand: %s" % [player.inventory])
	player.inventory["iron_ore"] = 0
	# Offline ohne Mine: Grund in der Chronik
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "iron_ore", "place": "here", "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Bergmann")
	player.logout_time = -1e9
	world.advance(30.0)
	assert_eq(int(player.inventory.get("iron_ore", 0)), 0, "offline ohne Mine nichts")
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("braucht eine Mine daneben"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
	# Mine bauen (nur neben Erz/Kohle), dann klappt es offline
	world.login(player.id)
	player.inventory["wood"] = 12
	player.inventory["stone"] = 6
	player.pos = Vector2(17.5, 13.5)
	assert_eq(SimConstruction.can_place(world, player, "mine", Vector2i(34, 30), 0), "muss neben Eisenerz oder Kohle stehen")  # Kachel (17, 15)
	var mine := SimConstruction.place_building(world, player, "mine", Vector2i(36, 26), 0)  # Kachel (18, 13), westlich der Ader
	assert_not_null(mine, "Mine: %s" % SimConstruction.can_place(world, player, "mine", Vector2i(36, 26), 0))
	player.pos = Vector2(19.5, 14.5)
	world.logout(player.id, rules, "Bergmann")
	player.logout_time = -1e9
	world.advance(60.0)
	assert_gte(int(player.inventory.get("iron_ore", 0)), 2, "mit Mine: %s" % [player.inventory])
	# Fremde Mine zählt nicht
	var stranger := world.spawn_player(Vector2(21.5, 13.5), "p2", "Fremder")
	assert_false(world.node_offline_ok(world.map.node_at(Vector2i(20, 13)), "p2"))
	assert_true(world.node_offline_ok(world.map.node_at(Vector2i(19, 13)), "p1"))
	assert_eq(stranger.owner_id, "p2")


func test_iron_needs_coal_axe_breaks_stone_wall_armor_slows() -> void:
	player.inventory["iron_ore"] = 6
	world.spawn_building("furnace", Vector2i(19, 6), "p1")
	world.spawn_building("forge", Vector2i(21, 6), "p1")
	assert_eq(SimCrafting.craft(world, player, "iron"), "zu wenig Kohle (1 nötig)", "Kohle ist der Engpass")
	player.inventory["coal"] = 3
	for i in 3:
		assert_eq(SimCrafting.craft(world, player, "iron"), "")
	assert_eq(int(player.inventory["iron"]), 3)
	player.inventory["wood"] = 10
	player.inventory["stone"] = 12
	assert_eq(SimCrafting.craft(world, player, "club"), "")
	assert_eq(SimCrafting.craft(world, player, "iron_axe"), "")
	var wall := SimConstruction.place_building(world, player, "stone_wall", Vector2i(44, 10), 0)
	assert_not_null(wall)
	player.pos = Vector2(21.3, 5.6)  # in Schlagweite der Wand (Halbzellen ab x = 22)
	player.facing = Vector2.RIGHT
	var intent := SimIntent.new()
	intent.melee = true
	SimCrafting.set_active_weapon(world, player, "club")
	world.set_intent(player.id, intent)
	world.tick()
	assert_almost_eq(wall.hp, wall.max_hp, 0.01, "Keule kann Stein nicht brechen (nur Verfall)")
	var too_hard := false
	for event: Dictionary in world.events:
		if event.get("type") == "too_hard":
			too_hard = true
	assert_true(too_hard)
	player.bite_cooldown = 0.0
	SimCrafting.set_active_weapon(world, player, "iron_axe")
	world.set_intent(player.id, intent)
	world.tick()
	assert_lt(wall.hp, wall.max_hp, "Eisenaxt bricht Stein")
	# Schwere Rüstung
	player.inventory["iron"] = 5
	player.inventory["cloth"] = 2
	assert_eq(SimCrafting.craft(world, player, "iron_armor"), "")
	assert_eq(player.armor_slow, 0.0, "nicht angelegt: kein Gewicht")
	assert_eq(SimCrafting.equip_armor(world, player, "iron_armor"), "")
	assert_eq(player.armor, data.balf("character.armor") + 5.0)
	assert_almost_eq(player.armor_slow, 0.15, 0.001)
	player.pos = Vector2(10.5, 5.5)
	var start := player.pos
	var walk := SimIntent.new()
	walk.move = Vector2.RIGHT
	for i in 20:
		world.set_intent(player.id, walk)
		world.tick()
	var slow_distance := player.pos.distance_to(start)
	SimCrafting.wear(world, player, "iron_armor", 1000.0)
	assert_eq(player.armor_slow, 0.0, "ohne Rüstung wieder flott")
	player.pos = start
	for i in 20:
		world.set_intent(player.id, walk)
		world.tick()
	assert_almost_eq(slow_distance / player.pos.distance_to(start), 0.85, 0.02, "15 % langsamer")
