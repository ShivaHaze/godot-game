extends GutTest
## Neutraler Markt: kampffreie Zone auf der Karte, Depot mit Gebühr (Senke), Ort für alle, sicher für Offline-Charaktere.

const MARKET_CENTER: Vector2 = Vector2(26.5, 25.5)   # Depot auf Kachel (26, 25), Markt 24..28 × 23..27
const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 131)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _depot() -> SimBuilding:
	for b: SimBuilding in SimTrade.depots(world):
		if world.map.zone(SimMap.cell_of(b.center())) == "market":
			return b
	assert_true(false, "Markt-Depot auf der Handkarte")
	return null


func test_market_zone_blocks_damage_building_and_claims() -> void:
	assert_eq(world.map.zone(Vector2i(24, 23)), "market")
	assert_eq(world.map.zone(Vector2i(20, 5)), "")
	var depot := _depot()
	assert_eq(depot.label, "Markt-Depot 1")
	assert_eq(SimMap.cell_of(depot.center()), Vector2i(26, 25))
	player.pos = Vector2(24.5, 24.5)
	var victim := world.spawn_player(Vector2(25.3, 24.5), "p2", "Opfer")
	world.spatial.rebuild(world.characters)
	SimCombat.apply_damage(world, victim, 50.0, Vector2.RIGHT, player.id)
	assert_eq(victim.hp, victim.max_hp, "kein Schaden auf dem Markt")
	# Schütze außerhalb, Opfer innen: Projektil verpufft an der Marktgrenze
	player.pos = Vector2(21.5, 24.5)
	player.facing = Vector2.RIGHT
	player.fire_cooldown = 0.0
	var intent := SimIntent.new()
	intent.shoot = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(world.projectiles.size(), 1)
	world.advance(1.5)
	assert_eq(victim.hp, victim.max_hp, "Projektil verpufft am Markt")
	assert_eq(world.projectiles.size(), 0)
	# Bauen und Beanspruchen sind verboten
	player.pos = Vector2(24.5, 24.5)
	player.inventory["wood"] = 30
	assert_eq(SimConstruction.can_place(world, player, "wood_wall", Vector2i(50, 48), 0), "auf dem Markt wird nicht gebaut")
	assert_eq(SimConstruction.can_place(world, player, "depot", Vector2i(50, 48), 0), "nicht baubar")
	SimConstruction.damage_building(world, depot, 5000.0, player.id)
	assert_true(world.map.buildings.has(depot.id), "unzerstörbar")
	player.pos = Vector2(23.5, 26.5)
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(46, 50), 0)  # Kachel (23, 25) neben dem Markt
	assert_not_null(anchor, "Anker: %s" % SimConstruction.can_place(world, player, "anchor", Vector2i(46, 50), 0))
	assert_eq(world.claims.claim_tile_reason(world, player, Vector2i(23, 24)), "")
	assert_eq(world.claims.claim_tile_reason(world, player, Vector2i(24, 25)), "Marktland gehört niemandem")


func test_wolves_ignore_prey_on_the_market() -> void:
	var wolf := world.spawn_wolf(Vector2(22.5, 25.5))
	player.pos = Vector2(24.5, 25.5)
	world.spatial.rebuild(world.characters)
	assert_null(WolfAI.nearest_prey(world, wolf, 8.0), "auf dem Markt keine Beute")
	player.pos = Vector2(22.5, 23.5)
	world.spatial.rebuild(world.characters)
	assert_eq(WolfAI.nearest_prey(world, wolf, 8.0), player)


func test_depot_fee_capacity_and_withdraw() -> void:
	var depot := _depot()
	player.pos = Vector2(25.5, 25.5)
	player.inventory["berries"] = 10
	assert_eq(SimTrade.depot_deposit(world, player, depot, "berries", 10), "")
	assert_eq(int(player.inventory["berries"]), 0)
	assert_eq(int(SimTrade.depot_stock(world, depot, "p1")["berries"]), 8, "20 % Gebühr")
	player.inventory["wood"] = 1
	assert_eq(SimTrade.depot_deposit(world, player, depot, "wood", 1), "zu wenig, die Gebühr frisst alles")
	assert_eq(SimTrade.depot_withdraw(world, player, depot, "berries", 3), "")
	assert_eq(int(player.inventory["berries"]), 3)
	assert_eq(int(SimTrade.depot_stock(world, depot, "p1")["berries"]), 5)
	assert_eq(SimTrade.depot_withdraw(world, player, depot, "stone", 1), "nichts im Depot")
	# Kapazität je Besitzer
	var capacity := data.bali("market.depot_capacity")
	depot.stores["p1"]["wood"] = capacity - 4 - 5  # plus 5 Beeren = 4 frei
	player.inventory["wood"] = 20
	assert_eq(SimTrade.depot_deposit(world, player, depot, "wood", 20), "")
	assert_eq(SimTrade.depot_stock_count(world, depot, "p1"), capacity, "bis zur Kappe gefüllt")
	assert_eq(int(player.inventory["wood"]), 15, "nur 5 abgegeben (4 behalten + 1 Gebühr)")
	assert_eq(SimTrade.depot_deposit(world, player, depot, "wood", 5), "Depot voll (%d)" % capacity)
	# Fremde haben ihren eigenen Bestand; weit weg geht nichts
	var stranger := world.spawn_player(Vector2(25.5, 24.5), "p2", "Fremder")
	assert_true(SimTrade.depot_stock(world, depot, "p2").is_empty())
	stranger.pos = OPEN
	assert_eq(SimTrade.depot_deposit(world, stranger, depot, "berries", 1), "zu weit weg")
	world.logout(player.id, data.roles["hide"]["rules"])
	assert_eq(SimTrade.depot_withdraw(world, player, depot, "berries", 1), "nur live")


