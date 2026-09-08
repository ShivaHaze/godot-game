extends GutTest
## Ereignis Leitwolf: erscheint im Zentrum, stärker, flieht nie, Beute in der Leiche (nur live plünderbar), zieht weiter.
## Offline-Charaktere: kämpfen zurück, greifen ihn aber nie zuerst an.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 431)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _events(kind: String) -> Array:
	var result := []
	for event: Dictionary in world.events:
		if event.get("type") == kind:
			result.append(event)
	return result


func test_boss_appears_in_the_center_after_first_hours_and_is_stronger() -> void:
	assert_null(world.boss_alive(), "am Anfang kein Leitwolf")
	assert_almost_eq(world.next_boss_time, data.balf("events.boss.first_after_hours") * 3600.0, 0.001, "erster Leitwolf nach first_after_hours")
	world.next_boss_time = world.time + 20.0  # Wartezeit abkürzen (Test)
	world.advance(10.0)
	assert_null(world.boss_alive())
	world.advance(11.0)
	var boss := world.boss_alive()
	assert_not_null(boss, "nach first_after_hours da")
	assert_eq(boss.name, "Leitwolf")
	assert_eq(boss.kind, SimCharacter.Kind.WOLF)
	assert_eq(boss.max_hp, data.balf("events.boss.max_hp"))
	assert_eq(boss.melee_damage, data.balf("events.boss.bite_damage"))
	assert_eq(int(boss.inventory.get("sulfur", 0)), 3, "Beute im Bauch")
	# Am Wolf-Spawn, der der Mitte am nächsten liegt
	var center := Vector2(world.map.width * 0.5, world.map.height * 0.5)
	for cell: Vector2i in data.wolf_spawns:
		assert_true(SimMap.cell_center(cell).distance_to(center) >= boss.home_pos.distance_to(center) - 0.01, "zentralster Spawn")
	assert_eq(world.count_alive_wolves(), 3, "der Leitwolf zählt nicht als normaler Wolf")
	assert_eq(SimWorld.boss_event_text({"type": "boss_spawned", "name": "Leitwolf"}), "Ein Leitwolf streift durchs Zentrum.")


func test_boss_never_flees_and_leaves_loot_only_for_live_looters() -> void:
	var boss := world.spawn_boss()
	boss.pos = OPEN + Vector2(3, 0)
	boss.home_pos = boss.pos
	boss.hp = boss.max_hp * 0.1  # weit unter der Fluchtschwelle eines Wolfs
	world.spatial.rebuild(world.characters)
	for i in 20:
		world.tick()
	assert_ne(boss.ai_state, WolfAI.STATE_FLEE, "der Leitwolf flieht nie")
	assert_eq(boss.ai_state, WolfAI.STATE_CHASE, "er jagt")
	# Erlegt: Ereignis, Leiche bleibt trotz Wolfsnachschub, Beute per E
	world.apply_damage(boss, 1000.0, Vector2.RIGHT, player.id)
	assert_true(boss.dead)
	assert_eq(_events("boss_killed").size(), 1)
	world._wolf_respawn_timer = data.balf("wolf.respawn_time")
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF and not c.boss:
			c.dead = true
	world.tick()  # Nachschub räumt tote Wölfe auf
	assert_true(world.characters.has(boss.id), "die Leiche des Leitwolfs bleibt liegen")
	player.pos = boss.pos + Vector2(0.9, 0)
	world.spatial.rebuild(world.characters)
	var intent := SimIntent.new()
	intent.interact = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(int(player.inventory.get("sulfur", 0)), 3, "Schwefel geplündert: %s" % [player.inventory])
	assert_eq(int(player.inventory.get("meat", 0)), 6)
	# Nach corpse_rot_hours verrottet auch die Leitwolf-Leiche
	boss.death_time = world.time - data.balf("combat.corpse_rot_hours") * 3600.0 + 1.0
	world.advance(2.0)
	assert_false(world.characters.has(boss.id))


func test_boss_leaves_after_lifetime_and_returns_on_interval() -> void:
	var lifetime := data.balf("events.boss.lifetime_hours") * 3600.0
	var interval := data.balf("events.boss.interval_hours") * 3600.0
	world.next_boss_time = world.time + 1.0
	world.advance(2.0)
	var boss := world.boss_alive()
	assert_not_null(boss)
	assert_almost_eq(world.next_boss_time, world.time - 2.0 + 1.0 + interval, 0.1, "nächster nach interval_hours")
	boss.logout_time = world.time - lifetime + 5.0  # ist fast lifetime_hours da (Test kürzt ab)
	world.advance(4.0)
	assert_not_null(world.boss_alive(), "noch da")
	world.advance(2.0)
	assert_null(world.boss_alive(), "weitergezogen")
	assert_false(world.characters.has(boss.id))
	world.advance(10.0)
	assert_null(world.boss_alive(), "vor dem Intervall keiner")
	world.next_boss_time = world.time + 1.0
	world.advance(2.0)
	assert_not_null(world.boss_alive(), "nächster Leitwolf zum Termin")
	# Spielstand trägt Leitwolf und Zeitplan
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_not_null(copy.boss_alive())
	assert_true(copy.boss_alive().boss)
	assert_almost_eq(copy.next_boss_time, world.next_boss_time, 0.001)


func test_offline_character_fights_back_but_never_attacks_the_boss_first() -> void:
	var rules := data.normalize_rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "attack", "params": {"radius": 8}}},
	], "Test")
	world.logout(player.id, rules, "Jäger")
	player.logout_time = -1e9
	var boss := world.spawn_boss()
	boss.pos = OPEN + Vector2(4, 0)
	boss.home_pos = boss.pos
	boss.control = SimCharacter.Controller.NONE  # steht still: greift nicht an
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 40:
		world.tick()
		shots += _events("shoot").size()
	assert_eq(shots, 0, "'greife an' meidet den Leitwolf")
	assert_eq(boss.hp, boss.max_hp)
	# Beißt er, wehrt sich der Charakter (kämpfe zurück)
	world.apply_damage(player, 1.0, Vector2.LEFT, boss.id)
	for i in 40:
		world.tick()
		shots += _events("shoot").size()
	assert_gt(shots, 0, "zurückgekämpft")
	assert_lt(boss.hp, boss.max_hp)
