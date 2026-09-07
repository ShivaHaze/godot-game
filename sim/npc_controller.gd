class_name NpcController
extends RefCounted
## Offline-Modus: führt die Regelliste eines Charakters aus. Derselbe Körper und dasselbe Kampfsystem
## wie live, aber schlechter: zielt auf die aktuelle statt die zukünftige Position, dreht sich zur
## Bedrohung (umlaufbar), hält vorsichtig Abstand. Die Leine – der Kreis der zuletzt gefeuerten
## Ortsregel – wird nie verlassen. Erzeugt nur Absichten (SimIntent) und Chronik-Einträge.

const THREAT_LOOK_RADIUS: float = 10.0  # Bis zu dieser Distanz dreht sich der NPC zum nächsten Fremden


static func decide(world: SimWorld, c: SimCharacter, dt: float) -> SimIntent:
	var intent := SimIntent.new()
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
		if String(rule["then"]["action"]) != "eat" and chosen != c.last_logged_rule_index:
			c.last_logged_rule_index = chosen
			SimChronicle.log_rule(world, c, chosen, rule)
	if chosen != RuleEngine.NO_MATCH and String(c.rules[chosen]["then"]["action"]) == "eat":
		c.last_logged_rule_index = chosen
		_eat_now(world, c, chosen, c.rules[chosen])


