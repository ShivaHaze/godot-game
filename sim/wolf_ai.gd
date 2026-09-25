class_name WolfAI
extends RefCounted
## Wolf-Verhalten als PvE-Druck: streunt um seinen Spawn, greift sichtbare Charaktere in Reichweite an, wendet sich
## gegen jeden, der ihn trifft (auch aus der Ferne; steht jemand näher, zuerst gegen den), beißt im Nahkampf, flieht
## bei wenig Leben und erholt sich danach. Der Leitwolf flieht nie und kehrt nach einer Jagd außerhalb seines Reviers
## unverwundbar heim (Leitwolf-Leine, _start_return).
## Erzeugt Absichten (SimIntent); nur die Leitwolf-Leine setzt Leben und Angreifer direkt zurück.

const STATE_WANDER: String = "wander"
const STATE_CHASE: String = "chase"
const STATE_FLEE: String = "flee"
const STATE_RETURN: String = "return"   # nur Leitwolf: Jagd außerhalb des Reviers abgebrochen, läuft heim (unverwundbar)


static func decide(world: SimWorld, wolf: SimCharacter, dt: float) -> SimIntent:
	var intent := SimIntent.new()
	var data := world.data
	wolf.ai_timer -= dt
	if wolf.ai_state == STATE_RETURN:
		_return_home(world, wolf, intent, dt)
		return intent
	var search_radius := data.balf("wolf.give_up_radius") if wolf.ai_state == STATE_CHASE else data.balf("wolf.aggro_radius")
	# Getroffen: der Suchkreis reicht bis zum Schützen, auch jenseits von aggro_radius/give_up_radius – sonst ließe sich
	# jeder Wolf aus sicherer Entfernung abschießen (Befund Schritt 54: 6 Bogentreffer aus 9–12 Kacheln, der Leitwolf
	# streunte weiter). Das gilt, solange Treffer kommen (combat.under_attack_window). Gejagt wird aber die nächste Beute
	# in diesem Kreis, nicht stur der letzte Schütze: sonst drehten zwei Schützen, die abwechselnd treffen, den Wolf bei
	# jedem Treffer um, und er erreichte keinen (Befund Schritt 54: 0 Bisse in 30 s, auch beim Leitwolf).
	var provoker := _provoker(world, wolf)
	if provoker != null:
		search_radius = maxf(search_radius, wolf.pos.distance_to(provoker.pos) + 0.01)
	var target := nearest_prey(world, wolf, search_radius)
	# Der Leitwolf verteidigt sein Revier, jagt aber nie quer über die Karte: außerhalb ignoriert er Beute und kehrt heim
	# (STATE_RETURN, siehe _start_return). Beschießt ihn ein Live-Spieler, jagt er weiter (provoked_chase_radius), sonst
	# erlegte ihn ein Bogenschütze knapp außerhalb des Reviers gefahrlos (Entscheidung [T] 2026-09-25). Ein
	# Offline-Charakter, der sich nur wehrt, lockt ihn nicht hinaus (Offline eingeschränkt beteiligt, [E]).
	if wolf.boss:
		var provoked := provoker != null and provoker.control == SimCharacter.Controller.PLAYER
		var limit := data.balf("events.boss.provoked_chase_radius") if provoked else data.balf("events.boss.territory_radius")
		if wolf.pos.distance_to(wolf.home_pos) > limit:
			target = null

	if wolf.ai_state != STATE_FLEE and target != null and not wolf.boss and wolf.health_percent() < data.balf("wolf.flee_hp_percent"):  # der Leitwolf flieht nie
		wolf.ai_state = STATE_FLEE
		wolf.ai_timer = data.balf("wolf.flee_duration")

	match wolf.ai_state:
		STATE_FLEE:
			if wolf.ai_timer <= 0.0:
				wolf.ai_state = STATE_WANDER
				wolf.ai_timer = 0.0
			else:
				var threat := target if target != null else world.get_character(wolf.last_attacker_id)
				if threat != null and threat.pos != wolf.pos:
					intent.move = (wolf.pos - threat.pos).normalized()
					intent.aim = intent.move  # rennt weg, zeigt den Rücken
				else:
					_wander(world, wolf, intent)
		STATE_CHASE:
			if target == null and wolf.boss and wolf.pos.distance_to(wolf.home_pos) > data.balf("events.boss.territory_radius"):
				_start_return(world, wolf)
				_return_home(world, wolf, intent, dt)
			elif target == null:
				wolf.ai_state = STATE_WANDER
				wolf.ai_timer = 0.0
			else:
				intent.aim = target.pos - wolf.pos
				if wolf.pos.distance_to(target.pos) <= wolf.melee_range:
					intent.melee = true
				else:
					intent.move = SimNav.direction_toward(world, wolf, target.pos, dt, wolf.melee_range * 0.8)
		_:
			if target != null:
				wolf.ai_state = STATE_CHASE
				intent.aim = target.pos - wolf.pos
			else:
				_wander(world, wolf, intent)
	return intent


