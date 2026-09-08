extends GutTest
## Zoll: Eigentümer-NPCs verlangen von Fremden im Claim Zoll (Regel-Aktion), merken sich Zollschuld über Besuche hinweg,
## greifen Zollpreller im Claim an; Zahlung per E gibt Freigang (kein 'Fremder im Claim', Turrets verschonen).

const OPEN: Vector2 = Vector2(20.5, 5.5)
const INSIDE: Vector2 = Vector2(19.5, 5.5)   # Kachel (19, 5) im Claim
const OUTSIDE: Vector2 = Vector2(15.5, 8.5)  # außerhalb, nicht in der Schusslinie

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 421)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.inventory["wood"] = 30
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


## Anker auf (22, 5) und ein Block 18..21 × 4..6 als Claim; Zöllner loggt bei OPEN aus.
func _claim_and_keeper(rules: Array = []) -> SimClaim:
	assert_not_null(SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0))
	# Kacheln müssen angrenzen: von innen nach außen
	for x in [21, 20, 19, 18]:
		assert_true(world.claims.claim_tile(world, player, Vector2i(x, 5)), "Kachel (%d, 5): %s" % [x, world.claims.claim_tile_reason(world, player, Vector2i(x, 5))])
	for x in [21, 20, 19, 18]:
		world.claims.claim_tile(world, player, Vector2i(x, 4))
		world.claims.claim_tile(world, player, Vector2i(x, 6))
	var claim := world.claims.claim_of_owner("p1")
	if rules.is_empty():
		rules = data.normalize_rule_list([
			{"if": {"condition": "stranger_in_claim"}, "then": {"action": "toll", "params": {"resource": "wood", "amount": 2}}},
			{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 4}}},
		], "Test")
	world.logout(player.id, rules, "Zöllner")
	player.logout_time = -1e9
	return claim


func _events(kind: String) -> Array:
	var result := []
	for event: Dictionary in world.events:
		if event.get("type") == kind:
			result.append(event)
	return result


func _tick(n: int, stranger: SimCharacter = null, intent: SimIntent = null, kind: String = "") -> Array:
	var collected := []
	for i in n:
		if stranger != null and intent != null:
			world.set_intent(stranger.id, intent)
		world.tick()
		if not kind.is_empty():
			collected.append_array(_events(kind))
	return collected


func test_toll_action_needs_own_claim() -> void:
	assert_true(data.actions.has("toll"))
	assert_false(world.can_use(player, data.action_def("toll")), "ohne Claim nicht verfügbar")
	SimConstruction.place_building(world, player, "anchor", Vector2i(44, 10), 0)
	assert_true(world.can_use(player, data.action_def("toll")), "mit Claim verfügbar")
	var def := data.action_def("toll")
	assert_eq(data.format_template(String(def["label"]), def["params"], {"resource": "wood", "amount": 2}), "verlange Zoll: 2 Holz")


