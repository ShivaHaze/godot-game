class_name CaravanAI
extends RefCounted
## Karawane (Ereignis): ein Händler führt, Lasttiere folgen ihm, Wachen folgen und verteidigen die Karawane, sobald
## ein Mitglied angegriffen wird – sie greifen nie zuerst an und verfolgen nur bis guard.leash um den Händler.
## Erzeugt nur Absichten (SimIntent); Route und Rast verwaltet SimEvents.

const FOLLOW_DISTANCE: float = 1.6


static func decide(world: SimWorld, c: SimCharacter, dt: float) -> SimIntent:
	var intent := SimIntent.new()
	var caravan: Dictionary = world.caravans.get(c.caravan_id, {})
	var leader := world.get_character(c.caravan_leader_id)
	match c.caravan_role:
		"trader":
			if String(caravan.get("leg", "")) == "travel":
				intent.move = SimNav.direction_toward(world, c, caravan.get("goal", c.pos), dt, 1.0)
		"guard":
			var threat := _threat(world, c, caravan)
			if threat != null:
				var spec: Dictionary = world.data.balance["events"]["caravan"]["guard"]
				if leader == null or leader.dead or c.pos.distance_to(leader.pos) <= float(spec.get("leash", 8.0)):
					NpcController._engage(world, c, threat, intent, dt)
				else:
					_follow(world, c, leader, intent, dt)  # nicht weiter weg vom Händler als die Leine erlaubt
			else:
				_follow(world, c, leader, intent, dt)
		_:
			_follow(world, c, leader, intent, dt)
	return intent


## Dem Händler folgen; steht er, bleibt man in seiner Nähe stehen.
static func _follow(world: SimWorld, c: SimCharacter, leader: SimCharacter, intent: SimIntent, dt: float) -> void:
	if leader == null or leader.dead or leader == c:
		return
	if c.pos.distance_to(leader.pos) > FOLLOW_DISTANCE:
		intent.move = SimNav.direction_toward(world, c, leader.pos, dt, FOLLOW_DISTANCE * 0.75)


## Nächster sichtbarer Angreifer eines Karawanenmitglieds (in engage_radius um die Wache), sonst null.
static func _threat(world: SimWorld, guard: SimCharacter, caravan: Dictionary) -> SimCharacter:
	var radius := float(world.data.balance["events"]["caravan"]["guard"].get("engage_radius", 10.0))
	var best: SimCharacter = null
	var best_d := radius * radius
	for id: int in caravan.get("members", []):
		var member := world.get_character(id)
		if member == null or not SimSensors.is_under_attack(world, member):
			continue
		var attacker := world.get_character(member.last_attacker_id)
		if attacker == null or attacker.dead or attacker.hidden or world.allied(attacker.owner_id, guard.owner_id):
			continue
		var d := attacker.pos.distance_squared_to(guard.pos)
		if d <= best_d:
			best_d = d
			best = attacker
	return best
