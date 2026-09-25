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
	world.lod_enabled = false  # Feinsimulation für nachvollziehbare Zeiten
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
	SimCombat.apply_damage(world, npc, 1.0, Vector2.LEFT, wolf.id)
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
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "flee_to", "params": {"place": "here", "radius": 2}}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 8}}},
	])
	world.logout(npc.id, rules, "Test")
	npc.pos = OPEN + Vector2(5, 0)
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(7, 0)
	SimCombat.apply_damage(world, npc, 1.0, Vector2.LEFT, wolf.id)
	_tick(40)
	assert_eq(npc.active_rule_index, 0, "angegriffen -> fliehe zu Hier")
	assert_lt(npc.pos.distance_to(OPEN), 2.0, "in der Fluchtleine angekommen")
	var lines := SimChronicle.format_all(npc)
	assert_true(lines[lines.size() - 1].ends_with("angegriffen, Regel 1: geflohen zu Hier"), lines[lines.size() - 1])


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
	npc.logout_time = -1e9  # Übergang für diesen Test überspringen
	_tick(60)
	assert_eq(npc.active_rule_index, 1, "fällt auf 'verstecken' durch")
	var skipped := 0
	for line: String in SimChronicle.format_all(npc):
		if line.contains("nicht möglich: nichts Essbares, übersprungen"):
			skipped += 1
	assert_eq(skipped, 1, "genau einmal vermerkt")


func test_hide_becomes_hidden_and_is_discovered() -> void:
	var rules := _rule_list([{"if": {"condition": "else"}, "then": {"action": "hide"}}])
	world.logout(npc.id, rules, "Verstecken")
	npc.logout_time = -1e9  # Übergang für diesen Test überspringen
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


## Zählt Treffer, bei denen Opfer und Angreifer beide in `ids` stehen (Kampf zwischen diesen Charakteren).
func _crossfire(ids: Array[int]) -> int:
	var n := 0
	for event: Dictionary in world.events:
		if event.get("type") == "hit" and ids.has(int(event["id"])) and ids.has(int(event["attacker"])):
			n += 1
	return n


## Befund Schritt 54: zwei fremde Offline-Charaktere nebeneinander, ein Wolf beißt einen und stirbt. Danach darf der
## Kampf nicht auf den Nachbarn überspringen – Ersatzziel sind nur Tiere, nie unbeteiligte Menschen.
func test_fight_back_never_turns_on_uninvolved_neighbour() -> void:
	var neighbour := world.spawn_player(OPEN + Vector2(1.5, 0), "p2", "Nachbar")
	for c: SimCharacter in [npc, neighbour]:
		world.logout(c.id, _rules("guard"), "Wache")
		c.logout_time = -1e9  # Übergang für diesen Test überspringen
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(-0.5, 3.0)  # näher am NPC als am Nachbarn
	wolf.home_pos = wolf.pos
	wolf.control = SimCharacter.Controller.WOLF_AI
	var ids: Array[int] = [npc.id, neighbour.id]
	var crossfire := 0
	var bitten := false
	for i in 20 * 10:
		world.tick()
		crossfire += _crossfire(ids)
		for event: Dictionary in world.events:
			if event.get("type") == "hit" and int(event["id"]) == npc.id and int(event["attacker"]) == wolf.id:
				bitten = true
		if bitten:
			break
	assert_true(bitten, "der Wolf beißt den NPC")
	# Der Wolf stirbt, während der NPC noch 'angegriffen' ist: kein lebender Angreifer mehr, der Nachbar steht daneben
	SimCombat.apply_damage(world, wolf, 1000.0, Vector2.DOWN, npc.id)
	assert_true(wolf.dead)
	var shots_after := 0
	for i in 20 * 8:
		world.tick()
		crossfire += _crossfire(ids)
		for event: Dictionary in world.events:
			if event.get("type") == "shoot" and int(event["id"]) == npc.id:
				shots_after += 1
	assert_eq(crossfire, 0, "die beiden Offline-Charaktere treffen sich nie")
	assert_eq(shots_after, 0, "ohne lebenden Angreifer und ohne Tier: kein Schuss")
	assert_eq(neighbour.hp, neighbour.max_hp, "der Nachbar bleibt unverletzt")


