extends GutTest
## Claims: Anker, Kacheln, Rechte, Unterhalt, Schrumpfen, Schonfrist, Diebstahl, Sensor, Spielstand, Snapshot.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 41)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.inventory["wood"] = 20
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


## Anker auf Kachel (22, 5), Spieler steht daneben.
func _anchor() -> SimBuilding:
	var b := world.place_building(player, "anchor", Vector2i(44, 10), 0)
	assert_not_null(b, "Anker steht")
	return b


func test_anchor_founds_claim_and_makes_condition_available() -> void:
	assert_false(world.can_use(player, data.condition_def("stranger_in_claim")), "ohne Claim nicht verfügbar")
	var b := _anchor()
	var claim := world.claims.claim_of_owner("p1")
	assert_not_null(claim)
	assert_eq(claim.anchor_building_id, b.id)
	assert_eq(claim.anchor_tile, Vector2i(22, 5))
	assert_eq(claim.tiles.size(), 1)
	assert_eq(world.claims.claim_at(Vector2i(22, 5)), claim)
	assert_eq(int(player.inventory["wood"]), 10)
	assert_true(world.can_use(player, data.condition_def("stranger_in_claim")), "mit Claim verfügbar")
	assert_eq(world.can_place(player, "anchor", Vector2i(46, 10), 0), "du hast schon einen Anker (Solo: einer)")


func test_foreign_anchor_distance_and_claim_rules() -> void:
	_anchor()
	var other := world.spawn_player(OPEN + Vector2(4, 0), "p2", "Nachbar")
	other.inventory["wood"] = 30
	assert_eq(world.can_place(other, "anchor", Vector2i(52, 10), 0), "zu nah an einem fremden Anker")
	other.pos = Vector2(34.6, 5.5)
	assert_eq(world.can_place(other, "anchor", Vector2i(66, 10), 0), "")
	# Kacheln: angrenzend, Kosten, fremd, Limit
	assert_eq(world.claims.claim_tile_reason(world, player, Vector2i(24, 5)), "muss an den Claim angrenzen")
	assert_eq(world.claims.claim_tile_reason(world, player, Vector2i(21, 5)), "")
	assert_true(world.claims.claim_tile(world, player, Vector2i(21, 5)))
	assert_eq(int(player.inventory["wood"]), 9)
	assert_eq(world.claims.claim_tile_reason(world, player, Vector2i(21, 5)), "schon beansprucht")
	assert_eq(world.claims.claim_tile_reason(world, other, Vector2i(23, 5)), "du brauchst einen stehenden Anker")
	world.place_building(other, "anchor", Vector2i(66, 10), 0)
	other.pos = Vector2(24.0, 5.5)
	assert_eq(world.claims.claim_tile_reason(world, other, Vector2i(21, 5)), "fremder Claim")
	player.inventory["wood"] = 100
	var claimed := 2
	for ring in range(1, 6):
		for tile: Vector2i in [Vector2i(22 - ring, 5), Vector2i(22 + ring, 5), Vector2i(22, 5 - ring), Vector2i(22, 5 + ring)]:
			if world.claims.claim_tile_reason(world, player, tile).is_empty():
				world.claims.claim_tile(world, player, tile)
				claimed += 1
	assert_gt(claimed, 10, "mehrere Kacheln beansprucht")
	assert_true(world.claims.claim_tile_reason(world, player, Vector2i(22, 12)).begins_with("muss an den Claim") or claimed <= 40)


func test_only_owner_builds_on_claim_and_npc_does_not_gather_foreign() -> void:
	_anchor()
	world.claims.claim_tile(world, player, Vector2i(21, 5))
	var other := world.spawn_player(Vector2(21.5, 6.6), "p2", "Fremder")
	other.inventory["wood"] = 6  # genug für eine Wand, Inventar bleibt offen
	assert_eq(world.can_place(other, "wood_wall", Vector2i(42, 10), 0), "fremder Claim")
	assert_eq(world.can_place(player, "wood_wall", Vector2i(42, 10), 0), "")
	# Alle vier Beerenbüsche (27..28, 2..3) in den Claim holen: Kachelkette von (22,5) aus
	player.inventory["wood"] = 100
	for tile: Vector2i in [Vector2i(23, 5), Vector2i(24, 5), Vector2i(25, 5), Vector2i(26, 5), Vector2i(26, 4), Vector2i(26, 3), Vector2i(27, 3), Vector2i(27, 2), Vector2i(28, 2), Vector2i(28, 3)]:
		player.pos = SimMap.cell_center(tile) + Vector2(-1, 0)
		assert_eq(world.claims.claim_tile_reason(world, player, tile), "", "Kachel %s" % tile)
		world.claims.claim_tile(world, player, tile)
	var npc := world.spawn_player(Vector2(26.5, 4.5), "p2", "Fremder NPC")
	world.logout(npc.id, data.roles["gatherer"]["rules"])
	npc.logout_time = -1e9
	for i in 40:
		world.tick()
	assert_eq(int(npc.inventory["berries"]), 0, "fremder NPC sammelt nicht im Claim")
	# Fremder live sammelt: Diebstahl
	other.pos = Vector2(26.5, 2.5)
	var intent := SimIntent.new()
	intent.interact = true
	var thefts := 0
	for i in 40:
		world.set_intent(other.id, intent)
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "theft":
				thefts += 1
	assert_gt(thefts, 0, "Diebstahl gemeldet")
	assert_gt(int(other.inventory["berries"]), 0, "aber möglich")


