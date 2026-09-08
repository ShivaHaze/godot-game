extends GutTest
## Voraussetzungen statt Freischaltungen: alle Grundbausteine sind da ('greife an' inklusive); Bausteine mit
## 'requires' sind verfügbar, sobald die Voraussetzung in der Welt existiert, und fallen sonst mit Grund durch.

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
	player.inventory["wood"] = 20
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _attack_rules(radius: float = 8.0) -> Array:
	return data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "attack", "params": {"radius": radius}}},
	], "Test")


func test_basic_blocks_are_always_available() -> void:
	assert_true(data.is_valid(), "Fehler: %s" % data.errors)
	for id: String in ["attack", "fight_back", "heal_self", "craft", "deliver", "hide", "eat"]:
		assert_true(world.can_use(player, data.action_def(id)), id)
	for id: String in ["hungry", "under_attack", "bleeding", "poisoned", "sick", "stranger_near"]:
		assert_true(world.can_use(player, data.condition_def(id)), id)
	for id: String in data.action_order + data.condition_order:
		var def: Dictionary = data.actions.get(id, data.conditions.get(id, {}))
		assert_false(def.has("unlock"), "%s: kein Freischalten mehr" % id)


func test_attack_hits_stranger_within_radius_and_leash() -> void:
	var stranger := world.spawn_player(OPEN + Vector2(4, 0), "p2", "Fremder")
	stranger.facing = Vector2.LEFT
	world.logout(player.id, _attack_rules(8.0))
	player.logout_time = -1e9
	var worst := 0.0
	for i in 60:
		world.tick()
		worst = maxf(worst, player.pos.distance_to(OPEN))
	assert_lt(stranger.hp, stranger.max_hp, "greift ohne Provokation an – der Spieler hat es so geregelt")
	assert_lte(worst, data.balf("npc.default_leash_radius") + 0.01, "bleibt an der Leine")
	var lines := SimChronicle.format_all(player)
	assert_true(lines[1].ends_with("sonst, Regel 1: angegriffen: Fremde im Umkreis 8"), lines[1])


func test_blocks_with_requirement_follow_the_world_state() -> void:
	assert_eq(world.prerequisites_of("p1"), {"own_claim": false, "own_sensor": false})
	assert_false(world.can_use(player, data.condition_def("stranger_in_claim")))
	assert_false(world.can_use(player, data.action_def("toll")))
	assert_false(world.can_use(player, data.condition_def("sensor_triggered")))
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	assert_not_null(anchor)
	assert_true(world.can_use(player, data.condition_def("stranger_in_claim")), "mit Claim verfügbar")
	assert_true(world.can_use(player, data.action_def("toll")))
	player.inventory["wire"] = 1
	assert_not_null(SimConstruction.place_building(world, player, "sensor", Vector2i(40, 10), 0))
	assert_true(world.can_use(player, data.condition_def("sensor_triggered")), "mit Sensor verfügbar")
	assert_eq(world.prerequisites_of("p1"), {"own_claim": true, "own_sensor": true})
	# Gildenmitglied teilt den Sensor (Voraussetzung über Verbündete)
	var member := world.spawn_player(OPEN + Vector2(3, 0), "p2", "Ben")
	assert_eq(world.guilds.found("p1", "Wache"), "")
	assert_eq(world.guilds.invite("p1", "p2"), "")
	assert_eq(world.guilds.accept("p2"), "")
	assert_true(world.prerequisites_of("p2")["own_sensor"], "Sensor eines Mitglieds zählt")
	assert_false(world.prerequisites_of("p2")["own_claim"], "Claims bleiben je Besitzer")
	assert_eq(member.owner_id, "p2")


func test_rule_falls_through_with_reason_when_requirement_is_lost() -> void:
	var anchor := SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "stranger_in_claim"}, "then": {"action": "toll", "params": {"resource": "wood", "amount": 1}}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	], "Test")
	world.logout(player.id, rules, "Zöllner")
	player.logout_time = -1e9
	assert_eq(NpcController.blocked_reason(world, player, rules[0]), "kein Mensch ohne Freigang im Claim", "mit Claim: nur der Zoll-Grund")
	# Anker zerstört und Schonfrist abgelaufen: der Claim ist weg, der Baustein fällt mit Grund durch
	SimConstruction.damage_building(world, anchor, 1000.0, -1)
	world.advance(data.balf("claim.grace_hours") * 3600.0 + 5.0)
	assert_null(world.claims.claim_of_owner("p1"))
	assert_eq(NpcController.blocked_reason(world, player, rules[0]), "braucht einen eigenen Claim (Anker)")
	assert_false(world.can_use(player, data.action_def("toll")))


func test_save_has_no_unlocks_and_mirror_gets_requirements_from_server() -> void:
	var dict := SimSave.world_to_dict(world)
	assert_false(dict.has("unlocks"), "nichts mehr zu speichern")
	SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	var block := NetProtocol.self_block_for(world, player)
	block["reqs"] = world.prerequisites_of(player.owner_id)
	var mirror := SimWorld.new(data, 0)
	var you := SimCharacter.new()  # Stammdaten (Besitzer) kommen vor dem Selbstblock an
	you.id = player.id
	you.owner_id = "p1"
	mirror.characters[you.id] = you
	NetProtocol.apply_self(mirror, player.id, NetProtocol.decode(NetProtocol.encode(block)))
	assert_true(mirror.prerequisites_of("p1")["own_claim"], "der Spiegel übernimmt den Stand des Servers")
	assert_false(mirror.prerequisites_of("p1")["own_sensor"])


func test_menu_shows_unavailable_block_disabled_with_hint() -> void:
	var menu: CanvasLayer = load("res://game/logout_menu.gd").new()
	add_child_autofree(menu)
	menu.open(data, player, data.default_rules, "", world.prerequisites_of("p1"))
	var locked: Dictionary = menu._locked(Array(data.action_order, TYPE_STRING, "", null), data.actions)
	assert_true(locked.has("toll"))
	assert_eq(String(locked["toll"]), "braucht einen eigenen Claim (Anker)")
	assert_false(locked.has("attack"), "'greife an' ist nie gesperrt")
	menu.open(data, player, data.default_rules, "", {"own_claim": true, "own_sensor": false})
	assert_false(menu._locked(Array(data.action_order, TYPE_STRING, "", null), data.actions).has("toll"))
