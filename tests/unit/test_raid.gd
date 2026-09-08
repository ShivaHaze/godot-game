extends GutTest
## Sprengsatz als Raidwerkzeug (auf fremdem Claim, zündet nach der Lunte, trifft jede Bauteil-Stufe) und Verrotten von Leichen.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 201)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_bomb_on_foreign_claim_blows_up_stone_and_turret() -> void:
	# Fremder Claim mit Steinwand und Turret
	var owner := world.spawn_player(Vector2(24.5, 5.5), "p2", "Besitzer")
	owner.inventory["wood"] = 30
	owner.inventory["stone"] = 20
	owner.inventory["iron"] = 4
	owner.inventory["wire"] = 2
	var anchor := SimConstruction.place_building(world, owner, "anchor", Vector2i(48, 8), 0)  # Kachel (24, 4)
	assert_not_null(anchor, "Anker: %s" % SimConstruction.can_place(world, owner, "anchor", Vector2i(48, 8), 0))
	assert_true(world.claims.claim_tile(world, owner, Vector2i(23, 4)))
	assert_true(world.claims.claim_tile(world, owner, Vector2i(22, 4)))
	assert_true(world.claims.claim_tile(world, owner, Vector2i(22, 5)))
	var wall := SimConstruction.place_building(world, owner, "stone_wall", Vector2i(44, 10), 0)  # Kachel (22, 5)
	assert_not_null(wall, "Wand: %s" % SimConstruction.can_place(world, owner, "stone_wall", Vector2i(44, 10), 0))
	var turret := SimConstruction.place_building(world, owner, "turret", Vector2i(44, 8), 0)  # Kachel (22, 4)
	assert_not_null(turret, "Turret: %s" % SimConstruction.can_place(world, owner, "turret", Vector2i(44, 8), 0))
	# Räuber legt den Sprengsatz auf dem fremden Claim
	player.pos = Vector2(21.5, 5.5)
	player.inventory["powder"] = 2
	player.inventory["iron"] = 1
	player.inventory["wood"] = 5
	world.spawn_building("forge", Vector2i(20, 6), "p1")  # Schmiede des Räubers (fliegt gleich mit in die Luft)
	assert_eq(SimCrafting.craft(world, player, "explosive"), "")
	assert_eq(SimConstruction.can_place(world, player, "wood_wall", Vector2i(46, 8), 0), "fremder Claim", "normales Bauen bleibt verboten")
	var bomb := SimConstruction.place_building(world, player, "bomb", Vector2i(43, 11), 0)  # Halbzelle vor der Wand, Kachel (21, 5) ist fremd? nein – (21,5) frei; (22,5) beansprucht
	assert_not_null(bomb, "Sprengsatz: %s" % SimConstruction.can_place(world, player, "bomb", Vector2i(43, 11), 0))
	assert_eq(int(player.inventory["explosive"]), 0)
	player.pos = Vector2(19.3, 5.5)  # zurück aus dem Radius (2 Kacheln um (21,75, 5,75))
	var wall_hp := wall.hp
	world.advance(4.0)
	assert_true(world.map.buildings.has(bomb.id), "Lunte läuft noch")
	assert_almost_eq(wall.hp, wall_hp, 0.01)
	world.advance(1.5)
	assert_false(world.map.buildings.has(bomb.id), "gezündet")
	assert_false(world.map.buildings.has(wall.id), "Steinwand (120 LP) zerstört: Sprengstoff kennt keine Stufe")
	assert_false(world.map.buildings.has(turret.id), "Turret weg")
	assert_true(world.map.buildings.has(anchor.id), "Anker außerhalb des Radius steht noch")
	assert_eq(player.hp, player.max_hp, "außerhalb des Radius heil")
	var seen := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("Sprengsatz"):
			seen = true
	assert_false(seen, "kein Chronikeintrag für Lebende: %s" % [SimChronicle.format_all(player)])


func test_bomb_not_on_market_and_can_be_defused() -> void:
	player.pos = Vector2(24.5, 24.5)
	player.inventory["explosive"] = 2
	assert_eq(SimConstruction.can_place(world, player, "bomb", Vector2i(50, 48), 0), "auf dem Markt wird nicht gebaut")
	player.pos = OPEN
	var bomb := SimConstruction.place_building(world, player, "bomb", Vector2i(43, 11), 0)
	assert_not_null(bomb)
	SimConstruction.damage_building(world, bomb, 10.0, -1)
	assert_false(world.map.buildings.has(bomb.id), "eingeschlagen = entschärft")
	world.advance(6.0)
	assert_eq(player.hp, player.max_hp, "keine Explosion")


func test_bomb_kill_is_logged_and_corpses_rot() -> void:
	var victim := world.spawn_player(OPEN + Vector2(1, 0), "p2", "Opfer")
	victim.hp = 5.0
	player.inventory["explosive"] = 1
	player.pos = OPEN + Vector2(-2, 0)
	var bomb := SimConstruction.place_building(world, player, "bomb", Vector2i(41, 11), 0)  # Kachel (20, 5), neben dem Opfer
	assert_not_null(bomb, "Sprengsatz: %s" % SimConstruction.can_place(world, player, "bomb", Vector2i(41, 11), 0))
	world.advance(6.0)
	assert_true(victim.dead)
	var lines := SimChronicle.format_all(victim)
	assert_true(lines[lines.size() - 1].contains("gestorben durch einen Sprengsatz"), "Chronik: %s" % [lines])
	assert_true(world.characters.has(victim.id), "Leiche liegt noch")
	world.advance(data.balf("combat.corpse_rot_hours") * 3600.0 - 12.0)
	assert_true(world.characters.has(victim.id), "kurz vor dem Verrotten noch da")
	world.advance(20.0)
	assert_false(world.characters.has(victim.id), "verrottet samt Inventar")
	assert_true(world.characters.has(player.id), "Lebende bleiben")
