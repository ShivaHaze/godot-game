extends GutTest
## Zustandseffekt Blutung: Klinge (Steinbeil) löst sie aus, ignoriert Rüstung, Verband stoppt sie.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter
var victim: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 111)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE
	victim = world.spawn_player(OPEN + Vector2(0.8, 0), "p2", "Opfer")
	victim.armor = 100.0  # Rüstung ist für den Effekt egal
	world.spatial.rebuild(world.characters)


func _axe_hit() -> void:
	player.inventory["stone"] = 2
	player.inventory["wood"] = 2
	assert_eq(world.craft(player, "stone_axe"), "")
	assert_true(world.set_active_weapon(player, "stone_axe"))
	player.facing = Vector2.RIGHT
	var intent := SimIntent.new()
	intent.melee = true
	world.set_intent(player.id, intent)
	world.tick()


func test_axe_causes_bleeding_that_ignores_armor_and_ends() -> void:
	var hp_before := victim.hp
	_axe_hit()
	assert_true(world.has_effect(victim, "bleeding"), "Steinbeil = Klinge")
	var after_hit := victim.hp
	assert_gte(after_hit, hp_before - float(data.bali("combat.min_damage")) - 0.1, "Rüstung fängt den Schlag ab")
	world.advance(4.0)
	assert_almost_eq(victim.hp, after_hit - 4.0 * data.balf("effects.bleeding.damage_per_second"), 0.15, "blutet trotz Rüstung")
	world.advance(data.balf("effects.bleeding.duration"))
	assert_false(world.has_effect(victim, "bleeding"), "läuft aus")
	assert_false(victim.effects.has("bleeding"), "Eintrag aufgeräumt")
	# Wolfsbiss löst keine Blutung aus
	var wolf := world.spawn_wolf(OPEN + Vector2(3, 0))
	wolf.control = SimCharacter.Controller.NONE
	world.apply_damage(player, wolf.melee_damage, Vector2.LEFT, wolf.id, wolf.melee_effect)
	assert_false(world.has_effect(player, "bleeding"))


func test_bandage_stops_bleeding_even_at_full_health() -> void:
	_axe_hit()
	victim.hp = victim.max_hp
	victim.inventory["bandage"] = 1
	var intent := SimIntent.new()
	intent.heal = true
	for i in 20 * 3 + 1:
		world.set_intent(victim.id, intent)
		world.tick()
	assert_false(world.has_effect(victim, "bleeding"), "Verband ist das Gegenmittel")
	assert_eq(int(victim.inventory["bandage"]), 0)


func test_npc_rule_bleeding_heals_itself() -> void:
	victim.inventory["bandage"] = 1
	world.unlock("p2", "owned_bandage", victim)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "bleeding"}, "then": {"action": "heal_self"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 2}}},
	], "Test")
	world.logout(victim.id, rules, "Wache")
	victim.logout_time = -1e9
	_axe_hit()  # Offline getroffen: die Chronik hält den Beginn fest
	victim.hp = victim.max_hp
	for i in 20 * 4:
		world.tick()
	assert_false(world.has_effect(victim, "bleeding"), "NPC hat sich verbunden")
	assert_eq(int(victim.inventory["bandage"]), 0)
	var lines := SimChronicle.format_all(victim)
	var seen_start := false
	var seen_rule := false
	for line: String in lines:
		if line.contains("blutet") and not line.contains("Regel"):
			seen_start = true
		if line.contains("blutet, Regel 1: verbunden"):
			seen_rule = true
	assert_true(seen_start and seen_rule, "Chronik: %s" % [lines])
	assert_eq(victim.active_rule_index, 1, "danach wieder Sonst")


func test_bleeding_can_kill_and_survives_save_and_snapshot() -> void:
	_axe_hit()
	victim.hp = 2.0
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_true(copy.has_effect(copy.get_character(victim.id), "bleeding"), "Spielstand trägt den Effekt")
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(NetProtocol.snapshot(world, player.id, {}, {}, {}))))
	assert_true(mirror.has_effect(mirror.get_character(victim.id), "bleeding"), "Snapshot zeigt Blutung")
	assert_eq(mirror.get_character(victim.id).control, SimCharacter.Controller.PLAYER, "Steuerung bleibt lesbar")
	world.logout(victim.id, data.roles["hide"]["rules"])
	world.advance(4.0)
	assert_true(victim.dead, "verblutet")
	var found := false
	for line: String in SimChronicle.format_all(victim):
		if line.contains("verblutet, zuletzt getroffen von Du"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(victim)])
