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


func _plain_wolf() -> SimCharacter:
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF and not c.boss and not c.dead:
			return c
	return null


func _events(kind: String) -> Array:
	var result := []
	for event: Dictionary in world.events:
		if event.get("type") == kind:
			result.append(event)
	return result


func test_boss_appears_in_the_center_after_first_hours_and_is_stronger() -> void:
	assert_null(SimEvents.boss_alive(world), "am Anfang kein Leitwolf")
	assert_almost_eq(world.next_boss_time, data.balf("events.boss.first_after_hours") * 3600.0, 0.001, "erster Leitwolf nach first_after_hours")
	world.next_boss_time = world.time + 20.0  # Wartezeit abkürzen (Test)
	world.advance(10.0)
	assert_null(SimEvents.boss_alive(world))
	world.advance(11.0)
	var boss := SimEvents.boss_alive(world)
	assert_not_null(boss, "nach first_after_hours da")
	assert_eq(boss.name, "Leitwolf")
	assert_eq(boss.kind, SimCharacter.Kind.WOLF)
	assert_eq(boss.max_hp, data.balf("events.boss.max_hp"))
	assert_eq(boss.melee_damage, data.balf("events.boss.bite_damage"))
	assert_eq(int(boss.inventory.get("hide", 0)), 3, "Beute: Fell")
	assert_eq(int(boss.inventory.get("meat", 0)), 8, "Beute: Fleisch")
	assert_false(boss.inventory.has("sulfur"), "kein Schwefel aus einem Wolf")
	# Am Wolf-Spawn, der der Mitte am nächsten liegt
	var center := Vector2(world.map.width * 0.5, world.map.height * 0.5)
	for cell: Vector2i in data.wolf_spawns:
		assert_true(SimMap.cell_center(cell).distance_to(center) >= boss.home_pos.distance_to(center) - 0.01, "zentralster Spawn")
	assert_eq(world.count_alive_wolves(), 3, "der Leitwolf zählt nicht als normaler Wolf")
	assert_eq(SimEvents.event_text({"type": "boss_spawned", "name": "Leitwolf"}), "Ein Leitwolf streift durchs Zentrum.")


func test_boss_never_flees_and_leaves_loot_only_for_live_looters() -> void:
	var boss := SimEvents.spawn_boss(world)
	boss.pos = OPEN + Vector2(3, 0)
	boss.home_pos = boss.pos
	boss.hp = boss.max_hp * 0.1  # weit unter der Fluchtschwelle eines Wolfs
	world.spatial.rebuild(world.characters)
	for i in 20:
		world.tick()
	assert_ne(boss.ai_state, WolfAI.STATE_FLEE, "der Leitwolf flieht nie")
	assert_eq(boss.ai_state, WolfAI.STATE_CHASE, "er jagt")
	# Erlegt: Ereignis, Leiche bleibt trotz Wolfsnachschub, Beute per E
	SimCombat.apply_damage(world, boss, 1000.0, Vector2.RIGHT, player.id)
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
	assert_eq(int(player.inventory.get("hide", 0)), 3, "Fell geplündert: %s" % [player.inventory])
	assert_eq(int(player.inventory.get("meat", 0)), 8)
	# Nach corpse_rot_hours verrottet auch die Leitwolf-Leiche
	boss.death_time = world.time - data.balf("combat.corpse_rot_hours") * 3600.0 + 1.0
	world.advance(2.0)
	assert_false(world.characters.has(boss.id))


func test_boss_leaves_after_lifetime_and_returns_on_interval() -> void:
	var lifetime := data.balf("events.boss.lifetime_hours") * 3600.0
	var interval := data.balf("events.boss.interval_hours") * 3600.0
	world.next_boss_time = world.time + 1.0
	world.advance(2.0)
	var boss := SimEvents.boss_alive(world)
	assert_not_null(boss)
	assert_almost_eq(world.next_boss_time, world.time - 2.0 + 1.0 + interval, 0.1, "nächster nach interval_hours")
	boss.logout_time = world.time - lifetime + 5.0  # ist fast lifetime_hours da (Test kürzt ab)
	world.advance(4.0)
	assert_not_null(SimEvents.boss_alive(world), "noch da")
	world.advance(2.0)
	assert_null(SimEvents.boss_alive(world), "weitergezogen")
	assert_false(world.characters.has(boss.id))
	world.advance(10.0)
	assert_null(SimEvents.boss_alive(world), "vor dem Intervall keiner")
	world.next_boss_time = world.time + 1.0
	world.advance(2.0)
	assert_not_null(SimEvents.boss_alive(world), "nächster Leitwolf zum Termin")
	# Spielstand trägt Leitwolf und Zeitplan
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_not_null(SimEvents.boss_alive(copy))
	assert_true(SimEvents.boss_alive(copy).boss)
	assert_almost_eq(copy.next_boss_time, world.next_boss_time, 0.001)


