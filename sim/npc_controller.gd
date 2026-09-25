class_name NpcController
extends RefCounted
## Offline-Modus: führt die Regelliste eines Charakters aus. Derselbe Körper und dasselbe Kampfsystem
## wie live, aber schlechter: zielt auf die aktuelle statt die zukünftige Position, dreht sich zur
## Bedrohung (umlaufbar), handelt vorsichtig (hält Abstand, schießt nicht durch Unbeteiligte, fängt keinen
## neuen Streit mit Menschen an). Die Leine – der Kreis der zuletzt gefeuerten Ortsregel – wird nie verlassen.
## Erzeugt nur Absichten (SimIntent) und Chronik-Einträge.

const THREAT_LOOK_RADIUS: float = 10.0  # Bis zu dieser Distanz dreht sich der NPC zum nächsten Fremden
const ENGAGE_TARGET: String = "engage_target"  # action_state: Kennung des Ziels, das _engage in diesem Tick anvisiert
const BYSTANDER_MARGIN: float = 0.45  # Sicherheitsabstand zur Schusslinie über den Körperradius hinaus (Ziele bewegen sich)


static func decide(world: SimWorld, c: SimCharacter, dt: float) -> SimIntent:
	var intent := SimIntent.new()
	c.action_state.erase(ENGAGE_TARGET)  # gilt nur für den Tick, in dem _engage es setzt: nie ein veraltetes Nahkampfziel
	c.decision_timer -= dt
	if c.decision_timer <= 0.0 or c.active_rule_index < 0:
		c.decision_timer = world.data.balf("npc.decision_interval")
		_evaluate(world, c)
	if not c.transition_logged and not world.in_transition(c):
		c.transition_logged = true
		SimChronicle.add(world, c, "Übergang beendet, Charakter ist jetzt offline")
		c.decision_timer = 0.0
	var navigating := false
	if c.active_rule_index >= 0 and c.active_rule_index < c.rules.size():
		navigating = _execute(world, c, c.rules[c.active_rule_index], intent, dt)
	_face_threat_if_idle(world, c, intent)
	_apply_leash(world, c, intent, dt, navigating)
	return intent


## Regelauswertung: erste zutreffende UND ausführbare Regel gewinnt. Eine zutreffende, aber nicht
## ausführbare Regel (z. B. "iss" ohne Essbares) wird übersprungen und einmal in der Chronik vermerkt.
## Protokolliert wird ein Regelwechsel; nimmt der NPC nach einer Pause dieselbe Regel wieder auf, nicht erneut.
## Derselbe Übersprung-Grund wird frühestens nach npc.skip_relog_minutes erneut vermerkt.
static func _evaluate(world: SimWorld, c: SimCharacter) -> void:
	var data := world.data
	var facts := SimSensors.facts_for(world, c)
	var chosen := RuleEngine.NO_MATCH
	var relog_after := data.balf("npc.skip_relog_minutes") * 60.0
	var start := 0
	while start < c.rules.size():
		var result := RuleEngine.evaluate(c.rules.slice(start), facts, data)
		if result["index"] == RuleEngine.NO_MATCH:
			break
		var index: int = start + result["index"]
		var reason := blocked_reason(world, c, c.rules[index])
		if reason.is_empty():
			chosen = index
			break
		var previous: Dictionary = c.skipped_rules.get(index, {})
		if previous.get("reason", "") != reason or world.time - float(previous.get("time", -1e9)) >= relog_after:
			c.skipped_rules[index] = {"reason": reason, "time": world.time}
			SimChronicle.log_rule(world, c, index, c.rules[index], "nicht möglich: %s, übersprungen" % reason)
		start = index + 1
	if chosen != c.active_rule_index:
		c.active_rule_index = chosen
		c.action_state = {}
		c.path.clear()
		if chosen == RuleEngine.NO_MATCH:
			return
		var rule: Dictionary = c.rules[chosen]
		var leash := RuleEngine.leash_of(rule, c)
		if not leash.is_empty():
			c.leash_center = leash["center"]
			c.leash_radius = leash["radius"]
		# "iss" und "verlange Zoll" protokollieren sich selbst mit Details (Menge bzw. Name des Fremden)
		if not ["eat", "toll"].has(String(rule["then"]["action"])) and chosen != c.last_logged_rule_index:
			c.last_logged_rule_index = chosen
			SimChronicle.log_rule(world, c, chosen, rule)
	if chosen != RuleEngine.NO_MATCH and String(c.rules[chosen]["then"]["action"]) == "eat":
		c.last_logged_rule_index = chosen
		_eat_now(world, c, chosen, c.rules[chosen])