func test_upkeep_deposit_and_shrink() -> void:
	_anchor()
	player.inventory["wood"] = 100
	for tile: Vector2i in [Vector2i(21, 5), Vector2i(23, 5), Vector2i(22, 4), Vector2i(22, 6), Vector2i(20, 5), Vector2i(24, 5), Vector2i(22, 3), Vector2i(22, 7), Vector2i(19, 5)]:
		player.pos = SimMap.cell_center(tile) + Vector2(0, 1)
		assert_true(world.claims.claim_tile(world, player, tile), "Kachel %s" % tile)
	var claim := world.claims.claim_of_owner("p1")
	assert_eq(claim.tiles.size(), 10)
	assert_almost_eq(SimClaims.upkeep_per_hour(data, 10), 1.0, 0.001, "10 Kacheln = 1 Holz/h")
	assert_almost_eq(SimClaims.upkeep_per_hour(data, 40), 10.0, 0.001, "40 Kacheln = 10 Holz/h (überproportional)")
	# Abliefern per E neben dem Anker
	player.pos = Vector2(21.4, 5.5)
	player.inventory["wood"] = 24
	var intent := SimIntent.new()
	intent.interact = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_almost_eq(claim.stock, 24.0, 0.01, "alles Holz abgeliefert")
	assert_eq(int(player.inventory["wood"]), 0)
	world.advance(3600.0 * 12)
	assert_almost_eq(claim.stock, 12.0, 0.05, "12 h Unterhalt verbraucht")
	world.advance(3600.0 * 12 + 60)
	assert_eq(claim.stock, 0.0)
	assert_gte(claim.starving_since, 0.0, "hungert")
	assert_eq(claim.tiles.size(), 10, "noch nicht geschrumpft")
	world.advance(3600.0 * 6)
	assert_eq(claim.tiles.size(), 9, "äußerste Kachel verloren")
	assert_false(claim.tiles.has(Vector2i(19, 5)), "die fernste Kachel zuerst")
	world.advance(3600.0 * 60)
	assert_eq(claim.tiles.size(), 1, "schrumpft bis zur Ankerkachel")
	assert_true(world.claims.claims.has(claim.id), "Anker steht noch")


func test_anchor_destroyed_grace_and_restore() -> void:
	var anchor := _anchor()
	var claim := world.claims.claim_of_owner("p1")
	world.damage_building(anchor, 100.0, -1)
	assert_eq(claim.anchor_building_id, -1)
	assert_gt(claim.grace_until, world.time)
	assert_eq(world.claims.claim_tile_reason(world, player, Vector2i(21, 5)), "du brauchst einen stehenden Anker")
	world.advance(3600.0)
	player.inventory["wood"] = 20
	var again := world.place_building(player, "anchor", Vector2i(44, 10), 0)
	assert_not_null(again, "Wiederaufbau in der Schonfrist")
	assert_eq(claim.anchor_building_id, again.id, "derselbe Claim lebt weiter")
	world.damage_building(again, 100.0, -1)
	world.advance(3600.0 * 3)
	assert_false(world.claims.claims.has(claim.id), "nach der Schonfrist aufgelöst")
	assert_null(world.claims.claim_at(Vector2i(22, 5)))


func test_logout_on_foreign_claim_pushes_out_and_sensor() -> void:
	_anchor()
	world.claims.claim_tile(world, player, Vector2i(21, 5))
	var other := world.spawn_player(Vector2(21.5, 5.5), "p2", "Fremder")
	assert_true(SimSensors.stranger_in_claim(world, player), "Fremder steht im Claim")
	world.logout(other.id, data.roles["hide"]["rules"])
	assert_false(world.claims.is_foreign(SimMap.cell_of(other.pos), "p2"), "aus dem fremden Claim geschoben")
	assert_true(SimChronicle.format_all(other)[0].contains("aus fremdem Claim geschoben"))
	assert_false(SimSensors.stranger_in_claim(world, player))


func test_save_and_snapshot_carry_claims() -> void:
	_anchor()
	world.claims.claim_tile(world, player, Vector2i(21, 5))
	var claim := world.claims.claim_of_owner("p1")
	claim.stock = 17.0
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	var loaded := copy.claims.claim_of_owner("p1")
	assert_not_null(loaded)
	assert_eq(loaded.tiles.size(), 2)
	assert_eq(loaded.stock, 17.0)
	assert_eq(copy.claims.claim_at(Vector2i(21, 5)), loaded)
	var known := {}
	var nodes := {}
	var built := {}
	var state := {}
	world.tick()
	var snap := NetProtocol.snapshot(world, player.id, known, nodes, built, state)
	assert_eq(snap["clm"].size(), 1)
	var again := NetProtocol.snapshot(world, player.id, known, nodes, built, state)
	assert_false(again.has("clm"), "unverändert: nicht nochmal")
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	assert_eq(mirror.claims.claim_at(Vector2i(21, 5)).owner_id, "p1")
	assert_gt(mirror.claims.claim_of_owner("p1").hours_left_hint, 0.0)
