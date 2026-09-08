extends GutTest
## Handelstisch: Lager, Angebote, Kauf, Rechte, Zerstörung = Beute, Spielstand, Snapshot.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var seller: SimCharacter
var buyer: SimCharacter
var table: SimBuilding


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 51)
	world.lod_enabled = false
	seller = world.get_character(world.setup_new_game())
	seller.pos = Vector2(21.4, 5.5)  # dicht am Tisch (Kachel 22, 5)
	seller.inventory["wood"] = 20
	seller.inventory["berries"] = 10
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE
	table = SimConstruction.place_building(world, seller, "trade_table", Vector2i(44, 10), 0)  # Kachel (22, 5), 2×1 Halbzellen
	assert_not_null(table)
	buyer = world.spawn_player(Vector2(23.5, 5.5), "p2", "Kunde")
	buyer.inventory["wood"] = 5


func test_owner_stocks_and_sets_offers() -> void:
	assert_true(SimTrade.is_trade_table(world, table))
	assert_eq(SimTrade.trade_table_near(world, seller), table)
	assert_eq(SimTrade.table_deposit(world, seller, table, "berries", 6), "")
	assert_eq(int(table.contents["berries"]), 6)
	assert_eq(int(seller.inventory["berries"]), 4)
	assert_eq(SimTrade.table_withdraw(world, seller, table, "berries", 2), "")
	assert_eq(int(table.contents["berries"]), 4)
	assert_eq(SimTrade.table_set_offers(world, seller, table, [{"sell": "berries", "sell_amount": 2, "price": "wood", "price_amount": 1}]), "")
	assert_eq(table.offers.size(), 1)
	assert_eq(SimTrade.table_set_offers(world, seller, table, [{"sell": "berries", "sell_amount": 2, "price": "berries", "price_amount": 1}]), "ungültiges Angebot")
	assert_eq(SimTrade.table_set_offers(world, seller, table, [{}, {}, {}, {}]), "höchstens 3 Angebote")
	assert_eq(SimTrade.table_deposit(world, buyer, table, "wood", 1), "nicht dein Tisch")
	assert_eq(SimTrade.table_set_offers(world, buyer, table, []), "nicht dein Tisch")


func test_buyer_trades_and_reasons() -> void:
	SimTrade.table_deposit(world, seller, table, "berries", 6)
	SimTrade.table_set_offers(world, seller, table, [{"sell": "berries", "sell_amount": 2, "price": "wood", "price_amount": 1}])
	assert_eq(SimTrade.table_buy(world, buyer, table, 0), "")
	assert_eq(int(buyer.inventory["berries"]), 2)
	assert_eq(int(buyer.inventory["wood"]), 4)
	assert_eq(int(table.contents["berries"]), 4)
	assert_eq(int(table.contents["wood"]), 1, "Bezahlung liegt im Tisch")
	assert_eq(SimTrade.table_buy(world, buyer, table, 1), "kein solches Angebot")
	buyer.inventory["wood"] = 0
	assert_eq(SimTrade.table_buy(world, buyer, table, 0), "zu wenig Holz (1 nötig)")
	buyer.inventory["wood"] = 9
	SimTrade.table_buy(world, buyer, table, 0)
	SimTrade.table_buy(world, buyer, table, 0)
	assert_eq(SimTrade.table_buy(world, buyer, table, 0), "ausverkauft")
	buyer.pos = Vector2(30.5, 5.5)
	assert_eq(SimTrade.table_buy(world, buyer, table, 0), "zu weit weg")
	world.logout(buyer.id, data.roles["guard"]["rules"])
	assert_eq(SimTrade.table_buy(world, buyer, table, 0), "nur live", "Handel nur live")


func test_destroyed_table_yields_contents_to_attacker() -> void:
	SimTrade.table_deposit(world, seller, table, "berries", 6)
	SimTrade.table_deposit(world, seller, table, "wood", 4)
	buyer.inventory["wood"] = 3
	SimCrafting.craft(world, buyer, "club")
	SimCrafting.set_active_weapon(world, buyer, "club")
	buyer.pos = Vector2(23.4, 5.25)
	var intent := SimIntent.new()
	intent.aim = Vector2.LEFT
	intent.shoot = true
	var looted := {}
	for i in 60:
		world.set_intent(buyer.id, intent)
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "loot" and event.get("table", -1) == table.id:
				looted = event["items"]
	assert_false(world.map.buildings.has(table.id), "Tisch zerstört")
	assert_eq(int(looted.get("berries", 0)), 6, "Shop ist auch Ziel: Inhalt fällt dem Zerstörer zu")
	assert_eq(int(buyer.inventory["berries"]), 6)


func test_save_and_snapshot_carry_table_state() -> void:
	SimTrade.table_deposit(world, seller, table, "berries", 3)
	SimTrade.table_set_offers(world, seller, table, [{"sell": "berries", "sell_amount": 1, "price": "wood", "price_amount": 2}])
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	var loaded: SimBuilding = copy.map.buildings[table.id]
	assert_eq(int(loaded.contents["berries"]), 3)
	assert_eq(loaded.offers.size(), 1)
	assert_eq(int(loaded.offers[0]["price_amount"]), 2)
	var known := {}
	var nodes := {}
	var state := {}
	world.tick()
	var snap := NetProtocol.snapshot(world, buyer.id, known, nodes, state)
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	assert_eq(int(mirror.map.buildings[table.id].contents["berries"]), 3)
	assert_eq(mirror.map.buildings[table.id].offers.size(), 1)
	assert_false(NetProtocol.snapshot(world, buyer.id, known, nodes, state).has("bld"), "unverändert")
	SimTrade.table_buy(world, buyer, table, 0)
	assert_true(NetProtocol.snapshot(world, buyer.id, known, nodes, state).has("bld"), "Kauf ändert den Tisch")
