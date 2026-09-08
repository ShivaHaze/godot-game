extends GutTest
## Namen nur in unmittelbarer Nähe: Anzeige, Chronik ("Unbekannter mit <Waffe>") und Stammdaten im Netz.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 171)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.facing = Vector2.RIGHT
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE
	world.spatial.rebuild(world.characters)


func test_knows_name_rules_and_description() -> void:
	var near := world.spawn_player(OPEN + Vector2(3, 0), "p2", "Nachbar")
	var far := world.spawn_player(OPEN + Vector2(8, 0), "p3", "Ferner")
	var own := world.spawn_player(OPEN + Vector2(12, 0), "p1", "Eigener")
	var wolf := world.spawn_wolf(OPEN + Vector2(12, 3))
	assert_true(world.knows_name(player, near), "innerhalb name_range")
	assert_false(world.knows_name(player, far), "zu weit weg")
	assert_true(world.knows_name(player, own), "eigene Leute immer")
	assert_true(world.knows_name(player, wolf), "Tiere immer")
	assert_eq(world.describe(player, near), "Nachbar")
	assert_eq(world.describe(player, far), "Unbekannter mit Schleuder")
	far.items.clear()
	world.refresh_equipment(far)
	assert_eq(world.describe(player, far), "Unbekannter mit bloßen Händen")
	far.inventory["copper"] = 2
	far.inventory["wood"] = 3
	world.spawn_building("workbench", Vector2i(28, 6), "p3")
	world.craft(far, "copper_spear")
	assert_eq(world.describe(player, far), "Unbekannter mit Kupferspeer")
	assert_eq(world.describe(player, null), "Unbekannt")


func test_chronicle_names_only_near_attackers() -> void:
	# Ferner Schütze: Opfer stirbt an einem Unbekannten
	var sniper := world.spawn_player(OPEN + Vector2(7, 0), "p2", "Schütze")
	sniper.facing = Vector2.LEFT
	var sniper_rules := data.normalize_rule_list([{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 2}}}], "Test")
	world.logout(sniper.id, sniper_rules, "Wache")
	player.hp = 1.0
	world.spatial.rebuild(world.characters)
	world.apply_damage(player, 10.0, Vector2.LEFT, sniper.id)
	assert_true(player.dead)
	var victim_lines := SimChronicle.format_all(player)
	assert_true(victim_lines[victim_lines.size() - 1].contains("gestorben durch Unbekannter mit Schleuder"), "Opfer: %s" % [victim_lines])
	var killer_lines := SimChronicle.format_all(sniper)
	assert_true(killer_lines[killer_lines.size() - 1].contains("Unbekannter mit Schleuder getötet"), "Täter kennt den Namen auch nicht: %s" % [killer_lines])
	# Naher Schlag: beide Seiten kennen sich
	var brawler := world.spawn_player(OPEN + Vector2(1, 0), "p3", "Schläger")
	var victim := world.spawn_player(OPEN + Vector2(2, 0), "p4", "Opfer")
	world.logout(brawler.id, sniper_rules, "Wache")
	victim.hp = 1.0
	world.apply_damage(victim, 10.0, Vector2.RIGHT, brawler.id)
	assert_true(SimChronicle.format_all(victim)[SimChronicle.format_all(victim).size() - 1].contains("gestorben durch Schläger"))
	assert_true(SimChronicle.format_all(brawler)[SimChronicle.format_all(brawler).size() - 1].contains("Opfer getötet"))
	# Wölfe erkennt man immer
	var wolf := world.spawn_wolf(OPEN + Vector2(-9, 0))
	var prey := world.spawn_player(OPEN + Vector2(-2, 0), "p5", "Beute")
	prey.hp = 1.0
	world.apply_damage(prey, 10.0, Vector2.RIGHT, wolf.id)
	assert_true(SimChronicle.format_all(prey)[SimChronicle.format_all(prey).size() - 1].contains("gestorben durch Wolf"))


func test_snapshot_reveals_name_only_in_range() -> void:
	var stranger := world.spawn_player(OPEN + Vector2(10, 0), "p2", "Geheim")
	world.tick()
	var known := {}
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(NetProtocol.snapshot(world, player.id, known, {}, {}))))
	assert_eq(mirror.get_character(stranger.id).name, "", "zu weit: Stammdaten ohne Name")
	assert_eq(known[stranger.id], false)
	assert_eq(mirror.get_character(player.id).name, "Du", "sich selbst kennt man")
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(NetProtocol.snapshot(world, player.id, known, {}, {}))))
	assert_eq(mirror.get_character(stranger.id).name, "", "bleibt unbekannt, keine erneuten Stammdaten")
	stranger.pos = OPEN + Vector2(3, 0)
	world.tick()
	var snap := NetProtocol.snapshot(world, player.id, known, {}, {})
	assert_eq(snap.get("intro", []).size(), 1, "Nachtrag mit Name")
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	assert_eq(mirror.get_character(stranger.id).name, "Geheim", "in Reichweite: Name bekannt")
	assert_eq(known[stranger.id], true)
	stranger.pos = OPEN + Vector2(10, 0)
	world.tick()
	snap = NetProtocol.snapshot(world, player.id, known, {}, {})
	assert_eq(snap.get("intro", []).size(), 0, "einmal gesehen bleibt bekannt")
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	assert_eq(mirror.get_character(stranger.id).name, "Geheim")