## Vorsichtig schießen: steht ein Unbeteiligter in der Schusslinie, hält der NPC das Feuer; ist die Linie frei, schießt er.
## Der NPC wird hier jeden Tick an seinen Platz zurückgesetzt – sonst träte er zur Seite, bis die Linie frei ist
## (test_sidesteps_to_clear_line_of_fire).
func test_holds_fire_while_bystander_in_line_of_fire() -> void:
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(6, 0)  # steht still (Steuerung aus)
	var bystander := world.spawn_player(OPEN + Vector2(3, 0), "p2", "Passant")
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 20 * 2:
		_attacked_by(wolf)
		npc.pos = OPEN
		world.tick()
		shots += _tick_shots()
	assert_eq(npc.active_rule_index, 0, "kämpft zurück")
	assert_eq(shots, 0, "Passant in der Schusslinie: kein Schuss")
	assert_eq(bystander.hp, bystander.max_hp)
	bystander.pos = OPEN + Vector2(9, 0)  # hinter dem Ziel, noch in Reichweite: ein Fehlschuss träfe ihn
	for i in 20:
		_attacked_by(wolf)
		npc.pos = OPEN
		world.tick()
		shots += _tick_shots()
	assert_eq(shots, 0, "auch hinter dem Ziel in Reichweite: kein Schuss")
	bystander.pos = OPEN + Vector2(3, 4)  # aus der Linie getreten
	for i in 20 * 2:
		_attacked_by(wolf)
		npc.pos = OPEN
		world.tick()
		shots += _tick_shots()
	assert_gt(shots, 0, "Linie frei: er schießt")
	assert_lt(wolf.hp, wolf.max_hp, "und trifft den Wolf")
	assert_eq(bystander.hp, bystander.max_hp, "den Passanten nie")


## Befund Schritt 54 (Review): der Wolf direkt vor dem NPC, der Nachbar vier Kacheln dahinter auf derselben Linie – der
## NPC hielt das Feuer, wich rückwärts aus, der Wolf folgte auf der Linie, und er starb ohne einen Schuss. So nah fängt
## das Ziel den Schuss ab: dahinter zählt niemand.
func test_close_target_shields_bystander_behind_it() -> void:
	var neighbour := world.spawn_player(OPEN + Vector2(4, 0), "p2", "Nachbar")
	for c: SimCharacter in [npc, neighbour]:
		world.logout(c.id, _rules("guard"), "Wache")
		c.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(1.2, 0)
	wolf.home_pos = wolf.pos
	wolf.ai_target_pos = wolf.pos
	wolf.control = SimCharacter.Controller.WOLF_AI
	world.spatial.rebuild(world.characters)
	var ids: Array[int] = [npc.id, neighbour.id]
	var crossfire := 0
	var shots := 0
	for i in 20 * 15:
		world.tick()
		crossfire += _crossfire(ids)
		shots += _tick_shots()
		if wolf.dead or npc.dead or wolf.ai_state == WolfAI.STATE_FLEE:
			break
	assert_gt(shots, 0, "er schießt auf den Wolf vor sich")
	assert_false(npc.dead, "und überlebt")
	assert_true(wolf.dead or wolf.ai_state == WolfAI.STATE_FLEE, "der Wolf stirbt oder flieht")
	assert_eq(crossfire, 0, "der Nachbar bleibt unberührt")


## Steht ein Unbeteiligter hinter einem Ziel auf Abstand in der Linie, tritt der NPC zur Seite, bis die Linie frei ist,
## statt stumm stehen zu bleiben.
func test_sidesteps_to_clear_line_of_fire() -> void:
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	var spot := Vector2(5.5, 17.5)  # freies Feld: kein Baum, der die Linie nach dem Seitenschritt verdeckt
	npc.pos = spot
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = spot + Vector2(5, 0)  # steht still (Steuerung aus)
	var bystander := world.spawn_player(spot + Vector2(8, 0), "p2", "Passant")
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 20 * 2:
		_attacked_by(wolf)
		world.tick()
		shots += _tick_shots()
	assert_gt(absf(npc.pos.y - spot.y), 0.5, "zur Seite getreten")
	assert_gt(shots, 0, "dann geschossen")
	assert_lt(wolf.hp, wolf.max_hp, "und den Wolf getroffen")
	assert_eq(bystander.hp, bystander.max_hp, "den Passanten nie")


