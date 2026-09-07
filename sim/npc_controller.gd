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
	if c.active_rule_index >= 0 and c.active_rule_index < c.rules.size():
		_execute(world, c, c.rules[c.active_rule_index], intent, dt)
	_face_threat_if_idle(world, c, intent)
	_apply_leash(world, c, intent, dt)
	return intent


## Regelauswertung: erste zutreffende UND ausführbare Regel gewinnt. Eine zutreffende, aber nicht
## ausführbare Regel (z. B. "iss" ohne Essbares) wird übersprungen und einmal in der Chronik vermerkt.
## Protokolliert wird ein Regelwechsel; nimmt der NPC nach einer Pause dieselbe Regel wieder auf, nicht erneut.
static func _evaluate(world: SimWorld, c: SimCharacter) -> void:
	var data := world.data
	var facts := SimSensors.facts_for(world, c)
	var chosen := RuleEngine.NO_MATCH
	var start := 0
	while start < c.rules.size():
		var result := RuleEngine.evaluate(c.rules.slice(start), facts, data)
		if result["index"] == RuleEngine.NO_MATCH:
			break
		var index: int = start + result["index"]
		if _can_execute(world, c, c.rules[index]):
			chosen = index
			break
		if c.skipped_rule_index != index:
			c.skipped_rule_index = index
			SimChronicle.log_rule(world, c, index, c.rules[index], "nicht möglich, übersprungen")
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


static func _can_execute(world: SimWorld, c: SimCharacter, rule: Dictionary) -> bool:
	var data := world.data
	var params: Dictionary = rule["then"]["params"]
	match String(rule["then"]["action"]):
		"eat":
			if c.hunger >= data.balf("hunger.max"):
				return false
			for rid: String in data.resource_order:
				if data.resources[rid].get("edible", false) and int(c.inventory.get(rid, 0)) > 0:
					return true
			return false
		"gather":
			if c.inventory_count() >= data.bali("inventory.capacity"):
				return false
			return _find_gather_node(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"])) != null
	return true


## "iss": sofort ausführen und mit Details protokollieren ("Beeren 4→3").
static func _eat_now(world: SimWorld, c: SimCharacter, index: int, rule: Dictionary) -> void:
	var event := world.eat(c)
	if event.is_empty():
		return
	var name := String(world.data.resources[event["resource"]]["name"])
	SimChronicle.log_rule(world, c, index, rule, "%s %d→%d" % [name, event["before"], event["after"]])


static func _execute(world: SimWorld, c: SimCharacter, rule: Dictionary, intent: SimIntent, dt: float) -> void:
	var params: Dictionary = rule["then"]["params"]
	match String(rule["then"]["action"]):
		"flee_to":
			_go_to(world, c, c.place_pos(String(params["place"])), float(params["radius"]) * 0.5, intent, dt)
			if intent.move != Vector2.ZERO:
				intent.aim = intent.move  # rennt, zeigt den Rücken
		"stay_at":
			var center := c.place_pos(String(params["place"]))
			if c.pos.distance_to(center) > float(params["radius"]) * 0.8:
				_go_to(world, c, center, float(params["radius"]) * 0.5, intent, dt)
		"gather":
			_gather(world, c, String(params["resource"]), c.place_pos(String(params["place"])), float(params["radius"]), intent, dt)
		"fight_back":
			_fight_back(world, c, intent, dt)
		"hide":
			intent.hide = true
		"eat":
			pass  # bereits bei der Auswertung ausgeführt


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
		intent.aim = node.center() - c.pos
	else:
		var stand := SimMap.cell_center(world.map.nearest_walkable_cell(node.cell))
		intent.move = SimNav.direction_toward(world, c, stand, dt, 0.15)


## Nächste Quelle mit Vorrat, deren Mitte innerhalb der Leine liegt.
static func _find_gather_node(world: SimWorld, c: SimCharacter, resource: String, center: Vector2, radius: float) -> SimResourceNode:
	var best: SimResourceNode = null
	var best_d := INF
	for node: SimResourceNode in world.map.nodes.values():
		if node.resource != resource or node.amount <= 0:
			continue
		if node.center().distance_to(center) > radius:
			continue
		var d := node.center().distance_squared_to(c.pos)
		if d < best_d:
			best_d = d
			best = node
	return best


## Zurückkämpfen: Angreifer (oder nächsten Feind) anvisieren, aktuelle Position beschießen,
## vorsichtig Abstand halten. Nie über die Leine hinaus verfolgen (siehe _apply_leash).
static func _fight_back(world: SimWorld, c: SimCharacter, intent: SimIntent, _dt: float) -> void:
	var data := world.data
	var target := world.get_character(c.last_attacker_id)
	if target == null or target.dead or target.hidden:
		target = world.nearest_enemy(c, data.balf("offline.hot_radius"))
	if target == null:
		return
	var to_target := target.pos - c.pos
	var distance := to_target.length()
	intent.aim = to_target  # zielt auf die aktuelle Position, kein Vorhalten
	var preferred := data.balf("npc.preferred_combat_range")
	if distance < preferred * 0.7:
		intent.move = -to_target.normalized()
	elif distance > preferred * 1.3:
		intent.move = to_target.normalized()
	var reach := data.balf("combat.projectile_speed") * data.balf("combat.projectile_lifetime")
	if distance <= reach and SimNav.line_clear(world.map, c.pos, target.pos, 0.1):
		intent.shoot = true


## Ohne eigenes Ziel dreht sich der NPC zum nächsten sichtbaren Fremden – berechenbar und umlaufbar.
static func _face_threat_if_idle(world: SimWorld, c: SimCharacter, intent: SimIntent) -> void:
	if intent.aim != Vector2.ZERO or intent.move != Vector2.ZERO:
		return
	var threat := world.nearest_enemy(c, THREAT_LOOK_RADIUS)
	if threat != null:
		intent.aim = threat.pos - c.pos


## Leine: kein Schritt darf den Kreis verlassen; außerhalb geht es nur zurück zur Mitte.
static func _apply_leash(world: SimWorld, c: SimCharacter, intent: SimIntent, dt: float) -> void:
	if c.leash_radius <= 0.0:
		return
	var offset := c.pos - c.leash_center
	var distance := offset.length()
	if distance > c.leash_radius:
		intent.move = -offset.normalized()
		return
	if intent.move == Vector2.ZERO:
		return
	var speed := c.move_speed * (world.data.balf("character.weakened_speed_multiplier") if c.is_weakened() else 1.0)
	var next := c.pos + intent.move * speed * dt
	if next.distance_to(c.leash_center) > c.leash_radius and distance > 0.0:
		var radial := offset / distance
		var outward := intent.move.dot(radial)
		if outward > 0.0:
			intent.move -= radial * outward  # nur noch am Kreis entlang