## Warum eine zutreffende Regel gerade nicht ausführbar ist; leer = ausführbar.
static func blocked_reason(world: SimWorld, c: SimCharacter, rule: Dictionary) -> String:
	var data := world.data
	var params: Dictionary = rule["then"]["params"]
	if not world.can_use(c, data.action_def(String(rule["then"]["action"]))) or not world.can_use(c, data.condition_def(String(rule["if"]["condition"]))):
		return "Baustein nicht freigeschaltet"
	for param_def: Dictionary in data.action_def(String(rule["then"]["action"])).get("params", []):
		if String(param_def["type"]) == "place":
			var place := String(params.get(param_def["name"], SimData.PLACE_HERE))
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
				if _find_gather_node(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"]), false) != null:
					return "braucht eine Mine daneben"
				return "nichts zu sammeln in der Leine"
		"hide":
			if world.in_transition(c):
				return "Logout-Übergang läuft"
		"heal_self":
			if c.hp >= c.max_hp and not world.has_effect(c, "bleeding"):
				return "gesund"
			if world.heal_item_of(c).is_empty():
				return "kein Verband"
		"craft":
			var reason := world.craft_reason(c, String(params["product"]))
			if not reason.is_empty():
				return reason
		"deliver":
			var rid := String(params["resource"])
			if int(c.inventory.get(rid, 0)) <= 0:
				return "nichts zu liefern"
			var target := world.container_near(c.owner_id, c.place_pos(String(params["place"])), float(params["radius"]))
			if target == null:
				return "kein eigener Anker oder Handelstisch am Ort"
			if target.part == "anchor" and rid != "wood":
				return "der Anker nimmt nur Holz"
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
			_fight_back(world, c, intent, dt)
		"attack":
			_attack_nearby(world, c, float(params["radius"]), intent, dt)
		"hide":
			intent.hide = true
		"heal_self":
			intent.heal = true  # kanalisiert; greift währenddessen nicht an, darf aber laufen
		"deliver":
			_deliver(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"]), intent, dt)
			return true
		"craft":
			var rid := String(params["product"])
			if world.craft(c, rid).is_empty():
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
	var target := world.container_near(c.owner_id, center, radius)
	if target == null:
		return
	var reach := world.data.balf("character.interact_range")
	if c.pos.distance_to(target.center()) <= reach + 0.3:
		var moved := world.deliver_to(c, target, rid)
		if moved > 0:
			var index := c.active_rule_index
			SimChronicle.log_rule(world, c, index, c.rules[index], "%d %s" % [moved, world.data.resources[rid]["name"]])
			c.last_logged_rule_index = -1  # nächste Lieferung wird wieder protokolliert
		return
	var stand := SimMap.cell_center(world.map.nearest_walkable_cell(SimMap.cell_of(target.center())))
	intent.move = SimNav.direction_toward(world, c, stand, dt, 0.15)


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
		if require_mine and not world.node_offline_ok(node, c.owner_id):
			continue  # Eisen/Kohle offline nur mit Mine daneben
		var d := node.center().distance_squared_to(c.pos)
		if d < best_d:
			best_d = d
			best = node
	return best


## Zurückkämpfen: Angreifer (oder nächsten Feind) anvisieren, aktuelle Position beschießen,
## vorsichtig Abstand halten. Nie über die Leine hinaus verfolgen (siehe _apply_leash).
static func _fight_back(world: SimWorld, c: SimCharacter, intent: SimIntent, dt: float) -> void:
	var target := world.get_character(c.last_attacker_id)
	if target == null or target.dead or target.hidden:
		target = world.nearest_enemy(c, world.data.balf("offline.hot_radius"))
	if target == null:
		return
	_engage(world, c, target, intent, dt)


## Angreifen (freigeschaltet): nächsten sichtbaren Fremden im Radius angreifen, ohne selbst angegriffen zu sein.
static func _attack_nearby(world: SimWorld, c: SimCharacter, radius: float, intent: SimIntent, dt: float) -> void:
	var target := world.nearest_enemy(c, radius)
	if target == null:
		return
	_engage(world, c, target, intent, dt)


## Gemeinsame Kampfausführung: Waffenwahl, Abstand, Schuss auf die aktuelle Position.
static func _engage(world: SimWorld, c: SimCharacter, target: SimCharacter, intent: SimIntent, _dt: float) -> void:
	var data := world.data
	var to_target := target.pos - c.pos
	var distance := to_target.length()
	intent.aim = to_target  # zielt auf die aktuelle Position, kein Vorhalten
	# Waffenwahl: Nahkampf nur, wenn der Feind schon in Reichweite steht; sonst vorsichtig auf Abstand schießen
	var melee_id := ""
	var ranged_id := ""
	for item_id: String in world.owned_weapons(c):
		if data.items[item_id]["attack"] == "melee" and melee_id.is_empty():
			melee_id = item_id
		elif data.items[item_id]["attack"] == "ranged" and world.has_ammo(c, item_id) \
				and (ranged_id.is_empty() or float(data.items[item_id]["damage"]) > float(data.items[ranged_id]["damage"])):
			ranged_id = item_id  # stärkste Fernwaffe mit Munition
	if not melee_id.is_empty() and distance <= float(data.items[melee_id]["range"]) * 1.1:
		world.set_active_weapon(c, melee_id)
		intent.shoot = true
		return
	if ranged_id.is_empty():
		if not melee_id.is_empty():
			world.set_active_weapon(c, melee_id)
			intent.move = to_target.normalized()  # nur Nahkampf: hingehen
		return
	world.set_active_weapon(c, ranged_id)
	var preferred := data.balf("npc.preferred_combat_range")
	if distance < preferred * 0.7:
		intent.move = -to_target.normalized()
	elif distance > preferred * 1.3:
		intent.move = to_target.normalized()
	var weapon: Dictionary = data.items[ranged_id]
	var reach := float(weapon["projectile_speed"]) * float(weapon["projectile_lifetime"])
	if distance <= reach and SimNav.line_clear(world.map, c.pos, target.pos, 0.1):
		intent.shoot = true


## Ohne eigenes Ziel dreht sich der NPC zum nächsten sichtbaren Fremden – berechenbar und umlaufbar.
static func _face_threat_if_idle(world: SimWorld, c: SimCharacter, intent: SimIntent) -> void:
	if intent.aim != Vector2.ZERO or intent.move != Vector2.ZERO:
		return
	var threat := world.nearest_enemy(c, THREAT_LOOK_RADIUS)
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
