extends GutTest
## Kupferkette: Kupfererz am Kartenrand (offline sammelbar) → Kupfer (Holz als Brennstoff) → Draht → Sensoren; Kupferspeer als Waffe Stufe 1.

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 161)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_copper_veins_sit_at_the_map_edge() -> void:
	var veins := 0
	for node: SimResourceNode in world.map.nodes.values():
		if node.resource != "copper_ore":
			continue
		veins += 1
		var edge_distance := mini(mini(node.cell.x, node.cell.y), mini(world.map.width - 1 - node.cell.x, world.map.height - 1 - node.cell.y))
		assert_lte(edge_distance, 2, "Handkarte: Ader %s am Rand" % node.cell)
	assert_gte(veins, 6)
	var gen := SimData.load_from_dir("res://data")
	assert_true(gen.apply_map(MapGen.generate(120, 90, 7)).is_empty())
	var big := SimWorld.new(gen, 1)
	var generated := 0
	for node: SimResourceNode in big.map.nodes.values():
		if node.resource != "copper_ore":
			continue
		generated += 1
		var fx := float(mini(node.cell.x, big.map.width - 1 - node.cell.x)) / float(big.map.width)
		var fy := float(mini(node.cell.y, big.map.height - 1 - node.cell.y)) / float(big.map.height)
		assert_lte(minf(fx, fy), 0.2, "Generator: Ader %s im äußeren Ring" % node.cell)
	assert_gte(generated, 4, "Generator setzt Kupferadern")


func test_gather_ore_offline_smelt_and_draw_wire() -> void:
	player.pos = Vector2(2.5, 10.5)  # neben den Adern (1, 10) und (1, 11)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "copper_ore", "place": "here", "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Bergmann")
	player.logout_time = -1e9
	world.advance(120.0)
	assert_gte(int(player.inventory.get("copper_ore", 0)), 4, "Erz offline gesammelt: %s" % [player.inventory])
	world.login(player.id)
	world.spawn_building("furnace", Vector2i(3, 10), "p1")  # Schmelzofen neben dem Bergmann
	world.spawn_building("workbench", Vector2i(2, 11), "p1")
	player.inventory["copper_ore"] = 4
	player.inventory["wood"] = 0
	assert_eq(SimCrafting.craft(world, player, "copper"), "zu wenig Holz (1 nötig)", "Schmelzen braucht Brennstoff")
	player.inventory["wood"] = 2
	assert_eq(SimCrafting.craft(world, player, "copper"), "")
	assert_eq(SimCrafting.craft(world, player, "copper"), "")
	assert_eq(int(player.inventory["copper"]), 2)
	assert_eq(int(player.inventory["copper_ore"]), 0)
	assert_eq(SimCrafting.craft(world, player, "wire"), "")
	assert_eq(int(player.inventory["wire"]), 2, "2 Draht je Kupfer")
	player.pos = Vector2(20.5, 5.5)
	player.inventory["wood"] = 10
	assert_eq(SimConstruction.can_place(world, player, "sensor", Vector2i(44, 10), 0), "")
	player.inventory["wire"] = 0
	assert_eq(SimConstruction.can_place(world, player, "sensor", Vector2i(44, 10), 0), "zu wenig Draht (1 nötig)", "Sensoren brauchen Draht")


func test_copper_spear_is_a_reach_blade() -> void:
	player.pos = Vector2(20.5, 5.5)
	player.inventory["copper"] = 2
	player.inventory["wood"] = 3
	world.spawn_building("workbench", Vector2i(20, 6), "p1")  # Station in Reichweite
	assert_eq(SimCrafting.craft(world, player, "copper_spear"), "")
	assert_true(SimCrafting.set_active_weapon(world, player, "copper_spear"))
	assert_eq(player.melee_range, 1.6, "Speer reicht weiter als Keule und Beil")
	assert_eq(player.melee_effect, "bleeding", "Klinge")
	var victim := world.spawn_player(player.pos + Vector2(1.4, 0), "p2", "Opfer")
	victim.facing = Vector2.LEFT  # schaut den Angreifer an: Fronttreffer, überlebt
	world.spatial.rebuild(world.characters)
	player.facing = Vector2.RIGHT
	var intent := SimIntent.new()
	intent.melee = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_lt(victim.hp, victim.max_hp, "trifft auf 1,4 Kacheln")
	assert_true(SimEffects.has_effect(world, victim, "bleeding"))