func test_offline_character_fights_back_but_never_attacks_the_boss_first() -> void:
	var rules := data.normalize_rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "attack", "params": {"radius": 8}}},
	], "Test")
	world.logout(player.id, rules, "Jäger")
	player.logout_time = -1e9
	var boss := SimEvents.spawn_boss(world)
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
	# Beißt ein Wolf und stirbt, ist der Leitwolf kein Ersatzziel für 'kämpfe zurück': er hat nicht gebissen
	var wolf := _plain_wolf()
	SimCombat.apply_damage(world, player, 1.0, Vector2.LEFT, wolf.id)
	SimCombat.apply_damage(world, wolf, 1000.0, Vector2.LEFT, -1)
	assert_true(wolf.dead)
	for i in 40:
		world.tick()
		shots += _events("shoot").size()
	assert_eq(shots, 0, "kein Ersatzziel Leitwolf")
	assert_eq(boss.hp, boss.max_hp)
	# Beißt er, wehrt sich der Charakter (kämpfe zurück)
	SimCombat.apply_damage(world, player, 1.0, Vector2.LEFT, boss.id)
	for i in 40:
		world.tick()
		shots += _events("shoot").size()
	assert_gt(shots, 0, "zurückgekämpft")
	assert_lt(boss.hp, boss.max_hp)


func test_boss_stops_chasing_outside_its_territory() -> void:
	var boss := SimEvents.spawn_boss(world)
	boss.pos = boss.home_pos + Vector2(3, 0)
	var prey := world.spawn_player(boss.pos + Vector2(2, 0), "p2", "Wanderer")
	prey.max_hp = 1000.0
	prey.hp = 1000.0
	world.spatial.rebuild(world.characters)
	world.tick()
	assert_eq(boss.ai_state, WolfAI.STATE_CHASE, "im Revier jagt er")
	var territory := data.balf("events.boss.territory_radius")
	boss.pos = boss.home_pos + Vector2(0, -(territory + 1.0))  # nördlich: freies Feld statt der Bäume östlich
	prey.pos = boss.pos + Vector2(2, 0)
	world.spatial.rebuild(world.characters)
	boss.hp = 50.0
	world.tick()
	assert_eq(boss.ai_state, WolfAI.STATE_RETURN, "außerhalb des Reviers gibt er auf und kehrt heim")
	assert_eq(boss.hp, boss.max_hp, "und heilt voll")
	# Auf dem Heimweg prallt jeder Treffer ab (Leitwolf-Leine, Entscheidung [T] 2026-09-25)
	SimCombat.apply_damage(world, boss, 30.0, Vector2.LEFT, prey.id)
	assert_eq(boss.hp, boss.max_hp, "unverwundbar auf dem Heimweg")
	assert_eq(_events("boss_evade").size(), 1, "der Schütze erfährt es")
	assert_eq(SimSensors.is_under_attack(world, boss), false, "und reizt ihn nicht")
	var closest := 99.0
	for i in 60:
		world.tick()
		closest = minf(closest, boss.pos.distance_to(boss.home_pos))
	assert_lt(closest, data.balf("events.boss.wander_radius") + 0.5, "läuft zurück ins Streifgebiet")
	assert_lt(boss.pos.distance_to(boss.home_pos), territory + 1.0, "und bleibt im Revier")
	assert_eq(prey.hp, 1000.0, "die Beute kommt davon")
	prey.pos = Vector2(38.5, 5.5)  # außer Sicht: er kommt zur Ruhe
	world.spatial.rebuild(world.characters)
	for i in 60:
		world.tick()
	assert_eq(boss.ai_state, WolfAI.STATE_WANDER)
	SimCombat.apply_damage(world, boss, 30.0, Vector2.LEFT, prey.id)
	assert_lt(boss.hp, boss.max_hp, "im Streifgebiet wieder verwundbar")