## Warum eine zutreffende Regel gerade nicht ausführbar ist; leer = ausführbar.
static func blocked_reason(world: SimWorld, c: SimCharacter, rule: Dictionary) -> String:
	var data := world.data
	var params: Dictionary = rule["then"]["params"]
	for def: Dictionary in [data.action_def(String(rule["then"]["action"])), data.condition_def(String(rule["if"]["condition"]))]:
		if not world.can_use(c, def):
			return String(data.requirement_of(def).get("label", "Voraussetzung fehlt"))
	for param_def: Dictionary in data.action_def(String(rule["then"]["action"])).get("params", []):
		if String(param_def["type"]) == "place":
			var place := String(params.get(param_def["name"], SimData.PLACE_HERE))
			if SimData.SYMBOLIC_PLACES.has(place) and not c.extra_places.has(place):
				return String(SimData.SYMBOLIC_PLACES[place]["missing"])
			if place != SimData.PLACE_HERE and place.begins_with("b") and not c.extra_places.has(place):
				return "Ort existiert nicht mehr"
	match String(rule["then"]["action"]):
		"eat":
			if c.hunger >= data.balf("hunger.max"):
				return "satt"
			for rid: String in data.resource_order:
				if data.resources[rid].get("edible", false) and int(c.inventory.get(rid, 0)) > 0:
					return ""
			return "nichts Essbares"
		"gather":
			if c.inventory_count() >= data.bali("inventory.capacity"):
				return "Inventar voll"
			if _find_gather_node(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"])) == null:
				var without := _find_gather_node(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"]), false)
				if without != null:
					return "nur live abbaubar" if world.node_live_only(without) else "braucht eine Mine daneben"
				return "nichts zu sammeln in der Leine"
		"hide":
			if world.in_transition(c):
				return "Logout-Übergang läuft"
		"heal_self":
			if c.hp >= c.max_hp and c.effects.is_empty():
				return "gesund"
			if SimCrafting.heal_item_of(world, c).is_empty():
				return "kein passendes Heilmittel"
		"craft":
			# Station (Werkbank, Schmelzofen, Lagerfeuer …): in Reichweite oder wenigstens in der Leine – dann läuft er hin
			var product := String(params["product"])
			var station := world.data.station_of(product)
			if not station.is_empty() and SimCrafting.building_part_near(world, c, station) == null and SimCrafting.station_in_leash(world, c, station) == null:
				return "%s nicht in der Leine" % world.data.buildings[station]["name"]
			var reason := SimCrafting.craft_reason(world, c, product, true)
			if not reason.is_empty():
				return reason
		"toll":
			var claim := SimToll.toll_claim_of(world, c)
			if claim == null:
				return "kein eigener Claim"
			if c.inventory_count() + int(params["amount"]) > data.bali("inventory.capacity"):
				return "kein Platz für den Zoll"
			if SimToll.toll_liable_in_claim(world, c, claim).is_empty():
				return "kein Mensch ohne Freigang im Claim"
		"deliver":
			var rid := String(params["resource"])
			if int(c.inventory.get(rid, 0)) <= 0:
				return "nichts zu liefern"
			var target := SimTrade.container_near(world, c.owner_id, c.place_pos(String(params["place"])), float(params["radius"]))
			if target == null:
				return "kein eigener Anker oder Handelstisch am Ort"
			if target.part == "anchor" and rid != "wood":
				return "der Anker nimmt nur Holz"
			if SimDefense.is_turret(world, target) and rid != String(world.data.buildings[target.part]["turret"]["ammo"]):
				return "das Turret nimmt nur Kugeln"
	return ""


## "iss": sofort ausführen und mit Details protokollieren ("Beeren 4→3").
static func _eat_now(world: SimWorld, c: SimCharacter, index: int, rule: Dictionary) -> void:
	var event := world.eat(c)
	if event.is_empty():
		return
	var name := String(world.data.resources[event["resource"]]["name"])
	SimChronicle.log_rule(world, c, index, rule, "%s %d→%d" % [name, event["before"], event["after"]])


## Führt die Aktion aus. Rückgabe true, wenn der NPC gerade per Wegsuche zu einem Ort unterwegs ist
## (dann darf die Leine ihn außerhalb des Kreises nicht übersteuern).
static func _execute(world: SimWorld, c: SimCharacter, rule: Dictionary, intent: SimIntent, dt: float) -> bool:
	var params: Dictionary = rule["then"]["params"]
	match String(rule["then"]["action"]):
		"flee_to":
			_go_to(world, c, c.place_pos(String(params["place"])), float(params["radius"]) * 0.5, intent, dt)
			if intent.move != Vector2.ZERO:
				intent.aim = intent.move  # rennt, zeigt den Rücken
			return true
		"stay_at":
			var center := c.place_pos(String(params["place"]))
			if c.pos.distance_to(center) > float(params["radius"]) * 0.8:
				_go_to(world, c, center, float(params["radius"]) * 0.5, intent, dt)
			return true
		"gather":
			_gather(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"]), intent, dt)
			return true
		"fight_back":
			return _fight_back(world, c, intent, dt)  # im Gefecht zählt die Kampfstellung, nicht der Rückweg zur Leine
		"attack":
			return _attack_nearby(world, c, float(params["radius"]), intent, dt)
		"hide":
			intent.hide = true
		"heal_self":
			intent.heal = true  # kanalisiert; greift währenddessen nicht an, darf aber laufen
		"deliver":
			_deliver(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"]), intent, dt)
			return true
		"toll":
			return _toll(world, c, String(params["resource"]), int(params["amount"]), intent, dt)
		"craft":
			var rid := String(params["product"])
			var station := world.data.station_of(rid)
			if not station.is_empty() and SimCrafting.building_part_near(world, c, station) == null:
				# Erst zur Station in der Leine laufen (Werkbank, Schmelzofen, Lagerfeuer …)
				var target := SimCrafting.station_in_leash(world, c, station)
				if target == null:
					return false
				var stand := SimMap.cell_center(world.map.nearest_walkable_cell(SimMap.cell_of(target.center())))
				intent.move = SimNav.direction_toward(world, c, stand, dt, 0.15)
				return true
			if SimCrafting.craft(world, c, rid).is_empty():
				var index := c.active_rule_index
				SimChronicle.log_rule(world, c, index, c.rules[index], "jetzt %d" % int(c.inventory.get(rid, 0)))
				c.last_logged_rule_index = -1  # jedes Stück wird protokolliert
		"eat":
			pass  # bereits bei der Auswertung ausgeführt
	return false


static func _go_to(world: SimWorld, c: SimCharacter, goal: Vector2, arrive: float, intent: SimIntent, dt: float) -> void:
	intent.move = SimNav.direction_toward(world, c, goal, dt, arrive)


static func _gather(world: SimWorld, c: SimCharacter, resource: String, center: Vector2, radius: float, intent: SimIntent, dt: float) -> void:
	var node: SimResourceNode = c.action_state.get("node")
	if node == null or node.amount <= 0:
		node = _find_gather_node(world, c, resource, center, radius)
		c.action_state["node"] = node
		if node == null:
			return
	var interact_range := world.data.balf("character.interact_range")
	if c.pos.distance_to(node.center()) <= interact_range * 0.95:
		intent.interact = true
		intent.gather_cell = node.cell
		intent.aim = node.center() - c.pos
	else:
		var stand := SimMap.cell_center(world.map.nearest_walkable_cell(node.cell))
		intent.move = SimNav.direction_toward(world, c, stand, dt, 0.15)


## Liefern: zum eigenen Anker/Tisch am Ort gehen und alles vom Rohstoff abgeben; Chronik mit Menge.
static func _deliver(world: SimWorld, c: SimCharacter, rid: String, center: Vector2, radius: float, intent: SimIntent, dt: float) -> void:
	var target := SimTrade.container_near(world, c.owner_id, center, radius)
	if target == null:
		return
	var reach := world.data.balf("character.interact_range")
	if c.pos.distance_to(target.center()) <= reach + 0.3:
		var moved := SimTrade.deliver_to(world, c, target, rid)
		if moved > 0:
			var index := c.active_rule_index
			SimChronicle.log_rule(world, c, index, c.rules[index], "%d %s" % [moved, world.data.resources[rid]["name"]])
			c.last_logged_rule_index = -1  # nächste Lieferung wird wieder protokolliert
		return
	var stand := SimMap.cell_center(world.map.nearest_walkable_cell(SimMap.cell_of(target.center())))
	intent.move = SimNav.direction_toward(world, c, stand, dt, 0.15)


## Zoll: jeden Fremden ohne Freigang im Claim zur Kasse bitten (Forderung einmal je Schuldperiode), zum nächsten
## hingehen, damit er per E zahlen kann. Die Zeit im Claim ohne Zahlung wird als Schuld gemerkt – auch über mehrere
## Besuche; ab toll.grace_seconds greift der Zöllner an, solange der Fremde im Claim steht (Design: "Zoll, Zutritt, Angriff").
static func _toll(world: SimWorld, c: SimCharacter, rid: String, amount: int, intent: SimIntent, dt: float) -> bool:
	var claim := SimToll.toll_claim_of(world, c)
	if claim == null:
		return false
	var grace := world.data.balf("toll.grace_seconds")
	var target: SimCharacter = null
	var best := INF
	for other: SimCharacter in SimToll.toll_liable_in_claim(world, c, claim):
		var entry := SimToll.toll_entry(world, claim, other.owner_id)
		entry["debt"] = float(entry["debt"]) + dt
		if not bool(entry["demanded"]):
			entry["demanded"] = true
			world.events.append({"type": "toll_demand", "id": c.id, "target": other.id, "owner": c.owner_id, "resource": rid, "amount": amount, "seconds_left": maxf(0.0, grace - float(entry["debt"]))})
			var index := c.active_rule_index
			SimChronicle.log_rule(world, c, index, c.rules[index], "von %s" % world.describe(c, other))
		if float(entry["debt"]) >= grace and not bool(entry["attacking"]):
			entry["attacking"] = true
			world.events.append({"type": "toll_attack", "id": c.id, "target": other.id, "owner": c.owner_id})
			SimChronicle.add(world, c, "Zoll geprellt: %s – Angriff" % world.describe(c, other))
		var d := other.pos.distance_squared_to(c.pos)
		if d < best:
			best = d
			target = other
	c.action_state["toll_active"] = target != null
	if target == null:
		return false
	if float(claim.toll[target.owner_id]["debt"]) >= grace:
		_engage(world, c, target, intent, dt)
		return false
	intent.aim = target.pos - c.pos
	var reach := world.data.balf("character.interact_range")
	if c.pos.distance_to(target.pos) > reach * 0.9:
		intent.move = SimNav.direction_toward(world, c, target.pos, dt, reach * 0.8)
	return true


## Nächste Quelle mit Vorrat, deren Mitte innerhalb der Leine liegt.
static func _find_gather_node(world: SimWorld, c: SimCharacter, resource: String, center: Vector2, radius: float, require_mine: bool = true) -> SimResourceNode:
	var best: SimResourceNode = null
	var best_d := INF
	for node: SimResourceNode in world.map.nodes.values():
		if node.resource != resource or node.amount <= 0:
			continue
		if node.center().distance_to(center) > radius:
			continue
		if world.claims.is_foreign(node.cell, c.owner_id):
			continue  # Rohstoffknoten nur für Eigentümer-NPCs
		if require_mine and (not world.node_offline_ok(node, c.owner_id) or world.node_live_only(node)):
			continue  # Eisen/Kohle offline nur mit Mine daneben; Schwefel nie offline
		var d := node.center().distance_squared_to(c.pos)
		if d < best_d:
			best_d = d
			best = node
	return best


## Zurückkämpfen: den Angreifer anvisieren, aktuelle Position beschießen, vorsichtig Abstand halten. Als Angreifer gilt
## nur, wer in den letzten combat.under_attack_window Sekunden getroffen hat (dieselbe Frist wie 'wird angegriffen') –
## wer ihn vor Stunden traf, ist heute unbeteiligt. Ist er tot, versteckt oder weg (auch Turret, Falle, Sprengsatz),
## gilt als Ersatzziel nur ein gewöhnlicher Wolf in wolf.aggro_radius (der greift ohnehin gleich an) – nie ein
## unbeteiligter Mensch, nie ein streunender Wolf weiter weg (ein Treffer machte ihn erst zum Angreifer, Befund
## Schritt 54) und nie der Leitwolf, der nicht selbst gebissen hat: vorsichtig handeln heißt, keinen neuen Streit
## anzufangen, und Ereignis-Tiere greift ein Offline-Charakter nie zuerst an (Design [E]). Befund Schritt 54: mit
## "nächster Fremder" als Ersatz sprang der Kampf gegen einen Wolf auf alle Offline-Nachbarn über.
## Nie über die Leine hinaus verfolgen (siehe _apply_leash).
## Rückgabe true, wenn ein Ziel da ist: dann übersteuert die Leine die Kampfstellung nicht (innerhalb des Kreises
## kürzt sie Schritte trotzdem, außerhalb – etwa unterwegs zu einem Lieferziel – kämpft er, wo er steht).
static func _fight_back(world: SimWorld, c: SimCharacter, intent: SimIntent, dt: float) -> bool:
	var target := _current_attacker(world, c)
	if target == null:
		target = _nearest_wolf(world, c, world.data.balf("wolf.aggro_radius"))
	if target == null:
		return false
	_engage(world, c, target, intent, dt)
	return true


## Wer den Charakter gerade angreift: der letzte Angreifer, solange 'wird angegriffen' gilt und er lebt, sichtbar und
## nicht verbündet ist; sonst null.
static func _current_attacker(world: SimWorld, c: SimCharacter) -> SimCharacter:
	if c.last_attacker_id < 0 or not SimSensors.is_under_attack(world, c):
		return null
	var attacker := world.get_character(c.last_attacker_id)
	if attacker == null or attacker.dead or attacker.hidden or world.allied(attacker.owner_id, c.owner_id):
		return null
	return attacker


## Nächster lebender gewöhnlicher Wolf im Radius (nicht der Leitwolf), sonst null.
static func _nearest_wolf(world: SimWorld, c: SimCharacter, radius: float) -> SimCharacter:
	var best: SimCharacter = null
	var best_d := radius * radius
	for other: SimCharacter in world.spatial.query(c.pos, radius):
		if other.kind != SimCharacter.Kind.WOLF or other.boss or other.dead or other.hidden:
			continue
		var d := other.pos.distance_squared_to(c.pos)
		if d <= best_d:
			best_d = d
			best = other
	return best


## Angreifen (freigeschaltet): nächsten sichtbaren Fremden im Radius angreifen, ohne selbst angegriffen zu sein.
static func _attack_nearby(world: SimWorld, c: SimCharacter, radius: float, intent: SimIntent, dt: float) -> bool:
	var target := SimCombat.nearest_enemy(world, c, radius, true)  # Offline nur eingeschränkt an Ereignissen beteiligt: Leitwolf und Karawane greift er nie zuerst an
	if target == null:
		return false
	_engage(world, c, target, intent, dt)
	return true


## Gemeinsame Kampfausführung: Waffenwahl, Abstand, Schuss auf die aktuelle Position. Das Ziel merkt sich der
## Charakter für diesen Tick (action_state ENGAGE_TARGET): der Nahkampf trifft genau es, nicht den Nächststehenden.
## Auch die Karawanenwachen kämpfen hierüber (CaravanAI).
static func _engage(world: SimWorld, c: SimCharacter, target: SimCharacter, intent: SimIntent, _dt: float) -> void:
	var data := world.data
	var to_target := target.pos - c.pos
	var distance := to_target.length()
	intent.aim = to_target  # zielt auf die aktuelle Position, kein Vorhalten
	c.action_state[ENGAGE_TARGET] = target.id
	# Waffenwahl: Nahkampf nur, wenn der Feind schon in Reichweite steht; sonst vorsichtig auf Abstand schießen
	var melee_id := ""
	var ranged_id := ""
	for item_id: String in SimCrafting.owned_weapons(world, c):
		if data.items[item_id]["attack"] == "melee" and melee_id.is_empty():
			melee_id = item_id
		elif data.items[item_id]["attack"] == "ranged" and SimCrafting.has_ammo(world, c, item_id) \
				and (ranged_id.is_empty() or float(data.items[item_id]["damage"]) > float(data.items[ranged_id]["damage"])):
			ranged_id = item_id  # stärkste Fernwaffe mit Munition
	if not melee_id.is_empty() and distance <= float(data.items[melee_id]["range"]) * 1.1:
		SimCrafting.set_active_weapon(world, c, melee_id)
		intent.shoot = true
		return
	if ranged_id.is_empty():
		if not melee_id.is_empty():
			SimCrafting.set_active_weapon(world, c, melee_id)
			intent.move = to_target.normalized()  # nur Nahkampf: hingehen
		return
	SimCrafting.set_active_weapon(world, c, ranged_id)
	var preferred := data.balf("npc.preferred_combat_range")
	var too_close := preferred * 0.7
	if distance < too_close:
		intent.move = -to_target.normalized()
	elif distance > preferred * 1.3:
		intent.move = to_target.normalized()
	var weapon: Dictionary = data.items[ranged_id]
	var reach := float(weapon["projectile_speed"]) * float(weapon["projectile_lifetime"])
	if distance > reach or distance <= 0.0:
		return
	# Sichtlinie ab der Mündung, wo das Projektil entsteht (SimCombat._shoot): wer mit dem Rücken an einem Baum steht,
	# schießt trotzdem (Befund Schritt 54: ein NPC am Baum sah den Wolf vor sich nicht und starb ohne einen Schuss)
	var dir := to_target / distance
	var muzzle := c.pos + dir * (c.collision_radius + 0.15)
	if not world.map.is_walkable(SimMap.cell_of(muzzle)) or not SimNav.line_clear(world.map, muzzle, target.pos, 0.1):
		return
	# Vorsichtig (nur Offline-Charaktere): kein Schuss, solange ein Unbeteiligter in der Schusslinie steht; stattdessen
	# ein Schritt zur Seite, bis die Linie frei ist (die Leine kürzt ihn wie jeden Schritt). Geprüft wird
	# nur, wenn der Schuss auch fallen könnte (sonst ist 'shoot' ohnehin wirkungslos) – das hält den heißen Pfad billig.
	if c.control == SimCharacter.Controller.RULES and c.fire_cooldown <= 0.0:
		var bystander := _bystander_in_line(world, c, target, reach, distance <= too_close)
		if bystander != null:
			# Seite so wählen, dass die Linie ihn verlässt: vor dem Ziel weg von ihm; hinter dem Ziel dreht sich die
			# Linie um das Ziel, also zu seiner Seite hin
			var side := dir.orthogonal()
			var offset := bystander.pos - c.pos
			if (offset.dot(side) > 0.0) != (offset.dot(dir) > distance):
				side = -side
			intent.move = (intent.move + side).normalized()
			return
	intent.shoot = true


## Der erste Unbeteiligte in der Schusslinie zum Ziel, sonst null. Die Linie reicht bis zur vollen Reichweite (ein
## Fehlschuss fliegt weiter) – außer das Ziel steht so nah, dass es den Schuss abfängt (target_shields: innerhalb des
## Abstands, bei dem der NPC zurückweicht), dann nur bis zum Ziel. Hinter dem Ziel zählt nur, wen keine Wand und kein
## Bauteil deckt (dort endet das Projektil). Befund Schritt 54: ohne diese Grenzen hielt ein NPC das Feuer gegen den
## Wolf direkt vor sich, weil der Nachbar vier Kacheln dahinter stand, und starb ohne einen Schuss.
## Unbeteiligt: sichtbare, lebende Menschen, Karawanenmitglieder und der Leitwolf, die weder das Ziel noch der aktuelle
## Angreifer noch verbündet sind (Projektile lassen Verbündete ohnehin passieren). Gewöhnliche Wölfe zählen nicht: sie
## jagen ohnehin jeden, und wer gegen ein Rudel kämpft, darf nicht verstummen. Der Leitwolf zählt, denn ein Streifschuss
## reizt ihn (er jagt, wer ihn trifft), und Offline-Charaktere greifen ihn nie zuerst an. Wer in einer kampffreien Zone
## steht (Markt), zählt nicht: dort verpuffen Projektile – sonst verstummte ein Händler am Markt, solange die Karawane
## dort rastet, und ein Wolf davor hätte leichtes Spiel. Querschläger bleiben legitime Treffer (Design [E] 2026-09-07) –
## der NPC vermeidet sie nur, wie es "handelt vorsichtig" verlangt.
static func _bystander_in_line(world: SimWorld, c: SimCharacter, target: SimCharacter, reach: float, target_shields: bool) -> SimCharacter:
	var dir := (target.pos - c.pos).normalized()
	if dir == Vector2.ZERO:
		return null
	var start := c.pos + dir * (c.collision_radius + 0.15)  # dort entsteht das Projektil (SimCombat._shoot)
	var to_target_along := (target.pos - start).dot(dir)
	var length := maxf(to_target_along, 0.0) if target_shields else reach
	var attacker := _current_attacker(world, c)
	var attacker_id := attacker.id if attacker != null else -1
	for other: SimCharacter in world.spatial.query(start + dir * (length * 0.5), length * 0.5 + 1.0):
		if other == c or other == target or other.dead or other.hidden or other.id == attacker_id:
			continue
		if (other.kind == SimCharacter.Kind.WOLF and not other.boss) or world.allied(other.owner_id, c.owner_id):
			continue
		if world.in_peace_zone(other.pos):
			continue
		var along := clampf((other.pos - start).dot(dir), 0.0, length)
		var closest := start + dir * along
		var margin := other.collision_radius + BYSTANDER_MARGIN
		if closest.distance_squared_to(other.pos) >= margin * margin:
			continue
		if along > to_target_along and not SimNav.line_clear(world.map, target.pos, closest, 0.05, "", world.data):
			continue  # hinter dem Ziel und von einer Wand oder einem Bauteil gedeckt
		return other
	return null


## Ohne eigenes Ziel dreht sich der NPC zum nächsten sichtbaren Fremden – berechenbar und umlaufbar.
static func _face_threat_if_idle(world: SimWorld, c: SimCharacter, intent: SimIntent) -> void:
	if intent.aim != Vector2.ZERO or intent.move != Vector2.ZERO:
		return
	var threat := SimCombat.nearest_enemy(world, c, THREAT_LOOK_RADIUS)
	if threat != null:
		intent.aim = threat.pos - c.pos


## Leine: kein Schritt darf den Kreis verlassen. Außerhalb (nach einem Regelwechsel) führt die Wegsuche der
## Ortsaktion zurück; andere Aktionen werden zur Mitte gelenkt.
static func _apply_leash(world: SimWorld, c: SimCharacter, intent: SimIntent, dt: float, navigating: bool = false) -> void:
	if c.leash_radius <= 0.0:
		return
	var offset := c.pos - c.leash_center
	var distance := offset.length()
	if distance > c.leash_radius:
		if not navigating:
			intent.move = SimNav.direction_toward(world, c, c.leash_center, dt, c.leash_radius * 0.5)
		return
	if intent.move == Vector2.ZERO:
		return
	var speed := c.move_speed * (world.data.balf("character.weakened_speed_multiplier") if c.is_weakened() else 1.0)
	var step := intent.move * speed * dt
	if (offset + step).length() <= c.leash_radius:
		return
	# Schritt so kürzen, dass er genau auf dem Kreis endet (auch bei großen Schritten der groben Stufe):
	# größtes f in [0, 1] mit |offset + f * step| = radius
	var a := step.dot(step)
	var b := 2.0 * offset.dot(step)
	var cc := offset.dot(offset) - c.leash_radius * c.leash_radius
	var discriminant := b * b - 4.0 * a * cc
	var f := 0.0
	if a > 0.0 and discriminant >= 0.0:
		f = clampf((-b + sqrt(discriminant)) / (2.0 * a), 0.0, 1.0)
	if f <= 0.001:
		# Am Rand: nur noch am Kreis entlang (tangential), verkürzt, damit der Bogen nicht hinausführt
		var radial := offset / distance
		var tangent := intent.move - radial * intent.move.dot(radial)
		intent.move = tangent * 0.5
	else:
		intent.move *= f
