extends GutTest
## Gildenlevel aus Offline-Leistung (Regelausführungen), mehr Land je Stufe; Bauteile der Gildenmitglieder als Orte.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter
var mate: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	data.balance["effects"]["sick"]["chance_per_hour"] = 0.0
	world = SimWorld.new(data, 271)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE
	mate = world.spawn_player(Vector2(18.5, 5.5), "p2", "Ben")
	assert_eq(world.guild_command("p1", "found", "Grenzwacht"), "Gilde „Grenzwacht“ gegründet.")
	assert_eq(world.guild_command("p1", "invite", "p2"), "p2 eingeladen (er antwortet mit /gilde annehmen).")
	assert_eq(world.guild_command("p2", "accept", ""), "Willkommen in der Gilde „Grenzwacht“.")


func test_offline_rules_raise_guild_level_and_land() -> void:
	assert_eq(world.guild_level("p1"), 1)
	assert_eq(world.guilds.xp_of("p1"), 0)
	assert_eq(world.claims.max_tiles_for(data, "p1"), data.bali("claim.max_tiles_solo") + data.bali("claim.guild_tiles_per_member"))
	world.guilds.add_xp("p2", data.bali("guild.xp_per_level") * 2)
	assert_eq(world.guild_level("p1"), 3, "gemeinsame Punkte, gemeinsame Stufe")
	assert_eq(world.claims.max_tiles_for(data, "p1"), data.bali("claim.max_tiles_solo") + data.bali("claim.guild_tiles_per_member") * 3)
	assert_eq(world.claims.max_tiles_for(data, "p3"), data.bali("claim.max_tiles_solo"), "Solo unverändert")
	# Ausgeführte Regeln eines Offline-Mitglieds bringen Punkte, übersprungene nicht
	var before := world.guilds.xp_of("p1")
	mate.inventory["berries"] = 3
	mate.hunger = 10.0
	var rules := data.normalize_rule_list([
		{"if": {"condition": "hungry"}, "then": {"action": "eat"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 2}}},
	], "Test")
	world.logout(mate.id, rules, "Wache")
	mate.logout_time = -1e9
	for i in 20:
		world.tick()
	assert_gt(world.guilds.xp_of("p1"), before, "Regelausführungen zählen: %s" % [SimChronicle.format_all(mate)])
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_eq(copy.guilds.xp_of("p2"), world.guilds.xp_of("p1"), "Punkte im Spielstand")
	assert_eq(copy.guild_level("p2"), world.guild_level("p1"))
	var block := NetProtocol.decode(NetProtocol.encode(NetProtocol.self_block_for(world, player)))
	assert_eq(int(block["guild"]["level"]), world.guild_level("p1"))
	var solo := SimWorld.new(data, 1)
	assert_eq(solo.guild_level("p1"), 0, "ohne Gilde keine Stufe")


func test_allied_buildings_are_places() -> void:
	mate.inventory["wood"] = 30
	mate.inventory["stone"] = 4
	mate.inventory["wire"] = 2
	mate.pos = Vector2(16.5, 5.5)
	var anchor := world.place_building(mate, "anchor", Vector2i(36, 10), 0)  # Kachel (18, 5)
	assert_not_null(anchor, "Anker: %s" % world.can_place(mate, "anchor", Vector2i(36, 10), 0))
	var sensor := world.place_building(mate, "sensor", Vector2i(34, 12), 0)
	assert_not_null(sensor)
	assert_eq(player.extra_places["b%d" % anchor.id]["name"], "Anker (p2)", "Anker des Mitglieds als Ort")
	assert_eq(player.extra_places["b%d" % sensor.id]["name"], "Sensor 1 (p2)")
	assert_eq(mate.extra_places["b%d" % anchor.id]["name"], "Anker", "eigener Anker ohne Zusatz")
	# Lieferung in den Gildenanker per Regel
	player.inventory["wood"] = 8
	world.unlock("p1", "owned_container", player)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "deliver", "params": {"resource": "wood", "place": "b%d" % anchor.id, "radius": 4}}},
	], "Test")
	world.logout(player.id, rules, "Versorger")
	player.logout_time = -1e9
	for i in 20 * 6:
		world.tick()
	assert_eq(int(player.inventory["wood"]), 0, "in den Gildenanker geliefert")
	assert_almost_eq(world.claims.claim_of_owner("p2").stock, 8.0, 0.01)
	# Austritt: die Orte verschwinden wieder
	world.login(player.id)
	assert_eq(world.guild_command("p1", "leave", ""), "Du hast „Grenzwacht“ verlassen.")
	assert_false(player.extra_places.has("b%d" % anchor.id), "nach dem Austritt kein Ort mehr")
