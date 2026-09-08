extends GutTest
## Ereignis Karawane: Händler mit Kasse, Wachen und Lasttiere ziehen zwischen Markt und Outpost, rasten und handeln in
## Kupfer (kaufen Waren, verkaufen die Fracht mit Aufschlag); ein Überfall lohnt, aber die Wachen verteidigen.

const OPEN: Vector2 = Vector2(20.5, 5.5)
const MARKET_DEPOT: Vector2 = Vector2(26.5, 25.5)
const OUTPOST_DEPOT: Vector2 = Vector2(14.5, 21.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 481)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _spawn() -> Dictionary:
	var id := SimEvents.spawn_caravan(world)
	assert_gte(id, 0, "Karawane erscheint")
	world.spatial.rebuild(world.characters)
	return world.caravans[id]


func _members(caravan: Dictionary, role: String) -> Array[SimCharacter]:
	var result: Array[SimCharacter] = []
	for id: int in caravan["members"]:
		var c := world.get_character(id)
		if c != null and c.caravan_role == role:
			result.append(c)
	return result


func _run(seconds: float, kind: String) -> Array:
	var collected := []
	for i in int(seconds * 20.0):
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == kind:
				collected.append(event)
	return collected


func test_caravan_spawns_at_the_market_and_rests_first() -> void:
	assert_almost_eq(world.next_caravan_time, data.balf("events.caravan.first_after_hours") * 3600.0, 0.001)
	world.next_caravan_time = world.time + 1.0
	var spawned := _run(2.0, "caravan_spawned")
	assert_eq(spawned.size(), 1, "eine Karawane")
	assert_eq(world.caravans.size(), 1)
	var caravan: Dictionary = world.caravans.values()[0]
	assert_eq(String(caravan["leg"]), "rest", "rastet zuerst am Markt")
	assert_eq(_members(caravan, "trader").size(), 1)
	assert_eq(_members(caravan, "guard").size(), 2)
	assert_eq(_members(caravan, "animal").size(), 2)
	var trader := _members(caravan, "trader")[0]
	assert_eq(trader.kind, SimCharacter.Kind.CARAVAN)
	assert_eq(trader.control, SimCharacter.Controller.CARAVAN_AI)
	assert_eq(trader.name, "Karawanenhändler")
	assert_eq(int(trader.inventory.get("copper", 0)), data.bali("events.caravan.currency_stock"), "Kasse")
	assert_lt(trader.pos.distance_to(MARKET_DEPOT), 3.0, "am Markt-Depot")
	var guard := _members(caravan, "guard")[0]
	assert_eq(guard.armor, 4.0)
	assert_eq(guard.active_weapon, "bow", "Bogen in der Hand, Speer für die Nähe: %s" % [guard.items])
	assert_true(guard.items.has("copper_spear"))
	assert_eq(int(guard.inventory.get("arrow", 0)), 200)
	assert_eq(world.count_alive_wolves(), 3, "keine Wölfe dazugekommen")
	assert_eq(SimEvents.event_text(spawned[0]), "Eine Karawane rastet am Neutraler Markt und handelt in Kupfer.")


func test_route_market_outpost_market_then_leaves() -> void:
	var caravan := _spawn()
	var trader := _members(caravan, "trader")[0]
	caravan["rest_until"] = world.time + 1.0
	_run(2.0, "")
	assert_eq(String(caravan["leg"]), "travel")
	assert_eq(int(caravan["target"]), SimEvents.depot_in_zone(world, "outpost").id)
	var rests := _run(40.0, "caravan_rest")
	assert_eq(rests.size(), 1, "am Outpost angekommen: %s" % trader.pos)
	assert_lt(trader.pos.distance_to(OUTPOST_DEPOT), 2.5)
	assert_eq(String(rests[0]["zone"]), "Räuber-Outpost")
	for animal: SimCharacter in _members(caravan, "animal"):
		assert_lt(animal.pos.distance_to(trader.pos), 4.0, "Lasttiere folgen")
	for guard: SimCharacter in _members(caravan, "guard"):
		assert_lt(guard.pos.distance_to(trader.pos), 4.0, "Wachen folgen")
	caravan["rest_until"] = world.time + 1.0
	rests = _run(40.0, "caravan_rest")
	assert_eq(rests.size(), 1, "zurück am Markt")
	assert_lt(trader.pos.distance_to(MARKET_DEPOT), 2.5)
	caravan["rest_until"] = world.time + 1.0
	var left := _run(2.0, "caravan_left")
	assert_eq(left.size(), 1, "zieht weiter")
	assert_true(world.caravans.is_empty())
	assert_null(world.get_character(trader.id), "Mitglieder verschwinden")


