class_name SimDefense
extends RefCounted
## Regelgesteuerte Verteidigung: Sensoren (Bedingung über Distanz, Orte in Regeln), Fallen (für Fremde unsichtbar),
## Turrets (Sichtlinie, Munition) und Sprengsätze (Lunte, jede Bauteil-Stufe). Reine Logik über dem Weltzustand.


static func is_sensor(world: SimWorld, b: SimBuilding) -> bool:
	return b != null and world.data.buildings.get(b.part, {}).has("sensor_radius")


static func is_trap(world: SimWorld, b: SimBuilding) -> bool:
	return b != null and world.data.buildings.get(b.part, {}).has("trap_damage")


## Für Fremde unsichtbare Bauteile (Fallen) sieht nur der Besitzer.
static func building_visible_to(world: SimWorld, b: SimBuilding, owner_id: String) -> bool:
	return not bool(world.data.buildings.get(b.part, {}).get("hidden", false)) or world.allied(b.owner_id, owner_id)


## Eigene Sensoren, die gerade ausgelöst sind (Orts-Kennungen), für die Bedingung 'Sensor … ausgelöst'.
static func triggered_sensors_of(world: SimWorld, owner_id: String) -> Array:
	var result := []
	for b: SimBuilding in world.map.buildings.values():
		if world.allied(b.owner_id, owner_id) and is_sensor(world, b) and world.time < b.triggered_until:
			result.append(SimWorld.place_id_of(b))
	return result


static func sensors_of(world: SimWorld, owner_id: String, include_allies: bool = false) -> Array[SimBuilding]:
	var result: Array[SimBuilding] = []
	for b: SimBuilding in world.map.buildings.values():
		if (b.owner_id == owner_id or (include_allies and world.allied(b.owner_id, owner_id))) and is_sensor(world, b):
			result.append(b)
	return result


static func is_turret(world: SimWorld, b: SimBuilding) -> bool:
	return b != null and world.data.buildings.get(b.part, {}).has("turret")


## Munition ins eigene Turret laden (live per E oder NPC-Lieferung). Rückgabe: geladene Menge.
static func turret_load(world: SimWorld, c: SimCharacter, b: SimBuilding, amount: int) -> int:
	if not is_turret(world, b) or not world.allied(b.owner_id, c.owner_id) or c.dead:
		return 0
	var spec: Dictionary = world.data.buildings[b.part]["turret"]
	var ammo := String(spec["ammo"])
	var room := int(spec["capacity"]) - int(b.contents.get(ammo, 0))
	amount = mini(mini(amount, int(c.inventory.get(ammo, 0))), room)
	if amount <= 0:
		return 0
	c.inventory[ammo] = int(c.inventory[ammo]) - amount
	b.contents[ammo] = int(b.contents.get(ammo, 0)) + amount
	world.events.append({"type": "turret_loaded", "id": c.id, "building": b.id, "amount": amount, "stock": int(b.contents[ammo])})
	return amount


## Turret in Reichweite des eigenen Besitzers, sonst null.
static func turret_near(world: SimWorld, c: SimCharacter) -> SimBuilding:
	for b: SimBuilding in world.map.buildings.values():
		if is_turret(world, b) and world.allied(b.owner_id, c.owner_id) and b.center().distance_to(c.pos) <= world.data.balf("character.interact_range") + 0.5:
			return b
	return null


