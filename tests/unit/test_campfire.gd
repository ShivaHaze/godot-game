extends GutTest
## Nahrung → gekocht: Wölfe geben Fleisch, das Lagerfeuer brät es (nahrhafter), Essen nimmt das beste Stück.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 231)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_wolf_corpse_gives_meat() -> void:
	var wolf := world.spawn_wolf(OPEN + Vector2(0.8, 0))
	wolf.control = SimCharacter.Controller.NONE
	assert_eq(int(wolf.inventory["meat"]), data.bali("wolf.meat"))
	world.apply_damage(wolf, 1000.0, Vector2.RIGHT, player.id)
	assert_true(wolf.dead)
	world.spatial.rebuild(world.characters)
	var intent := SimIntent.new()
	intent.interact = true
	for i in 20:
		world.set_intent(player.id, intent)
		world.tick()
	assert_eq(int(player.inventory.get("meat", 0)), data.bali("wolf.meat"), "Fleisch geplündert")


func test_cooking_needs_campfire_and_is_better_food() -> void:
	player.inventory["meat"] = 2
	player.inventory["wood"] = 4
	assert_eq(world.craft(player, "cooked_meat"), "kein Lagerfeuer in Reichweite")
	var fire := world.place_building(player, "campfire", Vector2i(43, 11), 0)
	assert_not_null(fire, "Feuer: %s" % world.can_place(player, "campfire", Vector2i(43, 11), 0))
	assert_eq(world.craft(player, "cooked_meat"), "")
	assert_eq(int(player.inventory["cooked_meat"]), 1)
	assert_eq(int(player.inventory["meat"]), 1)
	# Essen nimmt das nahrhafteste Stück
	player.inventory["berries"] = 3
	player.hunger = 20.0
	var event := world.eat(player)
	assert_eq(event["resource"], "cooked_meat", "gebraten vor Beeren und rohem Fleisch")
	assert_almost_eq(player.hunger, 70.0, 0.01, "+50")
	event = world.eat(player)
	assert_eq(event["resource"], "berries", "Beeren (25) vor rohem Fleisch (15)")
	# Das Feuer brennt herunter
	assert_true(world.map.buildings.has(fire.id))
	world.advance(3.5 * 3600.0)
	assert_false(world.map.buildings.has(fire.id), "nach ~3 h erloschen")
	assert_eq(world.craft(player, "cooked_meat"), "kein Lagerfeuer in Reichweite")


func test_npc_cooks_at_a_fire_and_eats_when_hungry() -> void:
	player.inventory["meat"] = 3
	player.inventory["wood"] = 4
	world.unlock("p1", "crafted_consumable", player)
	var fire := world.place_building(player, "campfire", Vector2i(43, 11), 0)
	assert_not_null(fire)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "hungry"}, "then": {"action": "eat"}},
		{"if": {"condition": "else"}, "then": {"action": "craft", "params": {"product": "cooked_meat"}}},
	], "Test")
	world.logout(player.id, rules, "Koch")
	player.logout_time = -1e9
	for i in 20 * 3:
		world.tick()
	assert_eq(int(player.inventory.get("cooked_meat", 0)), 3, "alles gebraten")
	player.hunger = 10.0
	for i in 20 * 2:
		world.tick()
	assert_eq(int(player.inventory["cooked_meat"]), 2, "hungrig: gebratenes Fleisch gegessen")
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("hungrig, Regel 1: gegessen (Gebratenes Fleisch 3→2)"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