## Leitwolf auf freiem Feld: Zuhause in Zeile 17 der Standardkarte, nach Osten ist bis x = 38 alles Boden.
func _boss_on_open_row() -> SimCharacter:
	var boss := SimEvents.spawn_boss(world)
	boss.home_pos = Vector2(8.5, 17.5)
	boss.pos = boss.home_pos
	boss.prev_pos = boss.pos
	return boss


## Befund Schritt 54: ein Bogenschütze traf den Leitwolf aus 9–12 Kacheln sechsmal, er streunte weiter. Jetzt wendet er
## sich gegen den Schützen – unter Beschuss bis provoked_chase_radius von seinem Zuhause, nicht weiter.
func test_boss_turns_on_ranged_attacker_up_to_the_provoked_chase_radius() -> void:
	var boss := _boss_on_open_row()
	var chase := data.balf("events.boss.provoked_chase_radius")
	assert_gt(chase, data.balf("events.boss.territory_radius"), "unter Beschuss weiter als das Revier")
	var archer := world.spawn_player(boss.home_pos + Vector2(10, 0), "p2", "Bogenschütze")  # jenseits von Aggro und Revier
	archer.max_hp = 1000.0
	archer.hp = 1000.0
	world.spatial.rebuild(world.characters)
	world.tick()
	assert_eq(boss.ai_state, WolfAI.STATE_WANDER, "sieht den Schützen nicht")
	var worst := 0.0
	for i in 20 * 5:
		if i % 20 == 0:
			SimCombat.apply_damage(world, boss, 1.0, Vector2.LEFT, archer.id)  # ein Treffer je Sekunde aus 10 Kacheln
		world.tick()
		if i == 0:
			assert_eq(boss.ai_state, WolfAI.STATE_CHASE, "wendet sich gegen den Schützen")
		worst = maxf(worst, boss.pos.distance_to(boss.home_pos))
	assert_gt(worst, 5.0, "läuft auf ihn zu")
	assert_lt(worst, chase + 0.6, "aber nie über provoked_chase_radius hinaus")
	# Jenseits von provoked_chase_radius lässt ihn ein Treffer kalt: er kehrt heim
	boss.pos = boss.home_pos + Vector2(chase + 1.0, 0)
	archer.pos = boss.pos + Vector2(10, 0)
	archer.hp = 1000.0
	world.spatial.rebuild(world.characters)
	SimCombat.apply_damage(world, boss, 1.0, Vector2.LEFT, archer.id)
	world.tick()
	assert_eq(boss.ai_state, WolfAI.STATE_RETURN, "jenseits von provoked_chase_radius keine Verfolgung")
	for i in 40:
		world.tick()
	assert_lt(boss.pos.distance_to(boss.home_pos), chase + 1.0, "kehrt heim")
	assert_eq(archer.hp, 1000.0, "der Schütze kommt davon")


## Entscheidung [T] 2026-09-25: knapp außerhalb des Reviers stehen und schießen war gefahrlos (der Leitwolf blieb am
## Reviersrand stehen, 4,2 gegen 4,0 Kacheln/s). Jetzt jagt er unter Beschuss bis provoked_chase_radius und beißt.
func test_archer_just_outside_the_territory_gets_bitten() -> void:
	var boss := _boss_on_open_row()
	var territory := data.balf("events.boss.territory_radius")
	assert_gt(boss.move_speed, data.balf("character.move_speed"), "schneller als ein Spieler")
	var archer := world.spawn_player(boss.home_pos + Vector2(territory + 2.0, 0), "p2", "Bogenschütze")
	archer.max_hp = 1000.0
	archer.hp = 1000.0
	world.spatial.rebuild(world.characters)
	for i in 20 * 6:
		if i % 14 == 0:
			SimCombat.apply_damage(world, boss, 1.0, (boss.pos - archer.pos).normalized(), archer.id)  # Bogentakt 0,7 s
		world.tick()
	assert_lt(archer.hp, 1000.0, "gebissen")