func test_npc_delivers_to_depot_and_is_safe_there() -> void:
	var depot := _depot()
	player.pos = Vector2(22.5, 23.5)
	player.inventory["berries"] = 10
	assert_true(player.extra_places.has("b%d" % depot.id), "Depot ist ein Ort für alle")
	assert_eq(player.marker_name("b%d" % depot.id), "Markt-Depot 1")
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "berries", "place": "b%d" % depot.id, "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Händler")
	player.logout_time = -1e9
	for i in 20 * 10:
		world.tick()
	assert_eq(int(player.inventory["berries"]), 0, "abgeliefert")
	assert_eq(int(SimTrade.depot_stock(world, depot, "p1").get("berries", 0)), 8, "Gebühr auch für NPC-Lieferungen")
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("sonst, Regel 1: geliefert: Beeren zu Markt-Depot 1 (10 Beeren)"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
	assert_true(world.in_market(player.pos), "bleibt auf dem Markt")
	var raider := world.spawn_player(player.pos + Vector2(0.8, 0), "p3", "Räuber")
	raider.inventory["wood"] = 3
	SimCrafting.craft(world, raider, "club")
	SimCrafting.set_active_weapon(world, raider, "club")
	world.spatial.rebuild(world.characters)
	var intent := SimIntent.new()
	intent.melee = true
	raider.facing = Vector2.LEFT
	for i in 5:
		raider.bite_cooldown = 0.0
		world.set_intent(raider.id, intent)
		world.tick()
	assert_eq(player.hp, player.max_hp, "Offline-Charakter auf dem Markt ist sicher")


func test_depot_stock_in_save_and_only_own_stock_in_snapshot() -> void:
	var depot := _depot()
	player.pos = Vector2(25.5, 25.5)
	player.inventory["berries"] = 10
	SimTrade.depot_deposit(world, player, depot, "berries", 10)
	var stranger := world.spawn_player(Vector2(25.5, 24.5), "p2", "Fremder")
	stranger.inventory["wood"] = 10
	SimTrade.depot_deposit(world, stranger, depot, "wood", 10)
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_eq(int(SimTrade.depot_stock(copy, copy.map.buildings[depot.id], "p1")["berries"]), 8, "Spielstand")
	assert_eq(int(SimTrade.depot_stock(copy, copy.map.buildings[depot.id], "p2")["wood"]), 8)
	world.tick()
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(NetProtocol.snapshot(world, stranger.id, {}, {}, {}))))
	var seen: SimBuilding = mirror.map.buildings[depot.id]
	assert_eq(int(SimTrade.depot_stock(mirror, seen, "p2").get("wood", 0)), 8, "eigener Bestand im Spiegel")
	assert_false(SimTrade.depot_stock(mirror, seen, "p2").has("berries"), "fremder Bestand bleibt geheim")
	assert_true(seen.stores.is_empty())


func test_map_generator_places_markets_with_depots() -> void:
	var gen := SimData.load_from_dir("res://data")
	var problems := gen.apply_map(MapGen.generate(120, 90, 7))
	assert_true(problems.is_empty(), "Karte gültig: %s" % [problems])
	var markets := 0
	for cell: Vector2i in gen.depot_spawns:
		if gen.map_tile_ids[cell.y * gen.map_width + cell.x] != "market":
			continue  # der Räuber-Outpost hat sein eigenes Depot
		markets += 1
		assert_eq(gen.map_tile_ids[(cell.y - 2) * gen.map_width + cell.x - 2], "market", "5×5 Marktboden")
	assert_eq(markets, 3, "3 Märkte auf 120×90")
	var big := SimWorld.new(gen, 1)
	big.setup_new_game()
	assert_eq(SimTrade.depots(big).size(), 4, "3 Markt-Depots und 1 Outpost-Depot")
