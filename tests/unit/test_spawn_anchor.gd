extends GutTest
## Spawn-Anker: teures Claim-Upgrade, neue Charaktere des Besitzers erscheinen daneben.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 101)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.inventory["wood"] = 60
	player.inventory["stone"] = 20


## Anker auf Kachel (22, 5), Claim um (23, 5) und (22, 6) erweitert.
func _found_claim() -> SimBuilding:
	var anchor := world.place_building(player, "anchor", Vector2i(44, 10), 0)
	assert_not_null(anchor)
	assert_true(world.claims.claim_tile(world, player, Vector2i(23, 5)))
	assert_true(world.claims.claim_tile(world, player, Vector2i(22, 6)))
	return anchor


func test_only_inside_own_claim_and_once() -> void:
	assert_eq(world.can_place(player, "spawn_anchor", Vector2i(46, 10), 0), "nur im eigenen Claim")
	_found_claim()
	assert_eq(world.can_place(player, "spawn_anchor", Vector2i(46, 10), 0), "")
	var spawn := world.place_building(player, "spawn_anchor", Vector2i(46, 10), 0)  # Kachel (23, 5)
	assert_not_null(spawn)
	assert_eq(int(player.inventory["wood"]), 60 - 10 - 2 - 25)
	assert_eq(int(player.inventory["stone"]), 20 - 8)
	player.inventory["wood"] = 60
	assert_eq(world.can_place(player, "spawn_anchor", Vector2i(44, 12), 0), "du hast schon Spawn-Anker")
	var stranger := world.spawn_player(Vector2(24.5, 6.5), "p2", "Fremder")
	stranger.inventory["wood"] = 30
	stranger.inventory["stone"] = 10
	assert_eq(world.can_place(stranger, "spawn_anchor", Vector2i(44, 12), 0), "fremder Claim")
	assert_eq(world.can_place(stranger, "spawn_anchor", Vector2i(50, 12), 0), "nur im eigenen Claim")


func test_respawn_next_to_spawn_anchor_else_map_edge() -> void:
	var edge := world.spawn_point_for("p1")
	assert_true(data.player_spawns.has(SimMap.cell_of(edge)), "ohne Anker: Kartenrand")
	_found_claim()
	var spawn := world.place_building(player, "spawn_anchor", Vector2i(46, 10), 0)
	assert_not_null(spawn)
	var point := world.spawn_point_for("p1")
	assert_lt(point.distance_to(spawn.center()), 2.0, "neben dem Spawn-Anker")
	assert_true(world.map.is_walkable(SimMap.cell_of(point)), "auf begehbarem Boden")
	assert_false(world.map.built_half.has(SimMap.cell_of(point) * 2), "nicht in einem Bauteil")
	assert_true(data.player_spawns.has(SimMap.cell_of(world.spawn_point_for("p2"))), "Fremde weiter am Rand")
	world.damage_building(spawn, 100.0, -1)
	assert_true(data.player_spawns.has(SimMap.cell_of(world.spawn_point_for("p1"))), "zerstört: wieder Kartenrand")