## Wer weiter weg steht als provoked_chase_radius, reizt ihn bis an diese Grenze, aber nicht darüber hinaus; dort läuft er
## unverwundbar heim und heilt voll – so jenseits der Grenze zu stehen, bringt keinen Biss, aber auch keine Beute.
func test_provoked_boss_stops_at_the_chase_radius_and_returns_home() -> void:
	var boss := _boss_on_open_row()
	var territory := data.balf("events.boss.territory_radius")
	var chase := data.balf("events.boss.provoked_chase_radius")
	var archer := world.spawn_player(boss.home_pos + Vector2(chase + 4.0, 0), "p2", "Bogenschütze")
	archer.max_hp = 1000.0
	archer.hp = 1000.0
	world.spatial.rebuild(world.characters)
	var worst := 0.0
	var returned := 0
	for i in 20 * 8:
		if i % 14 == 0:
			SimCombat.apply_damage(world, boss, 5.0, (boss.pos - archer.pos).normalized(), archer.id)
		world.tick()
		worst = maxf(worst, boss.pos.distance_to(boss.home_pos))
		returned += 1 if boss.ai_state == WolfAI.STATE_RETURN else 0
	assert_gt(worst, chase - 1.0, "jagt bis an die Grenze")
	assert_lt(worst, chase + 0.6, "nie darüber hinaus")
	assert_gt(returned, 0, "an der Grenze kehrt er um")
	assert_eq(archer.hp, 1000.0, "wer jenseits steht, wird nicht gebissen")
	for i in 20 * 15:
		world.tick()
		worst = maxf(worst, boss.pos.distance_to(boss.home_pos))
	assert_lt(worst, chase + 0.6)
	assert_lt(boss.pos.distance_to(boss.home_pos), territory, "ohne Treffer zurück im Revier")
	assert_eq(boss.hp, boss.max_hp, "und heil")


## Review Schritt 55: ein Bogenschütze, der rückwärts gehend weiterschießt, erlegte den Leitwolf allein ohne einen Biss
## (tot nach 13 s): jenseits der Grenze kehrte er gemächlich um, der nächste Treffer holte ihn zurück. Jetzt läuft er an
## der Grenze unverwundbar heim und heilt voll (Leitwolf-Leine). Echte Pfeile über Absichten, wie ein Live-Spieler.
func test_retreating_archer_cannot_kill_the_boss_alone() -> void:
	var boss := _boss_on_open_row()
	var chase := data.balf("events.boss.provoked_chase_radius")
	var archer := world.spawn_player(boss.home_pos + Vector2(11, 0), "p2", "Bogenschütze")
	archer.hunger = 90.0
	archer.items.append("bow")
	archer.durability["bow"] = {"left": 1000.0, "max": 1000.0}
	SimCrafting.set_active_weapon(world, archer, "bow")
	archer.inventory["arrow"] = 200
	var bow: Dictionary = data.items["bow"]
	var reach := float(bow["projectile_speed"]) * float(bow["projectile_lifetime"]) - 0.5
	world.spatial.rebuild(world.characters)
	var worst := 0.0
	var hits := 0
	var evades := 0
	for i in 20 * 60:
		var intent := SimIntent.new()
		var lead := (boss.pos - boss.prev_pos) / world.tick_dt * (archer.pos.distance_to(boss.pos) / float(bow["projectile_speed"]))
		intent.aim = boss.pos + lead - archer.pos
		intent.shoot = archer.pos.distance_to(boss.pos) <= reach
		if archer.pos.distance_to(boss.pos) < 4.0 and archer.pos.x < 37.0:
			intent.move = Vector2.RIGHT  # weicht zurück und schießt weiter
		elif archer.pos.distance_to(boss.pos) > reach - 1.0:
			intent.move = Vector2.LEFT  # und kommt wieder in Reichweite
		world.set_intent(archer.id, intent)
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "hit" and int(event["id"]) == boss.id:
				hits += 1
		evades += _events("boss_evade").size()
		worst = maxf(worst, boss.pos.distance_to(boss.home_pos))
		if boss.dead or archer.dead:
			break
	assert_gt(hits, 10, "der Schütze trifft, Runde um Runde")
	assert_gt(evades, 0, "an der Grenze kehrt der Leitwolf um")
	assert_false(boss.dead, "allein im Rückwärtsgang nicht zu erlegen")
	assert_lt(worst, chase + 0.6, "nie über provoked_chase_radius hinaus")