## Wen hinter dem Ziel eine Wand deckt, der blockiert die Schusslinie nicht: dort endet das Projektil.
func test_bystander_behind_wall_does_not_block_fire() -> void:
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	var spot := Vector2(24.5, 2.5)
	npc.pos = spot
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = Vector2(24.5, 5.5)  # drei Kacheln südlich, steht still
	wolf.max_hp = 1000.0
	wolf.hp = 1000.0
	var bystander := world.spawn_player(Vector2(24.5, 6.5), "p2", "Passant")  # hinter dem Wolf, ungedeckt
	assert_false(world.map.is_walkable(Vector2i(24, 7)), "Baum zwischen (24, 6) und (24, 8)")
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 20:
		_attacked_by(wolf)
		npc.pos = spot  # festhalten: kein Seitenschritt
		world.tick()
		shots += _tick_shots()
	assert_eq(shots, 0, "ungedeckt hinter dem Ziel: kein Schuss")
	bystander.pos = Vector2(24.5, 8.5)  # hinter dem Baum
	for i in 20:
		_attacked_by(wolf)
		npc.pos = spot
		world.tick()
		shots += _tick_shots()
	assert_gt(shots, 0, "hinter dem Baum gedeckt: er schießt")
	assert_lt(wolf.hp, wolf.max_hp)
	assert_eq(bystander.hp, bystander.max_hp)


## Befund Schritt 54 (Review): nach dem Tod des Angreifers schoss der NPC auf einen streunenden Wolf 9 Kacheln weiter,
## der ihn gar nicht beachtete – der Treffer machte ihn erst zum Angreifer. Ersatzziel ist nur ein Wolf in Aggro-Reichweite.
func test_fight_back_ignores_wandering_wolf_out_of_aggro_range() -> void:
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(-9, 0)  # streunt (Steuerung aus), außerhalb von wolf.aggro_radius
	assert_gt(9.0, data.balf("wolf.aggro_radius"))
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 20 * 2:
		npc.last_damage_time = world.time  # von einem Turret getroffen: kein Schütze
		npc.last_attacker_id = -1
		world.tick()
		shots += _tick_shots()
	assert_eq(npc.active_rule_index, 0, "kämpft zurück")
	assert_eq(shots, 0, "der ferne Wolf ist kein Ersatzziel")
	assert_eq(wolf.hp, wolf.max_hp)
	wolf.pos = OPEN + Vector2(-5, 0)  # in Aggro-Reichweite: er greift ohnehin gleich an
	for i in 20 * 2:
		npc.last_damage_time = world.time
		npc.last_attacker_id = -1
		world.tick()
		shots += _tick_shots()
	assert_gt(shots, 0, "der nahe Wolf ist Ersatzziel")


