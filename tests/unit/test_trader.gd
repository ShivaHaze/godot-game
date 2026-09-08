extends GutTest
## Rolle Händler und symbolische Orte: 'eigener Handelstisch', 'eigener Anker', 'nächstes Depot' werden beim Ausloggen
## aufgelöst; der Händler sammelt Beeren und liefert volle Ladungen zum Tisch, sonst zum Depot (quer über die Karte).

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 471)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_symbolic_places_resolve_from_the_world() -> void:
	assert_eq(player.marker_name("nearest_depot"), "nächstes Depot")
	assert_eq(player.marker_name("own_table"), "eigener Handelstisch")
	world.refresh_places("p1")
	assert_true(player.extra_places.has("nearest_depot"), "Depots gibt es auf jeder Karte")
	assert_false(player.extra_places.has("own_table"), "noch kein Tisch")
	assert_false(player.extra_places.has("own_anchor"), "noch kein Anker")
	var depot_pos: Vector2 = player.extra_places["nearest_depot"]["pos"]
	assert_almost_eq(depot_pos.x, 14.5, 0.6, "das Outpost-Depot bei (14, 21) liegt dem Spawn-Umfeld am nächsten (Markt bei (26, 25) ist weiter)")
	var market_pos: Vector2 = player.extra_places["nearest_market"]["pos"]
	assert_almost_eq(market_pos.x, 26.5, 0.6, "nächster Markt = Depot in der kampffreien Zone")
	player.inventory["wood"] = 30
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	player.pos = Vector2(18.5, 5.5)
	var table := SimConstruction.place_building(world, player, "trade_table", Vector2i(34, 10), 0)
	assert_not_null(anchor)
	assert_not_null(table)
	assert_eq(player.extra_places["own_anchor"]["pos"], anchor.center())
	assert_eq(player.extra_places["own_table"]["pos"], table.center())
	# Der Editor bietet die symbolischen Orte immer an
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "berries", "place": "own_table", "radius": 3}}},
	], "Test")
	assert_true(data.errors.is_empty(), "%s" % [data.errors])
	assert_eq(SimChronicle.rule_text(data, player, 0, rules[0]), "sonst, Regel 1: geliefert: Beeren zu eigener Handelstisch")


func test_missing_symbolic_place_is_a_reason() -> void:
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "berries", "place": "own_table", "radius": 3}}},
	], "Test")
	player.inventory["berries"] = 3
	world.logout(player.id, rules, "Händler")
	player.logout_time = -1e9
	assert_eq(NpcController.blocked_reason(world, player, rules[0]), "kein eigener Handelstisch")
	for i in 10:
		world.tick()
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("nicht möglich: kein eigener Handelstisch, übersprungen"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])


func test_trader_preset_walks_full_load_to_the_depot_and_back() -> void:
	var role: Dictionary = data.roles["trader"]
	assert_eq(role["rules"].size(), 5)
	assert_eq(String(role["rules"][0]["then"]["action"]), "fight_back", "gegen Wölfe hilft nur Zurückkämpfen")
	player.pos = Vector2(11.5, 6.5)  # neben den Beerenbüschen (11, 7) und (11, 8)
	player.inventory["berries"] = data.bali("inventory.capacity") - 1
	world.logout(player.id, role["rules"], String(role["name"]))
	player.logout_time = -1e9
	world.advance(2.0)
	assert_eq(player.inventory_count(), data.bali("inventory.capacity"), "voll gesammelt, bricht auf")
	world.advance(60.0)
	var depot := SimEvents.depot_in_zone(world, "market")
	var stock := SimTrade.depot_stock(world, depot, "p1")
	assert_gt(int(stock.get("berries", 0)), 0, "Beeren im Depot (abzüglich Gebühr): %s · Position %s · Chronik %s" % [stock, player.pos, SimChronicle.format_all(player)])
	assert_lt(int(stock.get("berries", 0)), data.bali("inventory.capacity"), "Gebühr abgezogen")
	var lines := SimChronicle.format_all(player)
	var delivered := false
	for line: String in lines:
		if line.contains("geliefert: Beeren zu nächster Markt"):
			delivered = true
	assert_true(delivered, "Chronik: %s" % [lines])
	world.advance(60.0)
	assert_lt(player.pos.distance_to(Vector2(11.5, 6.5)), 9.0, "wieder beim Sammeln um Hier")


func test_trader_prefers_own_table() -> void:
	var role: Dictionary = data.roles["trader"]
	player.inventory["wood"] = 8
	player.pos = Vector2(13.5, 6.5)
	var table := SimConstruction.place_building(world, player, "trade_table", Vector2i(28, 12), 0)  # Kachel (14, 6)
	assert_not_null(table, "Tisch: %s" % SimConstruction.can_place(world, player, "trade_table", Vector2i(28, 12), 0))
	player.pos = Vector2(11.5, 6.5)
	player.inventory["berries"] = data.bali("inventory.capacity")
	world.logout(player.id, role["rules"], String(role["name"]))
	player.logout_time = -1e9
	world.advance(30.0)
	assert_gt(int(table.contents.get("berries", 0)), 0, "Beeren im eigenen Tisch: %s" % [table.contents])
	assert_eq(int(SimTrade.depot_stock(world, SimEvents.depot_in_zone(world, "market"), "p1").get("berries", 0)), 0, "nicht zum Markt gelaufen")