func test_trade_only_at_rest_in_copper() -> void:
	var caravan := _spawn()
	var trader := _members(caravan, "trader")[0]
	player.pos = trader.pos + Vector2(0.9, 0)
	world.spatial.rebuild(world.characters)
	player.inventory["wood"] = 8
	assert_eq(SimTrade.caravan_sell(world, player, trader, "wood"), "")
	assert_eq(int(player.inventory["wood"]), 4)
	assert_eq(int(player.inventory["copper"]), 1)
	assert_eq(int(trader.inventory["copper"]), data.bali("events.caravan.currency_stock") - 1)
	assert_eq(int(SimTrade.caravan_cargo(world, trader).get("wood", 0)), 4, "Fracht auf einem Lasttier")
	assert_eq(SimTrade.caravan_sell(world, player, trader, "wood"), "")
	assert_eq(int(player.inventory["copper"]), 2)
	# Kaufen zum Aufschlag
	assert_eq(SimTrade.caravan_ask_price(world, "wood"), 2)
	assert_eq(SimTrade.caravan_buy(world, player, trader, "wood"), "")
	assert_eq(int(player.inventory["wood"]), 4)
	assert_eq(int(player.inventory["copper"]), 0)
	assert_eq(int(SimTrade.caravan_cargo(world, trader).get("wood", 0)), 4)
	assert_eq(SimTrade.caravan_buy(world, player, trader, "wood"), "zu wenig Kupfer (2 nötig)")
	# Gründe
	player.inventory["explosive"] = 2
	assert_eq(SimTrade.caravan_sell(world, player, trader, "explosive"), "das handelt die Karawane nicht", "Raidwaren stehen in keiner Preisliste")
	player.inventory["copper"] = 4
	assert_eq(SimTrade.caravan_sell(world, player, trader, "copper"), "das handelt die Karawane nicht")
	assert_eq(SimTrade.caravan_sell(world, player, trader, "berries"), "zu wenig Beeren (4 nötig)")
	trader.inventory["copper"] = 0
	player.inventory["wood"] = 4
	assert_eq(SimTrade.caravan_sell(world, player, trader, "wood"), "die Kasse der Karawane ist leer")
	caravan["leg"] = "travel"
	assert_eq(SimTrade.caravan_sell(world, player, trader, "wood"), "die Karawane handelt nur bei der Rast")
	assert_eq(SimTrade.caravan_trader_near(world, player), trader)


func test_raid_guards_defend_and_cargo_is_loot() -> void:
	var caravan := _spawn()
	var trader := _members(caravan, "trader")[0]
	# Raus aus dem kampffreien Markt: die Karawane steht auf offenem Feld
	var members: Array[SimCharacter] = []
	for id: int in caravan["members"]:
		members.append(world.get_character(id))
	for i in members.size():
		members[i].pos = OPEN + Vector2(2.0 + i, 0)
		members[i].prev_pos = members[i].pos
	caravan["leg"] = "travel"
	caravan["goal"] = OPEN + Vector2(2, 0)
	var animal := _members(caravan, "animal")[0]
	animal.inventory["hide"] = 3
	player.max_hp = 1000.0
	player.hp = 1000.0
	player.facing = Vector2.RIGHT
	world.spatial.rebuild(world.characters)
	_run(0.5, "")
	assert_eq(player.hp, 1000.0, "Wachen greifen nie zuerst an")
	SimCombat.apply_damage(world, animal, 5.0, Vector2.RIGHT, player.id)
	var raided := _run(3.0, "caravan_raided")
	assert_eq(raided.size(), 0, "noch niemand tot")
	assert_lt(player.hp, 1000.0, "die Wachen verteidigen das Lasttier")
	SimCombat.apply_damage(world, animal, 1000.0, Vector2.RIGHT, player.id)
	raided = _run(0.2, "caravan_raided")
	assert_eq(raided.size(), 1, "erstes Mitglied tot: überfallen")
	player.pos = animal.pos + Vector2(0.8, 0)
	world.spatial.rebuild(world.characters)
	var intent := SimIntent.new()
	intent.interact = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(int(player.inventory.get("hide", 0)), 3, "Fracht geplündert: %s" % [player.inventory])
	# Ohne Händler bleibt der Rest stehen und zieht nach linger_minutes ab
	SimCombat.apply_damage(world, trader, 1000.0, Vector2.RIGHT, player.id)
	_run(0.2, "")
	assert_eq(String(caravan["leg"]), "raided")
	caravan["raided_at"] = world.time - data.balf("events.caravan.linger_minutes") * 60.0
	_run(0.2, "")
	assert_true(world.caravans.is_empty())
	assert_not_null(world.get_character(trader.id), "die Leiche des Händlers bleibt (Kasse als Beute)")
	assert_eq(int(trader.inventory.get("copper", 0)), data.bali("events.caravan.currency_stock"))


