extends GutTest
## Lieferung per NPC-Aktion 'liefere X zu [Ort]': Anker nimmt Holz (Unterhalt), Handelstisch nimmt Waren.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 81)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.inventory["wood"] = 30
	player.inventory["stone"] = 4
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_anchor_and_table_are_places() -> void:
	assert_true(world.can_use(player, data.action_def("deliver")), "'liefere' ist von Anfang an verfügbar (Markt-Depots gibt es immer)")
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	assert_not_null(anchor)
	assert_eq(player.extra_places["b%d" % anchor.id]["name"], "Anker")
	player.pos = Vector2(18.5, 5.5)
	var table := SimConstruction.place_building(world, player, "trade_table", Vector2i(34, 10), 0)
	assert_not_null(table)
	assert_eq(player.extra_places["b%d" % table.id]["name"], "Handelstisch 1")


func test_npc_delivers_wood_to_anchor_and_logs() -> void:
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	var claim := world.claims.claim_of_owner("p1")
	player.inventory["wood"] = 12
	player.pos = Vector2(16.5, 5.5)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "wood", "place": "b%d" % anchor.id, "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Versorger")
	player.logout_time = -1e9
	for i in 20 * 6:
		world.tick()
	assert_eq(int(player.inventory["wood"]), 0, "alles abgeliefert")
	assert_almost_eq(claim.stock, 12.0, 0.01, "Vorrat am Anker")
	var lines := SimChronicle.format_all(player)
	var found := false
	for line: String in lines:
		if line.contains("sonst, Regel 1: geliefert: Holz zu Anker (12 Holz)"):
			found = true
	assert_true(found, "Chronik: %s" % [lines])
	assert_eq(player.active_rule_index, RuleEngine.NO_MATCH, "danach nichts mehr zu liefern")


func test_gather_and_deliver_loop_keeps_claim_fed() -> void:
	# Anker neben den Bäumen bei (3..5, 14..16): Sammler holt Holz und liefert es ab
	player.pos = Vector2(7.5, 15.5)
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(16, 30), 0)  # Kachel (8, 15)
	assert_not_null(anchor)
	var claim := world.claims.claim_of_owner("p1")
	player.inventory["wood"] = 0
	var rules := data.normalize_rule_list([
		{"if": {"condition": "inventory_state", "params": {"state": "full"}}, "then": {"action": "deliver", "params": {"resource": "wood", "place": "b%d" % anchor.id, "radius": 3}}},
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "wood", "place": "here", "radius": 6}}},
	], "Test")
	world.logout(player.id, rules, "Versorger")
	player.logout_time = -1e9
	world.advance(20 * 60.0)
	assert_gt(claim.stock, 10.0, "Vorrat gefüllt: %s" % claim.stock)
	var deliveries := 0
	for line: String in SimChronicle.format_all(player):
		if line.contains("geliefert"):
			deliveries += 1
	assert_gte(deliveries, 1, "mindestens eine Lieferung protokolliert")


func test_deliver_reasons() -> void:
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	player.inventory["wood"] = 0
	player.inventory["stone"] = 3
	var rules := data.normalize_rule_list([
		{"if": {"condition": "hungry"}, "then": {"action": "deliver", "params": {"resource": "stone", "place": "b%d" % anchor.id, "radius": 3}}},
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "wood", "place": "b%d" % anchor.id, "radius": 3}}},
	], "Test")
	player.hunger = 5.0
	world.logout(player.id, rules)
	player.logout_time = -1e9
	for i in 20:
		world.tick()
	var lines := SimChronicle.format_all(player)
	var stone_reason := false
	var wood_reason := false
	for line: String in lines:
		if line.contains("der Anker nimmt nur Holz"):
			stone_reason = true
		if line.contains("nichts zu liefern"):
			wood_reason = true
	assert_true(stone_reason and wood_reason, "beide Gründe: %s" % [lines])


func test_npc_delivers_berries_to_table() -> void:
	player.pos = Vector2(18.5, 5.5)
	var table := SimConstruction.place_building(world, player, "trade_table", Vector2i(34, 10), 0)  # Kachel (17, 5)
	player.inventory["berries"] = 5
	player.pos = Vector2(22.5, 5.5)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "berries", "place": "b%d" % table.id, "radius": 3}}},
	], "Test")
	world.logout(player.id, rules)
	player.logout_time = -1e9
	for i in 20 * 6:
		world.tick()
	assert_eq(int(table.contents.get("berries", 0)), 5, "Beeren im Tisch")
	assert_eq(int(player.inventory["berries"]), 0)
