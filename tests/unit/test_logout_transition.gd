extends GutTest
## Logout-Übergang: Ausloggen macht nie sofort sicher.

var data: SimData
var world: SimWorld
var npc: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 8)
	world.lod_enabled = false  # Feinsimulation für nachvollziehbare Zeiten
	npc = world.get_character(world.setup_new_game())
	npc.pos = Vector2(20.5, 5.5)
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _hide_rules() -> Array:
	return data.normalize_rule_list([{"if": {"condition": "else"}, "then": {"action": "hide"}}], "Test")


func test_cannot_hide_during_transition() -> void:
	world.logout(npc.id, _hide_rules(), "Verstecken")
	var transition := data.balf("logout.transition_seconds")
	assert_true(world.in_transition(npc))
	assert_almost_eq(world.transition_end(npc), transition, 0.001, "ohne Kampf: Übergang ab dem Ausloggen")
	world.advance(transition - 1.0)
	assert_false(npc.hidden, "während des Übergangs sichtbar")
	assert_true(world.in_transition(npc))
	world.advance(1.0 + data.balf("npc.hide_delay") + 1.0)
	assert_false(world.in_transition(npc))
	assert_true(npc.hidden, "danach versteckt")
	var lines := SimChronicle.format_all(npc)
	var has_end := false
	var has_skip := false
	for line: String in lines:
		if line.contains("Übergang beendet"):
			has_end = true
		if line.contains("Logout-Übergang läuft"):
			has_skip = true
	assert_true(has_skip, "Chronik nennt den Grund: %s" % lines)
	assert_true(has_end, "Chronik vermerkt das Ende: %s" % lines)


func test_damage_delays_transition() -> void:
	world.logout(npc.id, _hide_rules(), "Verstecken")
	world.advance(10.0)
	SimCombat.apply_damage(world, npc, 1.0, Vector2.LEFT, -1)
	var expected := 10.0 + data.balf("logout.combat_window") + data.balf("logout.transition_seconds")
	assert_almost_eq(world.transition_end(npc), expected, 0.01, "Kampf schiebt den Übergang hinaus")
	world.advance(expected - 10.0 - 1.0)
	assert_true(world.in_transition(npc))
	assert_false(npc.hidden)


func test_combat_before_logout_counts() -> void:
	world.advance(30.0)
	SimCombat.apply_damage(world, npc, 1.0, Vector2.LEFT, -1)
	world.advance(20.0)
	world.logout(npc.id, _hide_rules())
	var expected := 30.0 + data.balf("logout.combat_window") + data.balf("logout.transition_seconds")
	assert_almost_eq(world.transition_end(npc), expected, 0.01)


func test_transition_irrelevant_once_logged_in() -> void:
	world.logout(npc.id, _hide_rules())
	world.login(npc.id)
	assert_false(world.in_transition(npc))