## Nächster lebender, sichtbarer Spielercharakter (live oder NPC) im Radius.
static func nearest_prey(world: SimWorld, wolf: SimCharacter, radius: float) -> SimCharacter:
	var best: SimCharacter = null
	var best_d := radius * radius
	for c: SimCharacter in world.spatial.query(wolf.pos, radius):
		if c.kind != SimCharacter.Kind.PLAYER or c.dead or c.hidden or world.in_peace_zone(c.pos):
			continue
		var d := c.pos.distance_squared_to(wolf.pos)
		if d <= best_d:
			best_d = d
			best = c
	return best


## Wer den Wolf gerade getroffen hat (innerhalb combat.under_attack_window): ein lebender, sichtbarer Spielercharakter
## außerhalb kampffreier Zonen – dieselbe Beute, die nearest_prey auch sonst findet (so liegt der Schütze sicher im
## erweiterten Suchkreis). Turrets, Fallen und Sprengsätze haben keinen Schützen (Angreifer -1) und locken ihn nicht weg.
static func _provoker(world: SimWorld, wolf: SimCharacter) -> SimCharacter:
	if wolf.last_attacker_id < 0 or not SimSensors.is_under_attack(world, wolf):
		return null
	var attacker := world.get_character(wolf.last_attacker_id)
	if attacker == null or attacker.kind != SimCharacter.Kind.PLAYER or attacker.dead or attacker.hidden or world.in_peace_zone(attacker.pos):
		return null
	return attacker


## Leitwolf-Leine: endet eine Jagd außerhalb seines Reviers (Beute zu weit weg, im Markt, versteckt oder tot), läuft er
## mit voller Geschwindigkeit heim, bis er wieder in seinem Streifgebiet (events.boss.wander_radius) ist – dabei ist er
## unverwundbar (SimCombat.apply_damage), heilt voll und vergisst den Schützen. Vorher kehrte er gemächlich um, und der
## nächste Treffer holte ihn zurück: ein Bogenschütze im Rückwärtsgang erlegte ihn allein ohne einen Biss (Review
## Schritt 55: tot nach 13 s, auch mit der Schleuder und am Markt). Entscheidung [T] 2026-09-25.
static func _start_return(world: SimWorld, wolf: SimCharacter) -> void:
	if wolf.last_attacker_id >= 0 and SimSensors.is_under_attack(world, wolf):
		world.events.append({"type": "boss_evade", "id": wolf.id, "attacker": wolf.last_attacker_id, "name": wolf.name, "pos": wolf.pos})
	wolf.ai_state = STATE_RETURN
	wolf.ai_timer = world.data.balf("events.boss.return_max_seconds")
	wolf.hp = wolf.max_hp
	wolf.effects.clear()
	wolf.last_attacker_id = -1
	wolf.last_damage_time = -1e9


## Heimweg nach _start_return. Endet im Streifgebiet – oder nach return_max_seconds, falls der Weg verbaut ist.
static func _return_home(world: SimWorld, wolf: SimCharacter, intent: SimIntent, dt: float) -> void:
	var r := world.data.balf("events.boss.wander_radius")
	if wolf.pos.distance_to(wolf.home_pos) <= r or wolf.ai_timer <= 0.0:
		wolf.ai_state = STATE_WANDER
		wolf.ai_timer = 0.0
		return
	intent.move = SimNav.direction_toward(world, wolf, wolf.home_pos, dt, r * 0.5)
	intent.aim = intent.move


static func _wander(world: SimWorld, wolf: SimCharacter, intent: SimIntent) -> void:
	var r := world.data.balf("events.boss.wander_radius") if wolf.boss else world.data.balf("wolf.wander_radius")  # der Leitwolf bleibt im Zentrum
	if wolf.ai_timer <= 0.0 or wolf.pos.distance_to(wolf.ai_target_pos) < 0.4:
		wolf.ai_target_pos = wolf.home_pos + Vector2(world.rng.randf_range(-r, r), world.rng.randf_range(-r, r))
		wolf.ai_timer = world.rng.randf_range(2.0, 5.0)
	var to_target := wolf.ai_target_pos - wolf.pos
	if to_target.length() > 0.4:
		intent.move = to_target.normalized() * 0.5  # gemächlich
