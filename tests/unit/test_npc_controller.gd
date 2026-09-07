extends GutTest
## NPC-Modus: Regelausführung, Leine, Chronik, Verstecken, Sammeln, Zurückkämpfen, Aus-/Einloggen.

const OPEN: Vector2 = Vector2(20.5, 5.5)
const PARKING: Vector2 = Vector2(38.5, 28.5)

var data: SimData
var world: SimWorld
var npc: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 5)
	npc = world.get_character(world.setup_new_game())
	npc.pos = OPEN
	npc.name = "NPC"
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = PARKING
			c.home_pos = PARKING
			c.ai_target_pos = PARKING
			c.control = SimCharacter.Controller.NONE


func _rules(role: String) -> Array:
	return data.roles[role]["rules"]


func _rule_list(list: Array) -> Array:
	return data.normalize_rule_list(list, "Test")


func _wolf() -> SimCharacter:
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			return c
	return null


func _tick(ticks: int, collect_type: String = "") -> Array:
	var collected := []
	for i in ticks:
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == collect_type:
				collected.append(event)
	return collected


func _max_distance_over(ticks: int, center: Vector2) -> float:
	var worst := 0.0
	for i in ticks:
		world.tick()
		worst = maxf(worst, npc.pos.distance_to(center))
	return worst


func test_logout_and_login_switch_control_and_log() -> void:
	world.logout(npc.id, _rules("guard"), "Wache")
	assert_eq(npc.control, SimCharacter.Controller.RULES)
	assert_eq(npc.logout_pos, OPEN)
	assert_eq(npc.leash_center, OPEN)
	assert_eq(npc.leash_radius, data.balf("npc.default_leash_radius"))
	assert_eq(npc.chronicle.size(), 1)
	assert_true(String(npc.chronicle[0]["text"]).begins_with("ausgeloggt als Wache"))
	_tick(5)
	world.login(npc.id)
	assert_eq(npc.control, SimCharacter.Controller.PLAYER)
	assert_true(String(npc.chronicle[npc.chronicle.size() - 1]["text"]).begins_with("eingeloggt"))


func test_guard_stays_and_logs_rule_once() -> void:
	world.logout(npc.id, _rules("guard"), "Wache")
	var worst := _max_distance_over(200, OPEN)
	assert_lte(worst, 4.0, "bleibt in der Leine der Sonst-Regel (Radius 4)")
	assert_eq(npc.active_rule_index, 3, "Sonst-Regel aktiv")
	assert_eq(npc.chronicle.size(), 2, "ausgeloggt + einmal 'sonst', kein Spam")
	assert_eq(SimChronicle.format_all(npc)[1].substr(8), "sonst, Regel 4: geblieben bei Hier")


func test_stay_at_marker_moves_there_and_then_holds_leash() -> void:
	npc.markers.append({"id": "m1", "name": "Lager", "pos": OPEN + Vector2(8, 0)})
	var rules := _rule_list([{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "m1", "radius": 2}}}])
	world.logout(npc.id, rules)
	_tick(20 * 4)
	assert_lte(npc.pos.distance_to(OPEN + Vector2(8, 0)), 2.0, "am Marker angekommen")
	assert_eq(npc.leash_center, OPEN + Vector2(8, 0))
	assert_eq(npc.leash_radius, 2.0)
	var worst := _max_distance_over(200, OPEN + Vector2(8, 0))
	assert_lte(worst, 2.0, "verlässt die Leine nie")


func test_fight_back_never_leaves_leash_but_shoots() -> void:
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	world.logout(npc.id, rules)
	_tick(5)
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(9, 0)  # weit außerhalb der Leine
	wolf.facing = Vector2.LEFT
	world.apply_damage(npc, 1.0, Vector2.LEFT, wolf.id)
	var shots := 0
	var worst := 0.0
	for i in 100:
		world.tick()
		worst = maxf(worst, npc.pos.distance_to(OPEN))
		for event: Dictionary in world.events:
			if event.get("type") == "shoot" and event.get("id") == npc.id:
				shots += 1
	assert_eq(npc.active_rule_index, 0, "kämpft zurück")
	assert_gt(shots, 0, "schießt")
	assert_lte(worst, 3.01, "Leine bleibt beim Zurückkämpfen bestehen (Sonst-Regel, Radius 3)")
	assert_almost_eq(npc.facing.angle_to((wolf.pos - npc.pos).normalized()), 0.0, 0.05, "dreht sich zur Bedrohung")
	assert_lt(wolf.hp, wolf.max_hp, "trifft")
	assert_eq(SimChronicle.format_all(npc)[2].substr(8), "angegriffen, Regel 1: zurückgekämpft")