func test_demand_and_payment_give_pass() -> void:
	var claim := _claim_and_keeper()
	var stranger := world.spawn_player(INSIDE, "p2", "Anna")
	stranger.inventory["wood"] = 5
	var demands := _tick(6, null, null, "toll_demand")
	assert_eq(demands.size(), 1, "eine Forderung")
	assert_eq(int(demands[0]["target"]), stranger.id)
	assert_eq(String(demands[0]["resource"]), "wood")
	assert_eq(int(demands[0]["amount"]), 2)
	var lines := SimChronicle.format_all(player)
	var found := false
	for line: String in lines:
		if line.contains("Fremder im Claim, Regel 1: Zoll verlangt: 2 Holz (von Anna)"):
			found = true
	assert_true(found, "Chronik: %s" % [lines])
	assert_gt(float(claim.toll["p2"]["debt"]), 0.0, "Schuld läuft")
	# Zahlen per E beim Zöllner
	var pay := SimIntent.new()
	pay.interact = true
	var paid := _tick(1, stranger, pay, "toll_paid")
	assert_eq(paid.size(), 1, "gezahlt")
	assert_eq(int(stranger.inventory["wood"]), 3)
	assert_eq(int(player.inventory["wood"]), 30 - 10 - 12 + 2, "Zöllner hat den Zoll: %s" % [player.inventory])
	assert_true(SimToll.has_toll_pass(world, claim, "p2"), "Freigang")
	assert_eq(float(claim.toll["p2"]["debt"]), 0.0)
	assert_false(SimSensors.stranger_in_claim(world, player), "zahlende Gäste sind keine Fremden im Claim")
	found = false
	for line: String in SimChronicle.format_all(player):
		if line.contains("Zoll kassiert: 2 Holz von Anna (Freigang 2 h)"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
	# Mit Freigang: kein Angriff, auch nach der Frist; Zöllner fällt auf 'bleib bei Hier'
	world.advance(20.0)
	assert_eq(stranger.hp, stranger.max_hp, "unversehrt")
	assert_eq(String(player.rules[player.active_rule_index]["then"]["action"]), "stay_at")
	# Freigang läuft nach pass_hours ab
	assert_almost_eq(float(claim.toll["p2"]["paid_until"]), world.time - 20.0 + data.balf("toll.pass_hours") * 3600.0, 1.0)
	claim.toll["p2"]["paid_until"] = world.time - 1.0
	assert_false(SimToll.has_toll_pass(world, claim, "p2"))


func test_evader_is_attacked_and_remembered() -> void:
	var claim := _claim_and_keeper()
	var stranger := world.spawn_player(INSIDE, "p2", "Anna")
	stranger.facing = Vector2.RIGHT
	stranger.max_hp = 1000.0  # soll den Zöllner überleben, um wiederzukommen (drei Schleudertreffer töten sonst)
	stranger.hp = stranger.max_hp
	var grace := data.balf("toll.grace_seconds")
	var attacks := _tick(int(grace * 20) - 2, null, null, "toll_attack")
	assert_eq(attacks.size(), 0, "vor der Frist kein Angriff")
	assert_eq(stranger.hp, stranger.max_hp)
	attacks = _tick(40, null, null, "toll_attack")
	assert_eq(attacks.size(), 1, "nach der Frist: Angriff")
	assert_true(bool(claim.toll["p2"]["attacking"]))
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("Zoll geprellt: Anna – Angriff"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
	_tick(30)
	assert_lt(stranger.hp, stranger.max_hp, "Zöllner schießt")
	# Draußen ist Ruhe: 'Fremder im Claim' ist falsch, Zöllner bleibt
	var hp := stranger.hp
	stranger.pos = OUTSIDE
	world.spatial.rebuild(world.characters)
	world.advance(60.0)
	assert_eq(String(player.rules[player.active_rule_index]["then"]["action"]), "stay_at")
	assert_gte(stranger.hp, hp, "draußen kein Schaden mehr (eher natürliche Heilung)")
	# Wiederkommen nach einer Weile: die Schuld ist gemerkt, Angriff auf Sicht
	world.advance(120.0)
	stranger.hp = stranger.max_hp
	stranger.pos = INSIDE
	world.spatial.rebuild(world.characters)
	var demands := _tick(40, null, null, "toll_demand")
	assert_eq(demands.size(), 0, "keine neue Forderung – die alte Schuld gilt")
	assert_lt(stranger.hp, stranger.max_hp, "sofort beschossen")
	# Nach der Verjährung ohne Besuch: frische Forderung
	stranger.pos = OUTSIDE
	world.spatial.rebuild(world.characters)
	world.advance(10.0)
	claim.toll["p2"]["last_seen"] = world.time - data.balf("toll.forget_hours") * 3600.0 - 60.0  # lange nicht gesehen (Test kürzt ab)
	stranger.hp = stranger.max_hp
	stranger.pos = INSIDE
	world.spatial.rebuild(world.characters)
	demands = _tick(6, null, null, "toll_demand")
	assert_eq(demands.size(), 1, "Schuld verjährt: neue Forderung")
	assert_lt(float(claim.toll["p2"]["debt"]), 1.0)


func test_running_through_accumulates_debt_across_visits() -> void:
	var claim := _claim_and_keeper()
	var stranger := world.spawn_player(INSIDE, "p2", "Anna")
	_tick(100)  # 5 s drin
	assert_almost_eq(float(claim.toll["p2"]["debt"]), 5.0, 0.3)
	assert_false(bool(claim.toll["p2"]["attacking"]), "durchgerannt, noch kein Angriff")
	stranger.pos = OUTSIDE
	world.spatial.rebuild(world.characters)
	world.advance(60.0)
	assert_almost_eq(float(claim.toll["p2"]["debt"]), 5.0, 0.3, "Schuld bleibt")
	stranger.pos = INSIDE
	world.spatial.rebuild(world.characters)
	var attacks := _tick(80, null, null, "toll_attack")  # 4 s: 5 + 4 > 8
	assert_eq(attacks.size(), 1, "beim zweiten Besuch reicht die Restfrist nicht mehr")


func test_blocked_reasons_and_save() -> void:
	var claim := _claim_and_keeper()
	# Ein Wolf zählt als 'Fremder im Claim', ist aber nicht zollpflichtig: die Regel fällt mit Grund durch
	var wolf := world.spawn_wolf(INSIDE)
	wolf.control = SimCharacter.Controller.NONE
	assert_true(SimToll.toll_liable_in_claim(world, player, claim).is_empty())
	_tick(10)
	var lines := SimChronicle.format_all(player)
	var found := false
	for line: String in lines:
		if line.contains("nicht möglich: kein Mensch ohne Freigang im Claim, übersprungen"):
			found = true
	assert_true(found, "Chronik: %s" % [lines])
	wolf.pos = Vector2(38.5, 28.5)
	world.spatial.rebuild(world.characters)
	# Voller Zöllner kann nicht kassieren
	var stranger := world.spawn_player(INSIDE + Vector2(0, 1), "p2", "Anna")
	player.inventory["wood"] = data.bali("inventory.capacity")
	assert_eq(NpcController.blocked_reason(world, player, player.rules[0]), "kein Platz für den Zoll")
	player.inventory["wood"] = 0
	assert_eq(NpcController.blocked_reason(world, player, player.rules[0]), "")
	# Zu wenig Ware beim Zahlen
	_tick(6)
	var pay := SimIntent.new()
	pay.interact = true
	var short := _tick(1, stranger, pay, "toll_short")
	assert_eq(short.size(), 1)
	assert_eq(String(short[0]["reason"]), "zu wenig Holz (2 nötig)")
	# Spielstand trägt das Zoll-Gedächtnis
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	var loaded := copy.claims.claim_of_owner("p1")
	assert_true(loaded.toll.has("p2"))
	assert_true(bool(loaded.toll["p2"]["demanded"]))
	assert_almost_eq(float(loaded.toll["p2"]["debt"]), float(claim.toll["p2"]["debt"]), 0.001)


func test_turret_spares_pass_holders() -> void:
	var claim := _claim_and_keeper()
	world.login(player.id)
	player.inventory["iron"] = 4
	player.inventory["wood"] = 6
	player.inventory["wire"] = 2
	var turret := SimConstruction.place_building(world, player, "turret", Vector2i(36, 8), 0)  # Kachel (18, 4) im Claim
	assert_not_null(turret, "Turret: %s" % SimConstruction.can_place(world, player, "turret", Vector2i(36, 8), 0))
	turret.contents["shot"] = 10
	var stranger := world.spawn_player(INSIDE, "p2", "Anna")
	SimToll.toll_entry(world, claim, "p2")["paid_until"] = world.time + 3600.0
	var shots := _tick(40, null, null, "turret_shot")
	assert_eq(shots.size(), 0, "Turret verschont zahlende Gäste")
	claim.toll["p2"]["paid_until"] = -1.0
	shots = _tick(40, null, null, "turret_shot")
	assert_gt(shots.size(), 0, "ohne Freigang schießt es")
	assert_eq(stranger.owner_id, "p2")