## Sprengsätze: nach der Lunte trifft die Explosion alle Bauteile (jede Stufe) und Charaktere im Radius.
static func update_bombs(world: SimWorld) -> void:
	for id: int in world.map.buildings.keys():
		var b: SimBuilding = world.map.buildings.get(id)
		if b == null:
			continue
		var spec: Dictionary = world.data.buildings[b.part].get("bomb", {})
		if spec.is_empty() or world.time < b.placed_time + float(spec["fuse"]):
			continue
		var center := b.center()
		var radius := float(spec["radius"])
		world.map.remove_building(id)
		world.claims.on_building_removed(world, id)
		world.events.append({"type": "explosion", "building": id, "owner": b.owner_id, "pos": center, "radius": radius})
		for other_id: int in world.map.buildings.keys():
			var other: SimBuilding = world.map.buildings.get(other_id)
			if other != null and other.center().distance_to(center) <= radius:
				SimConstruction.damage_building(world, other, float(spec["building_damage"]), -1)
		for c: SimCharacter in world.spatial.query(center, radius):
			if not c.dead and c.pos.distance_to(center) <= radius and not world.in_peace_zone(c.pos):
				SimCombat.apply_damage(world, c, float(spec["character_damage"]), (c.pos - center).normalized() if c.pos != center else Vector2.DOWN, -1, "", "einen Sprengsatz")


## Turrets: nächster sichtbarer Fremder oder Tier im Radius mit Sichtlinie, ein Schuss je Abklingzeit, eine Kugel je Schuss.
static func update_turrets(world: SimWorld, _dt: float) -> void:
	for b: SimBuilding in world.map.buildings.values():
		if not is_turret(world, b) or world.time < b.triggered_until:
			continue
		var spec: Dictionary = world.data.buildings[b.part]["turret"]
		var ammo := String(spec["ammo"])
		if int(b.contents.get(ammo, 0)) <= 0:
			continue
		var radius := float(spec["radius"])
		var center := b.center()
		var target: SimCharacter = null
		var best := radius * radius
		for other: SimCharacter in world.spatial.query(center, radius):
			if other.dead or other.hidden or world.allied(other.owner_id, b.owner_id) or world.in_peace_zone(other.pos) or SimToll.has_toll_pass_at(world, b, other.owner_id):
				continue
			var d := other.pos.distance_squared_to(center)
			# Sichtlinie ab dem Rand des eigenen Bauteils (sonst blockiert sich das Turret selbst), Bauteile zählen
			var muzzle := center + (other.pos - center).normalized() * 0.85
			if d <= best and SimNav.line_clear(world.map, muzzle, other.pos, 0.1, b.owner_id, world.data):
				best = d
				target = other
		if target == null:
			continue
		b.contents[ammo] = int(b.contents[ammo]) - 1
		b.triggered_until = world.time + float(spec["cooldown"])
		world.events.append({"type": "turret_shot", "building": b.id, "owner": b.owner_id, "target": target.id, "from": center, "to": target.pos})
		SimCombat.apply_damage(world, target, float(spec["damage"]), (target.pos - center).normalized(), -1, "", "ein Turret")


static func update_sensors_and_traps(world: SimWorld, dt: float) -> void:
	if world.map.buildings.is_empty():
		return
	for id: int in world.map.buildings.keys():
		var b: SimBuilding = world.map.buildings.get(id)
		if b == null:
			continue
		var def: Dictionary = world.data.buildings[b.part]
		if def.has("sensor_radius"):
			var was_triggered := world.time < b.triggered_until
			var center := b.center()
			for other: SimCharacter in world.spatial.query(center, float(def["sensor_radius"])):
				if other.dead or world.allied(other.owner_id, b.owner_id) or other.pos.distance_to(center) > float(def["sensor_radius"]):
					continue
				b.triggered_until = world.time + float(def.get("sensor_hold", 5.0))
				if not was_triggered:
					world.events.append({"type": "sensor_triggered", "building": b.id, "owner": b.owner_id, "by": other.id, "label": b.label})
				break
		elif def.has("trap_damage"):
			for other: SimCharacter in world.spatial.query(b.center(), 1.5):
				if other.dead or world.allied(other.owner_id, b.owner_id) or SimToll.has_toll_pass_at(world, b, other.owner_id):
					continue
				var half := SimBuilding.half_cell_of(other.pos)
				if not b.cells.has(half):
					continue
				SimCombat.apply_damage(world, other, float(def["trap_damage"]), Vector2.DOWN, -1)
				world.events.append({"type": "trap_triggered", "building": b.id, "owner": b.owner_id, "by": other.id, "pos": b.center()})
				world.map.remove_building(b.id)
				break