func test_offline_characters_turrets_and_wolves_leave_the_caravan_alone() -> void:
	var caravan := _spawn()
	for id: int in caravan["members"]:
		var m := world.get_character(id)
		m.pos = OPEN + Vector2(4.0 + (id % 3), 0)
		m.prev_pos = m.pos
		m.control = SimCharacter.Controller.NONE
	caravan["leg"] = "travel"
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "attack", "params": {"radius": 8}}},
	], "Test")
	world.logout(player.id, rules, "Jäger")
	player.logout_time = -1e9
	player.inventory["iron"] = 4
	player.inventory["wood"] = 6
	player.inventory["wire"] = 2
	world.spatial.rebuild(world.characters)
	var shots := _run(2.0, "shoot")
	assert_eq(shots.size(), 0, "'greife an' meidet die Karawane")
	world.login(player.id)
	var turret := SimConstruction.place_building(world, player, "turret", Vector2i(44, 10), 0)
	assert_not_null(turret, "Turret: %s" % SimConstruction.can_place(world, player, "turret", Vector2i(44, 10), 0))
	turret.contents["shot"] = 10
	var turret_shots := _run(2.0, "turret_shot")
	assert_eq(turret_shots.size(), 0, "Turrets verschonen die neutrale Karawane")
	player.pos = Vector2(8.5, 5.5)  # weit weg: der Wolf sieht nur die Karawane
	var wolf := world.spawn_wolf(OPEN + Vector2(6, 1))
	world.spatial.rebuild(world.characters)
	assert_null(WolfAI.nearest_prey(world, wolf, 7.0), "Wölfe jagen keine Karawane")


func test_save_and_snapshot_keep_the_caravan() -> void:
	var caravan := _spawn()
	var trader := _members(caravan, "trader")[0]
	_members(caravan, "animal")[0].inventory["wood"] = 4
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_eq(copy.caravans.size(), 1)
	var loaded: Dictionary = copy.caravans.values()[0]
	assert_eq(String(loaded["leg"]), "rest")
	assert_eq(int(loaded["leader"]), trader.id)
	var loaded_trader := copy.get_character(trader.id)
	assert_eq(loaded_trader.kind, SimCharacter.Kind.CARAVAN)
	assert_eq(loaded_trader.control, SimCharacter.Controller.CARAVAN_AI)
	assert_eq(loaded_trader.caravan_role, "trader")
	assert_eq(int(SimTrade.caravan_cargo(copy, loaded_trader).get("wood", 0)), 4)
	assert_almost_eq(copy.next_caravan_time, world.next_caravan_time, 0.001)
	# Snapshot: der Spiegel kennt Rast, Kasse und Fracht der Karawane in Sicht
	player.pos = trader.pos + Vector2(2, 0)
	var mirror := SimWorld.new(data, 0)
	var snap := NetProtocol.snapshot(world, player.id, {}, {})
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	var seen := mirror.get_character(trader.id)
	assert_not_null(seen)
	assert_eq(seen.caravan_role, "trader")
	assert_true(SimTrade.caravan_resting(mirror, seen))
	assert_eq(SimTrade.caravan_copper(mirror, seen), data.bali("events.caravan.currency_stock"))
	assert_eq(int(SimTrade.caravan_cargo(mirror, seen).get("wood", 0)), 4)
