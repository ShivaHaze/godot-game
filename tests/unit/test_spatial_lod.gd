extends GutTest
## Räumliches Raster und Simulationsstufen pro Charakter (grob ohne Online-Spieler in der Nähe).

var data: SimData
var world: SimWorld


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 17)
	world.setup_new_game()


func test_spatial_query_matches_brute_force() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 60:
		world.spawn_player(Vector2(rng.randf_range(1.0, 39.0), rng.randf_range(1.0, 29.0)), "o%d" % i, "N%d" % i)
	var spatial := SimSpatial.new(4.0)
	spatial.rebuild(world.characters)
	for trial in 30:
		var pos := Vector2(rng.randf_range(0.0, 40.0), rng.randf_range(0.0, 30.0))
		var radius := rng.randf_range(0.5, 9.0)
		var expected := {}
		for c: SimCharacter in world.characters.values():
			if not c.dead and c.pos.distance_to(pos) <= radius:
				expected[c.id] = true
		var got := {}
		for c: SimCharacter in spatial.query(pos, radius):
			if c.pos.distance_to(pos) <= radius:
				got[c.id] = true
		assert_eq_deep(got, expected)


func test_nearest_enemy_uses_grid_and_ignores_far() -> void:
	var player: SimCharacter = world.characters[1]
	player.pos = Vector2(20.5, 5.5)
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
	var near := world.spawn_player(player.pos + Vector2(2, 0), "p2", "nah")
	world.spawn_player(player.pos + Vector2(9, 0), "p3", "fern")
	world.tick()
	assert_eq(world.nearest_enemy(player, 5.0), near)
	assert_null(world.nearest_enemy(player, 1.0))


func test_far_npc_runs_coarse_near_npc_runs_fine() -> void:
	var player: SimCharacter = world.characters[1]
	player.pos = Vector2(20.5, 5.5)
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.control = SimCharacter.Controller.NONE
	var far := world.spawn_player(Vector2(5.5, 25.5), "f", "fern")
	var near := world.spawn_player(player.pos + Vector2(3, 0), "n", "nah")
	var rules := data.normalize_rule_list([{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 2}}}], "Test")
	world.logout(far.id, rules)
	world.logout(near.id, rules)
	var ticks := data.bali("tick_rate") * 4
	for i in ticks:
		world.tick()
	assert_eq(near.lod_fine_steps, ticks, "nah am Online-Spieler: jeder Tick")
	assert_eq(near.lod_coarse_steps, 0)
	assert_eq(far.lod_fine_steps, 0, "fern: nur grobe Schritte")
	assert_eq(far.lod_coarse_steps, int(4.0 / data.balf("offline.coarse_tick_dt")))
	# Verhalten bleibt gleich: beide bleiben in ihrer Leine
	assert_lte(far.pos.distance_to(far.logout_pos), 2.0)
	assert_lte(near.pos.distance_to(near.logout_pos), 2.0)


func test_coarse_and_fine_cover_same_distance() -> void:
	var player: SimCharacter = world.characters[1]
	player.pos = Vector2(20.5, 5.5)
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.control = SimCharacter.Controller.NONE
	var far := world.spawn_player(Vector2(3.5, 23.5), "f", "fern")
	var near := world.spawn_player(Vector2(23.5, 5.5), "n", "nah")
	far.markers.append({"id": "m1", "name": "Ziel", "pos": far.pos + Vector2(10, 0)})
	near.markers.append({"id": "m1", "name": "Ziel", "pos": near.pos + Vector2(10, 0)})
	var rules := data.normalize_rule_list([{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "m1", "radius": 1}}}], "Test")
	world.logout(far.id, rules)
	world.logout(near.id, rules)
	for i in data.bali("tick_rate") * 2:
		world.tick()
	var far_moved := far.pos.distance_to(Vector2(3.5, 23.5))
	var near_moved := near.pos.distance_to(Vector2(23.5, 5.5))
	assert_almost_eq(far_moved, near_moved, 0.6, "grobe Schritte legen dieselbe Strecke zurück (Rundung auf ganze Sekunden)")
	assert_gt(far_moved, 5.0)


func test_wolves_far_from_players_still_hunt_npcs() -> void:
	var player: SimCharacter = world.characters[1]
	player.pos = Vector2(2.5, 2.5)
	var wolf: SimCharacter = null
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			if wolf == null:
				wolf = c
			else:
				c.dead = true
	var npc := world.spawn_player(Vector2(30.5, 22.5), "f", "fern")
	world.logout(npc.id, data.roles["hide"]["rules"])
	npc.logout_time = -1e9
	wolf.pos = npc.pos + Vector2(5, 0)
	wolf.home_pos = wolf.pos
	world.advance(15.0)
	assert_lt(npc.hp, npc.max_hp, "auch grob simuliert beißt der Wolf")


func test_coarse_fight_back_keeps_leash_exactly() -> void:
	var player: SimCharacter = world.characters[1]
	player.pos = Vector2(2.5, 2.5)
	var wolf: SimCharacter = null
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			if wolf == null:
				wolf = c
			else:
				c.dead = true
	var origin := Vector2(20.5, 5.5)
	var npc := world.spawn_player(origin, "f", "fern")
	var rules := data.normalize_rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	], "Test")
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	wolf.control = SimCharacter.Controller.NONE
	wolf.pos = origin + Vector2(9, 0)
	wolf.facing = Vector2.LEFT
	for i in 25:
		world.tick()  # erste grobe Entscheidung: 'bleib bei Hier (3)' setzt die Leine
	assert_eq(npc.leash_radius, 3.0)
	world.apply_damage(npc, 1.0, Vector2.LEFT, wolf.id)
	var worst := 0.0
	for i in 20 * 6:
		world.tick()
		worst = maxf(worst, npc.pos.distance_to(origin))
	assert_gt(npc.lod_coarse_steps, 0, "läuft grob (kein Online-Spieler in der Nähe)")
	assert_lte(worst, 3.001, "Leine hält auch bei 4-Kachel-Schritten")
	assert_lt(wolf.hp, wolf.max_hp, "schießt trotzdem")


func test_observer_makes_npc_run_fine() -> void:
	var player: SimCharacter = world.characters[1]
	player.pos = Vector2(2.5, 2.5)
	var npc := world.spawn_player(Vector2(30.5, 20.5), "f", "fern")
	world.logout(npc.id, data.roles["guard"]["rules"])
	world.observer_ids = [npc.id]
	for i in 20:
		world.tick()
	assert_eq(npc.lod_fine_steps, 20, "beobachteter NPC läuft fein")
