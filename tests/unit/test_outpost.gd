extends GutTest
## Räuber-Outpost: Zone ohne Kampfverbot, Depot mit niedriger Gebühr, Raidwaren erlaubt; Zonen kommen aus balance.json.

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 211)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _depot_in(zone: String) -> SimBuilding:
	for b: SimBuilding in world.depots():
		if world.map.zone(SimMap.cell_of(b.center())) == zone:
			return b
	return null


func _outpost_depot() -> SimBuilding:
	return _depot_in("outpost")


func test_outpost_zone_no_peace_no_building() -> void:
	assert_eq(world.map.zone(Vector2i(12, 19)), "outpost")
	var depot := _outpost_depot()
	assert_not_null(depot)
	assert_eq(depot.label, "Outpost-Depot 1")
	assert_eq(world.depots().size(), 2, "Markt- und Outpost-Depot")
	assert_eq(_depot_in("market").label, "Markt-Depot 1", "Zählung je Zone")
	assert_false(world.in_market(depot.center()))
	assert_false(world.in_peace_zone(depot.center()), "kein Kampfverbot")
	assert_true(world.in_peace_zone(Vector2(24.5, 24.5)), "Markt bleibt friedlich")
	player.pos = Vector2(12.5, 20.5)
	var victim := world.spawn_player(Vector2(13.3, 20.5), "p2", "Opfer")
	world.spatial.rebuild(world.characters)
	world.apply_damage(victim, 10.0, Vector2.RIGHT, player.id)
	assert_lt(victim.hp, victim.max_hp, "im Outpost gibt es Schaden")
	player.inventory["wood"] = 10
	assert_eq(world.can_place(player, "wood_wall", Vector2i(26, 40), 0), "im Räuber-Outpost wird nicht gebaut")
	assert_eq(world.claims.claim_tile_reason(world, player, Vector2i(13, 20)), "du brauchst einen stehenden Anker")


func test_outpost_depot_low_fee_and_raid_goods() -> void:
	var depot := _outpost_depot()
	player.pos = depot.center() + Vector2(-1.2, 0)
	player.inventory["powder"] = 20
	player.inventory["berries"] = 20
	assert_almost_eq(world.depot_fee_of(depot), 0.05, 0.001)
	assert_eq(world.depot_deposit(player, depot, "powder", 20), "", "Raidwaren erlaubt")
	assert_eq(int(world.depot_stock(depot, "p1")["powder"]), 19, "5 % Gebühr")
	assert_eq(world.depot_deposit(player, depot, "berries", 20), "")
	assert_eq(int(world.depot_stock(depot, "p1")["berries"]), 19)
	var market := _depot_in("market")
	assert_almost_eq(world.depot_fee_of(market), 0.2, 0.001)
	player.pos = market.center() + Vector2(-1.2, 0)
	player.inventory["powder"] = 2
	assert_eq(world.depot_deposit(player, market, "powder", 2), "Raidware: am neutralen Markt nicht handelbar")


func test_generator_places_one_outpost_far_from_markets() -> void:
	var gen := SimData.load_from_dir("res://data")
	assert_true(gen.apply_map(MapGen.generate(120, 90, 7)).is_empty())
	var big := SimWorld.new(gen, 1)
	big.setup_new_game()
	var outposts := 0
	var markets: Array[Vector2] = []
	var outpost_pos := Vector2.ZERO
	for b: SimBuilding in big.depots():
		if big.map.zone(SimMap.cell_of(b.center())) == "outpost":
			outposts += 1
			outpost_pos = b.center()
		else:
			markets.append(b.center())
	assert_eq(outposts, 1)
	assert_eq(markets.size(), 3)
	for m: Vector2 in markets:
		assert_gte(m.distance_to(outpost_pos), 20.0, "fern der Märkte")
	assert_eq(big.map.zone(SimMap.cell_of(outpost_pos) + Vector2i(2, 2)), "outpost", "5×5 Outpost-Boden")