func test_flee_to_here_when_attacked() -> void:
	world.logout(npc.id, _rules("gatherer"), "Sammler")
	npc.pos = OPEN + Vector2(5, 0)
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(7, 0)
	world.apply_damage(npc, 1.0, Vector2.LEFT, wolf.id)
	_tick(40)
	assert_eq(npc.active_rule_index, 1, "angegriffen -> fliehe zu Hier")
	assert_lt(npc.pos.distance_to(OPEN), 2.0, "in der Fluchtleine angekommen")
	var lines := SimChronicle.format_all(npc)
	assert_true(lines[lines.size() - 1].ends_with("angegriffen, Regel 2: geflohen zu Hier"), lines[lines.size() - 1])


func test_eat_when_hungry_logs_details() -> void:
	npc.inventory["berries"] = 4
	npc.hunger = 10.0
	world.logout(npc.id, _rules("guard"))
	_tick(2)
	assert_eq(npc.inventory["berries"], 3)
	assert_almost_eq(npc.hunger, 35.0, 0.1)
	assert_eq(SimChronicle.format_all(npc)[1].substr(8), "hungrig, Regel 3: gegessen (Beeren 4→3)")
	_tick(40)
	assert_eq(npc.inventory["berries"], 3, "satt genug: isst nicht weiter")
	assert_eq(npc.active_rule_index, 3, "zurück zur Sonst-Regel")


func test_eat_without_food_is_skipped_once() -> void:
	npc.hunger = 5.0
	var rules := _rule_list([
		{"if": {"condition": "hungry"}, "then": {"action": "eat"}},
		{"if": {"condition": "else"}, "then": {"action": "hide"}},
	])
	world.logout(npc.id, rules)
	_tick(60)
	assert_eq(npc.active_rule_index, 1, "fällt auf 'verstecken' durch")
	var skipped := 0
	for line: String in SimChronicle.format_all(npc):
		if line.contains("nicht möglich, übersprungen"):
			skipped += 1
	assert_eq(skipped, 1, "genau einmal vermerkt")


func test_hide_becomes_hidden_and_is_discovered() -> void:
	var rules := _rule_list([{"if": {"condition": "else"}, "then": {"action": "hide"}}])
	world.logout(npc.id, rules, "Verstecken")
	_tick(ceili(data.balf("npc.hide_delay") / world.tick_dt) + 2)
	assert_true(npc.hidden, "versteckt")
	assert_eq(_tick(20).size(), 0)
	assert_true(npc.hidden, "bleibt versteckt, solange niemand kommt")
	var wolf := _wolf()
	wolf.pos = npc.pos + Vector2(0.5, 0)
	var found := _tick(1, "discovered")
	assert_eq(found.size(), 1, "Wolf läuft drüber")
	assert_false(npc.hidden)


func test_gatherer_collects_berries_within_leash() -> void:
	npc.pos = Vector2(25.5, 5.5)  # Beerenbüsche bei (27, 2) und (28, 2)
	world.logout(npc.id, _rules("gatherer"), "Sammler")
	_tick(20 * 12)
	assert_gt(int(npc.inventory["berries"]), 0, "hat Beeren gesammelt")
	assert_eq(npc.active_rule_index, 4)
	assert_eq(SimChronicle.format_all(npc)[1].substr(8), "sonst, Regel 5: gesammelt: Beeren um Hier")
	assert_lte(npc.pos.distance_to(Vector2(25.5, 5.5)), 8.0)


func test_gather_falls_through_when_nothing_in_leash() -> void:
	var rules := _rule_list([
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "berries", "place": "here", "radius": 2}}},
	])
	world.logout(npc.id, rules)
	_tick(20)
	assert_eq(npc.active_rule_index, RuleEngine.NO_MATCH, "keine ausführbare Regel: steht")
	assert_eq(npc.pos, OPEN)


func test_hungry_npc_eats_offline_over_time() -> void:
	npc.inventory["berries"] = 2
	npc.hunger = data.balf("hunger.hungry_threshold") + 0.2
	world.logout(npc.id, _rules("guard"))
	var seconds_until_hungry := 0.3 / data.balf("hunger.decay_per_second_offline")
	_tick(ceili(seconds_until_hungry / world.tick_dt) + 10)
	assert_eq(npc.inventory["berries"], 1, "hat unterwegs gegessen")


func test_resuming_same_rule_after_pause_is_not_logged_again() -> void:
	npc.pos = Vector2(25.5, 5.5)
	var rules := _rule_list([
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "berries", "place": "here", "radius": 3.5}}},
	])
	world.logout(npc.id, rules)
	_tick(20 * 30)  # beide Büsche in der Leine leeren
	assert_eq(npc.active_rule_index, RuleEngine.NO_MATCH, "nichts mehr zu sammeln")
	var lines_before := npc.chronicle.size()
	for node: SimResourceNode in world.map.nodes.values():
		node.amount = node.max_amount  # nachgewachsen
	_tick(20 * 2)
	assert_eq(npc.active_rule_index, 0, "sammelt wieder")
	assert_eq(npc.chronicle.size(), lines_before, "dieselbe Regel wird nicht erneut protokolliert")
