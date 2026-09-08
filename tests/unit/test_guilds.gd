extends GutTest
## Gilden (Kern): Verbündete bauen und sammeln auf den Claims der anderen, gehen durch ihre Türen, teilen den Alarm,
## werden von Turrets/Fallen verschont und kennen einander; Spielstand und Snapshot tragen die Gilde.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter
var mate: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 241)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE
	mate = world.spawn_player(OPEN + Vector2(-2, 0), "p2", "Kamerad")
	world.spatial.rebuild(world.characters)


func _found(name: String = "Grenzwacht") -> void:
	assert_eq(world.guilds.found("p1", name), "")
	assert_eq(world.guilds.invite("p1", "p2"), "")
	assert_eq(world.guilds.accept("p2"), "")


func test_guild_lifecycle_and_alliance() -> void:
	assert_false(world.allied("p1", "p2"))
	assert_eq(world.guilds.found("p1", "ab"), "Name braucht 3 bis 20 Zeichen")
	assert_eq(world.guilds.accept("p2"), "keine Einladung")
	_found()
	assert_true(world.allied("p1", "p2"))
	assert_true(world.allied("p2", "p1"))
	assert_false(world.allied("p1", "p3"))
	assert_eq(world.guilds.name_of("p2"), "Grenzwacht")
	assert_eq(world.guilds.found("p3", "grenzWACHT"), "den Namen gibt es schon")
	assert_eq(world.guilds.found("p2", "Andere"), "du bist schon in einer Gilde")
	assert_eq(world.guilds.invite("p2", "p1"), "p1 ist schon in einer Gilde")
	assert_eq(world.guilds.leave("p1"), "")
	assert_eq(world.guilds.guilds[1]["leader"], "p2", "Führung geht weiter")
	assert_false(world.allied("p1", "p2"))
	assert_eq(world.guilds.leave("p2"), "")
	assert_true(world.guilds.guilds.is_empty(), "leere Gilde löst sich auf")


func test_allies_share_claims_doors_and_are_no_strangers() -> void:
	player.inventory["wood"] = 30
	var anchor := world.place_building(player, "anchor", Vector2i(44, 10), 0)  # Kachel (22, 5)
	assert_not_null(anchor)
	assert_true(world.claims.claim_tile(world, player, Vector2i(23, 5)))
	mate.inventory["wood"] = 10
	mate.pos = Vector2(23.5, 5.5)  # auf der beanspruchten Kachel
	assert_true(SimSensors.stranger_in_claim(world, player), "Kamerad zählt vor der Gilde als Fremder")
	mate.pos = Vector2(24.5, 5.5)
	assert_eq(world.can_place(mate, "wood_wall", Vector2i(46, 10), 0), "fremder Claim")
	_found()
	assert_eq(world.can_place(mate, "wood_wall", Vector2i(46, 10), 0), "", "Gildenmitglied baut auf dem Claim")
	assert_false(SimSensors.stranger_in_claim(world, player))
	assert_null(SimSensors.nearest_stranger(world, player), "Verbündete sind keine Fremden")
	assert_null(world.nearest_enemy(player, 10.0))
	assert_true(world.knows_name(mate, player), "Gildenmitglieder kennen sich")
	# Tür des Spielers lässt den Kameraden durch
	var door := world.place_building(player, "wood_door", Vector2i(44, 12), 0)  # Kachel (22, 6)
	assert_not_null(door)
	assert_false(world.map.half_blocked_for(Vector2i(44, 12), "p2", data), "Gildentür offen")
	assert_true(world.map.half_blocked_for(Vector2i(44, 12), "p3", data))
	# Sammeln auf dem Gildenclaim ist kein Diebstahl
	var claim := world.claims.claim_of_owner("p1")
	assert_false(world.claims.is_foreign(Vector2i(23, 5), "p2"))
	assert_true(world.claims.is_foreign(Vector2i(23, 5), "p3"))
	assert_eq(claim.owner_id, "p1")


func test_shared_alarm_and_defenses_spare_allies() -> void:
	_found()
	player.inventory["wood"] = 20
	player.inventory["wire"] = 3
	player.inventory["stone"] = 4
	player.inventory["iron"] = 4
	var sensor := world.place_building(player, "sensor", Vector2i(46, 11), 0)
	assert_not_null(sensor)
	var turret := world.place_building(player, "turret", Vector2i(44, 8), 0)
	assert_not_null(turret, "Turret: %s" % world.can_place(player, "turret", Vector2i(44, 8), 0))
	turret.contents["shot"] = 5
	mate.pos = sensor.center() + Vector2(2, 0)
	for i in 20:
		world.tick()
	assert_eq(world.triggered_sensors_of("p1").size(), 0, "Kamerad löst nicht aus")
	assert_eq(int(turret.contents["shot"]), 5, "Turret verschont den Kameraden")
	var stranger := world.spawn_player(sensor.center() + Vector2(2, 0), "p3", "Fremder")  # freie Kachel (25, 5)
	for i in 3:
		world.tick()
	assert_eq(world.triggered_sensors_of("p1").size(), 1)
	assert_eq(world.triggered_sensors_of("p2").size(), 1, "geteilter Alarm in der Gilde")
	assert_true(world.sensors_of("p2", true).has(sensor))
	assert_lt(int(turret.contents["shot"]), 5, "Fremde werden beschossen")
	assert_true(stranger.hp < stranger.max_hp or stranger.dead)


func test_guild_in_save_and_snapshot() -> void:
	_found()
	assert_eq(world.guilds.invite("p1", "p9"), "")
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_true(copy.allied("p1", "p2"), "Spielstand")
	assert_eq(copy.guilds.name_of("p1"), "Grenzwacht")
	assert_eq(int(copy.guilds.invites["p9"]), 1)
	assert_eq(copy.guilds.found("p9", "Neue"), "")
	assert_eq(int(copy.guilds.guild_of("p9")), 2, "Kennungen laufen weiter")
	world.tick()
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(NetProtocol.snapshot(world, player.id, {}, {}, {}))))
	assert_eq(mirror.guilds.name_of("p2"), "Grenzwacht", "Gilde eines Sichtbaren kommt mit den Stammdaten")
	var block := NetProtocol.decode(NetProtocol.encode(NetProtocol.self_block_for(world, player)))
	assert_eq(String(block["guild"]["name"]), "Grenzwacht")
	assert_eq(block["guild"]["members"].size(), 2)
	NetProtocol.apply_self(mirror, player.id, block)
	assert_true(mirror.allied("p1", "p2"))