## Befund Schritt 54 (Review): last_attacker_id veraltete nie. Mit "Fremder in Nähe → kämpfe zurück" beschoss der NPC
## den Menschen, der ihn Stunden vorher getroffen hatte. Angreifer ist nur, wer innerhalb von 'wird angegriffen' traf.
func test_fight_back_ignores_stale_attacker() -> void:
	var rules := _rule_list([
		{"if": {"condition": "stranger_near", "params": {"radius": 10}}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	var old_foe := world.spawn_player(OPEN + Vector2(5, 0), "p2", "Alter Feind")
	npc.last_attacker_id = old_foe.id
	npc.last_damage_time = -1e6  # vor langer Zeit
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	world.spatial.rebuild(world.characters)
	var hits_on_foe := 0
	var shots := 0
	for i in 20 * 2:
		world.tick()
		shots += _tick_shots()
		hits_on_foe += _crossfire([npc.id, old_foe.id] as Array[int])
	assert_eq(npc.active_rule_index, 0, "Fremder in Nähe: kämpfe zurück")
	assert_eq(shots, 0, "kein aktueller Angreifer, kein Tier: kein Schuss")
	assert_eq(hits_on_foe, 0)
	assert_lt(npc.pos.distance_to(OPEN), 0.5, "geht nicht auf ihn zu")
	# Trifft er jetzt, ist er wieder Angreifer
	SimCombat.apply_damage(world, npc, 1.0, Vector2.LEFT, old_foe.id)
	for i in 20 * 2:
		world.tick()
		shots += _tick_shots()
	assert_gt(shots, 0, "frischer Treffer: er wehrt sich")


## Wer in einer kampffreien Zone steht, blockiert die Schusslinie nicht: dort verpuffen Projektile (Befund Schritt 54:
## ein Händler am Markt hielt das Feuer, solange die Karawane dort rastete, und starb am Wolf davor).
func test_bystander_in_peace_zone_does_not_block_fire() -> void:
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	npc.pos = Vector2(17.5, 27.5)
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = Vector2(21.5, 27.5)  # vor dem Markt, steht still
	var bystander := world.spawn_player(Vector2(24.5, 27.5), "p2", "Marktbesucher")  # hinter dem Wolf, auf dem Markt
	assert_true(world.in_peace_zone(bystander.pos), "steht auf dem Markt")
	assert_false(world.in_peace_zone(wolf.pos))
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 20 * 2:
		_attacked_by(wolf)
		world.tick()
		shots += _tick_shots()
	assert_gt(shots, 0, "schießt trotz des Marktbesuchers in der Linie")
	assert_lt(wolf.hp, wolf.max_hp, "und trifft den Wolf")
	assert_eq(bystander.hp, bystander.max_hp)
	bystander.pos = Vector2(22.5, 27.5)  # jetzt vor dem Markt, hinter dem Wolf
	assert_false(world.in_peace_zone(bystander.pos))
	var spot := npc.pos
	for i in 20:
		world.tick()  # fliegende Projektile landen lassen
	var later := 0
	for i in 20 * 2:
		_attacked_by(wolf)
		npc.pos = spot  # festhalten: kein Seitenschritt
		world.tick()
		later += _tick_shots()
	assert_eq(later, 0, "außerhalb des Marktes blockiert er wieder")


## Hält den NPC 'angegriffen' von diesem Angreifer, ohne ihm Leben zu nehmen (Treffer ohne Schaden gibt es nicht).
func _attacked_by(attacker: SimCharacter) -> void:
	npc.last_damage_time = world.time
	npc.last_attacker_id = attacker.id


func _tick_shots() -> int:
	var n := 0
	for event: Dictionary in world.events:
		if event.get("type") == "shoot" and int(event["id"]) == npc.id:
			n += 1
	return n


## Nahkampf eines Offline-Charakters trifft das Ziel, das er bekämpft – nicht den Unbeteiligten, der näher steht.
func test_melee_hits_engaged_target_not_closer_bystander() -> void:
	npc.items.append("club")
	npc.durability["club"] = {"left": float(data.items["club"]["durability"]), "max": float(data.items["club"]["durability"])}
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(0.8, 0)  # in Keulenreichweite
	var bystander := world.spawn_player(OPEN + Vector2(-0.6, 0), "p2", "Passant")  # noch näher, andere Seite
	world.spatial.rebuild(world.characters)
	var victims := {}
	for i in 20 * 3:
		_attacked_by(wolf)
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "hit" and int(event["attacker"]) == npc.id:
				victims[int(event["id"])] = true
	assert_eq(npc.active_weapon, "club", "Keule gegen den Feind in Reichweite")
	assert_true(victims.has(wolf.id), "trifft den Wolf")
	assert_false(victims.has(bystander.id), "nie den Passanten")
	assert_eq(bystander.hp, bystander.max_hp)


## Sichtlinie ab der Mündung: mit dem Rücken an einem Baum (Befund Schritt 54: die Sichtlinie ab der Körpermitte streifte
## den Baum) schießt der NPC trotzdem auf den Wolf vor sich.
func test_shoots_with_back_against_a_tree() -> void:
	var rules := _rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	])
	var spot := Vector2(22.95, 6.5)  # dicht am Baum auf (23, 6)
	assert_false(world.map.is_walkable(Vector2i(23, 6)))
	assert_false(SimNav.line_clear(world.map, spot, Vector2(22.75, 5.7), 0.1), "ab der Körpermitte streift die Linie den Baum")
	npc.pos = spot
	world.logout(npc.id, rules)
	npc.logout_time = -1e9
	var wolf := _wolf()
	wolf.pos = Vector2(22.75, 5.7)  # direkt vor ihm, steht still
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 20:
		_attacked_by(wolf)
		npc.pos = spot
		world.tick()
		shots += _tick_shots()
	assert_gt(shots, 0, "er schießt")
	assert_lt(wolf.hp, wolf.max_hp, "und trifft")
