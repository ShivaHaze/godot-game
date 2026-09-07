extends GutTest
## Freischalten von Regel-Bausteinen: 'greife an' ist gesperrt, bis ein fremder Offline-NPC einen angreift.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 23)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _attack_rules(radius: float = 8.0) -> Array:
	return data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "attack", "params": {"radius": radius}}},
	], "Test")


func test_attack_action_is_locked_at_start() -> void:
	assert_true(data.is_valid(), "Fehler: %s" % data.errors)
	assert_true(data.actions.has("attack"))
	assert_false(world.can_use(player, data.action_def("attack")))
	assert_true(world.can_use(player, data.action_def("fight_back")))
	assert_true(world.can_use(player, data.condition_def("hungry")))


func test_locked_rule_is_skipped_by_npc() -> void:
	var stranger := world.spawn_player(OPEN + Vector2(4, 0), "p2", "Fremder")
	world.logout(player.id, _attack_rules())
	player.logout_time = -1e9
	for i in 40:
		world.tick()
	assert_eq(player.active_rule_index, RuleEngine.NO_MATCH, "gesperrte Regel wird nicht ausgeführt")
	assert_eq(stranger.hp, stranger.max_hp, "kein Angriff")
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("Baustein nicht freigeschaltet"):
			found = true
	assert_true(found, "Chronik nennt den Grund")


func test_npc_attack_unlocks_for_victim_owner_only() -> void:
	var npc := world.spawn_player(OPEN + Vector2(3, 0), "p2", "Fremder NPC")
	world.logout(npc.id, data.roles["guard"]["rules"])
	npc.logout_time = -1e9
	var hits := 0
	world.apply_damage(npc, 1.0, Vector2.RIGHT, player.id)  # Spieler provoziert, NPC kämpft zurück
	for i in 80:
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "hit" and event.get("id") == player.id:
				hits += 1
	assert_gt(hits, 0, "der fremde NPC trifft den Spieler")
	assert_true(world.can_use(player, data.action_def("attack")), "Angriff durch fremden NPC schaltet 'greife an' frei")
	assert_false(world.can_use(npc, data.action_def("attack")), "der Angreifer selbst bekommt nichts")
	assert_true(world.unlocks_of("p1").has("attacked_by_npc"))
	assert_false(world.unlock("p1", "attacked_by_npc"), "nur einmal")


func test_wolf_bite_does_not_unlock() -> void:
	var wolf: SimCharacter = null
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			wolf = c
	world.apply_damage(player, 3.0, Vector2.LEFT, wolf.id)
	assert_false(world.can_use(player, data.action_def("attack")), "Tiere zählen nicht")


func test_unlocked_attack_hits_stranger_within_radius_and_leash() -> void:
	world.unlock("p1", "attacked_by_npc")
	var stranger := world.spawn_player(OPEN + Vector2(4, 0), "p2", "Fremder")
	stranger.facing = Vector2.LEFT
	world.logout(player.id, _attack_rules(8.0))
	player.logout_time = -1e9
	var worst := 0.0
	for i in 60:
		world.tick()
		worst = maxf(worst, player.pos.distance_to(OPEN))
	assert_lt(stranger.hp, stranger.max_hp, "greift ohne Provokation an")
	assert_lte(worst, data.balf("npc.default_leash_radius") + 0.01, "bleibt an der Leine")
	var lines := SimChronicle.format_all(player)
	assert_true(lines[1].ends_with("sonst, Regel 1: angegriffen: Fremde im Umkreis 8"), lines[1])


func test_unlocks_survive_death_and_save() -> void:
	world.unlock("p1", "attacked_by_npc")
	var fresh := world.spawn_player(OPEN + Vector2(1, 0), "p1", "Du (neu)")
	assert_true(world.can_use(fresh, data.action_def("attack")), "am Besitzer, nicht am Charakter")
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_true(copy.unlocks_of("p1").has("attacked_by_npc"))
	assert_false(copy.unlocks_of("p2").has("attacked_by_npc"))


func test_menu_shows_locked_action_disabled() -> void:
	var menu: CanvasLayer = load("res://game/logout_menu.gd").new()
	add_child_autofree(menu)
	menu.open(data, player, data.default_rules, "", {})
	var locked: Dictionary = menu._locked(Array(data.action_order, TYPE_STRING, "", null), data.actions)
	assert_true(locked.has("attack"))
	assert_false(locked.has("fight_back"))
	menu.open(data, player, data.default_rules, "", {"attacked_by_npc": true})
	assert_false(menu._locked(Array(data.action_order, TYPE_STRING, "", null), data.actions).has("attack"))