## Nur ein Live-Spieler reizt ihn über das Revier hinaus. Ein Offline-Charakter, der sich wehrt, lockt ihn nicht hinaus
## (Offline eingeschränkt beteiligt; Messung: mit Verfolgung bis 16 Kacheln starben mehr als doppelt so viele Füll-NPCs am Leitwolf).
func test_offline_defender_does_not_lure_the_boss_out_of_its_territory() -> void:
	var boss := _boss_on_open_row()
	var territory := data.balf("events.boss.territory_radius")
	var npc := world.spawn_player(boss.home_pos + Vector2(territory + 2.0, 0), "p2", "Wache")
	npc.max_hp = 1000.0
	npc.hp = 1000.0
	var rules := data.normalize_rule_list([{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 1}}}], "Test")
	world.logout(npc.id, rules, "Wache")
	npc.logout_time = -1e9
	world.spatial.rebuild(world.characters)
	var worst := 0.0
	for i in 20 * 6:
		if i % 14 == 0:
			SimCombat.apply_damage(world, boss, 1.0, (boss.pos - npc.pos).normalized(), npc.id)  # der NPC wehrt sich
		world.tick()
		worst = maxf(worst, boss.pos.distance_to(boss.home_pos))
	assert_gt(worst, territory - 1.0, "er wendet sich gegen ihn")
	assert_lt(worst, territory + 0.6, "aber nur bis an den Reviersrand")
	assert_eq(npc.hp, 1000.0, "zwei Kacheln vor dem Rand: kein Biss")


## Vorsichtig schießen: steht der Leitwolf hinter dem Wolf in der Schusslinie, hält der Offline-Charakter das Feuer –
## ein Streifschuss würde ihn reizen, und Ereignis-Tiere greift er nie zuerst an.
func test_offline_character_never_shoots_through_the_boss() -> void:
	var rules := data.normalize_rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	], "Test")
	world.logout(player.id, rules, "Wache")
	player.logout_time = -1e9
	var wolf := _plain_wolf()
	wolf.pos = OPEN + Vector2(5, 0)  # steht still (Steuerung aus)
	var boss := SimEvents.spawn_boss(world)
	boss.pos = OPEN + Vector2(8, 0)  # hinter dem Wolf, in Schleuderreichweite
	boss.control = SimCharacter.Controller.NONE
	world.spatial.rebuild(world.characters)
	var shots := 0
	for i in 20:
		player.last_damage_time = world.time  # vom Wolf angegriffen, ohne Schaden
		player.last_attacker_id = wolf.id
		player.pos = OPEN  # festhalten: kein Seitenschritt
		world.tick()
		shots += _events("shoot").size()
	assert_eq(shots, 0, "Leitwolf in der Schusslinie: kein Schuss")
	boss.pos = OPEN + Vector2(5, -4)  # aus der Linie
	for i in 40:
		player.last_damage_time = world.time
		player.last_attacker_id = wolf.id
		world.tick()
		shots += _events("shoot").size()
	assert_gt(shots, 0, "Linie frei: er schießt auf den Wolf")
	assert_eq(boss.hp, boss.max_hp, "den Leitwolf nie")


## Befund Schritt 54: zwei Schützen, die abwechselnd treffen, drehten den Leitwolf bei jedem Treffer um – sie erlegten
## ihn, ohne einmal gebissen zu werden. Er geht auf den Nächsten los.
func test_two_alternating_shooters_do_not_stun_lock_the_boss() -> void:
	var boss := SimEvents.spawn_boss(world)
	boss.max_hp = 1000.0
	boss.hp = 1000.0
	player.pos = boss.home_pos + Vector2(-5, 0)
	var other := world.spawn_player(boss.home_pos + Vector2(5, 0), "p2", "B")
	for c: SimCharacter in [player, other]:
		c.max_hp = 1000.0
		c.hp = 1000.0
	world.spatial.rebuild(world.characters)
	var shooters: Array[SimCharacter] = [player, other]
	var bites := 0
	for i in 20 * 10:
		if i % 10 == 0:
			var shooter := shooters[(i / 10) % 2]
			SimCombat.apply_damage(world, boss, 0.01, (boss.pos - shooter.pos).normalized(), shooter.id)
		world.tick()
		bites += _events("hit").filter(func(e: Dictionary) -> bool: return int(e["attacker"]) == boss.id).size()
	assert_gt(bites, 4, "der Leitwolf erreicht einen der beiden und beißt")
