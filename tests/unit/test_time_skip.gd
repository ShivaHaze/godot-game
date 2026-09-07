extends GutTest
## Zeitsprung: Simulationsstufen (grob/fein), Budget, 8 Stunden am Stück, Determinismus.

const PARKING: Vector2 = Vector2(38.5, 28.5)

var data: SimData
var world: SimWorld
var npc: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 21)
	npc = world.get_character(world.setup_new_game())


func _park_wolves() -> void:
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = PARKING
			c.home_pos = PARKING
			c.ai_target_pos = PARKING
			c.control = SimCharacter.Controller.NONE


func _wolf() -> SimCharacter:
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			return c
	return null


func test_quiet_skip_uses_coarse_ticks() -> void:
	_park_wolves()
	world.logout(npc.id, data.roles["guard"]["rules"], "Wache")
	var steps := world.advance(8 * 3600.0)
	assert_almost_eq(world.time, 8 * 3600.0, 0.01)
	assert_eq(steps, int(8 * 3600.0 / data.balf("offline.coarse_tick_dt")), "ohne Gefahr nur grobe Schritte")
	assert_eq(world.clock_string(), "16:00")


func test_danger_nearby_uses_fine_ticks() -> void:
	_park_wolves()
	var wolf := _wolf()
	wolf.pos = npc.pos + Vector2(5, 0)
	assert_true(world.is_hot())
	var steps := world.advance(10.0)
	assert_eq(steps, int(10.0 / world.tick_dt), "Wolf in der Nähe: feine Ticks")


func test_is_hot_conditions() -> void:
	_park_wolves()
	assert_false(world.is_hot(), "nichts los")
	var p := SimProjectile.new()
	p.lifetime = 1.0
	world.projectiles.append(p)
	assert_true(world.is_hot(), "Projektil in der Luft")
	world.projectiles.clear()
	npc.last_damage_time = world.time
	assert_true(world.is_hot(), "kürzlich getroffen")


func test_advance_until_stops_exactly_at_target() -> void:
	_park_wolves()
	var done := world.advance_until(world.time + 100.0, 5000)
	assert_true(done)
	assert_almost_eq(world.time, 100.0, 0.001)
	var partial := world.advance_until(world.time + 3600.0, 0)
	assert_false(partial, "ohne Budget nur ein Schritt")
	assert_lt(world.time, 3700.0)


func test_eight_hours_guard_eats_berries_and_survives() -> void:
	_park_wolves()
	npc.inventory["berries"] = 10
	world.logout(npc.id, data.roles["guard"]["rules"], "Wache")
	var started := Time.get_ticks_msec()
	world.advance(8 * 3600.0)
	var elapsed := Time.get_ticks_msec() - started
	gut.p("8 h ruhiger Zeitsprung: %d ms" % elapsed)
	assert_lt(elapsed, 60000, "muss in Sekunden laufen")
	assert_false(npc.dead)
	assert_lt(int(npc.inventory["berries"]), 10, "hat unterwegs gegessen")
	assert_gt(npc.hunger, 0.0, "nie geschwächt")
	var ate := 0
	for line: String in SimChronicle.format_all(npc):
		if line.contains("gegessen"):
			ate += 1
	assert_gt(ate, 0)
	assert_lte(npc.pos.distance_to(npc.logout_pos), 4.0, "Leine der Wache gehalten")


func test_eight_hours_with_wolves_active_runs_and_stays_deterministic() -> void:
	var a := SimWorld.new(data, 77)
	var a_id := a.setup_new_game()
	a.get_character(a_id).inventory["berries"] = 6
	a.logout(a_id, data.roles["gatherer"]["rules"], "Sammler")
	var b := SimWorld.new(data, 77)
	var b_id := b.setup_new_game()
	b.get_character(b_id).inventory["berries"] = 6
	b.logout(b_id, data.roles["gatherer"]["rules"], "Sammler")
	var started := Time.get_ticks_msec()
	a.advance(8 * 3600.0)
	gut.p("8 h Sammler mit Wölfen: %d ms" % (Time.get_ticks_msec() - started))
	b.advance(8 * 3600.0)
	assert_eq(a.get_character(a_id).pos, b.get_character(b_id).pos, "gleicher Seed, gleiches Ergebnis")
	assert_eq(a.get_character(a_id).chronicle.size(), b.get_character(b_id).chronicle.size())
	assert_gt(a.get_character(a_id).chronicle.size(), 1, "Chronik hat Einträge")
	assert_eq(SimChronicle.format_all(a.get_character(a_id)), SimChronicle.format_all(b.get_character(b_id)))


func test_coarse_ticks_arrive_without_overshoot_and_keep_leash() -> void:
	_park_wolves()
	var target := npc.pos + Vector2(8, 0)
	npc.markers.append({"id": "m1", "name": "Lager", "pos": target})
	var rules := data.normalize_rule_list([{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "m1", "radius": 2}}}], "Test")
	world.logout(npc.id, rules)
	var dt := data.balf("offline.coarse_tick_dt")
	var arrived_at := -1
	var worst_after_arrival := 0.0
	var biggest_jump_after_arrival := 0.0
	for i in 60:
		var before := npc.pos
		world.step(dt)
		var d := npc.pos.distance_to(target)
		if arrived_at < 0 and d <= 2.0:
			arrived_at = i
		elif arrived_at >= 0:
			worst_after_arrival = maxf(worst_after_arrival, d)
			biggest_jump_after_arrival = maxf(biggest_jump_after_arrival, before.distance_to(npc.pos))
	assert_gte(arrived_at, 0, "kommt an")
	assert_lte(worst_after_arrival, 2.0, "bleibt in der Leine")
	assert_lt(biggest_jump_after_arrival, 0.5, "kein Hin- und Herspringen bei groben Ticks")
