class_name SimCrafting
extends RefCounted
## Herstellen und Ausrüstung: Rezepte an Stationen (Werkbank, Schmelzofen, Schmiede, Lagerfeuer), Verschleiß und
## Reparatur (nie wieder 100 %), Rüstung explizit anlegen, Waffen und Munition, Heilmittel als Kanalisierung.
## Reine Logik über dem Weltzustand (world als erster Parameter), keine Nodes.


## Leitet Rüstung und Nahkampfwerte aus der getragenen Rüstung und der aktiven Waffe ab (nur Spielercharaktere).
## Rüstung zählt nur, wenn sie angelegt ist (equip_armor); besitzen allein schützt nicht.
static func refresh_equipment(world: SimWorld, c: SimCharacter) -> void:
	if c.kind == SimCharacter.Kind.WOLF:
		return
	if c.kind == SimCharacter.Kind.PLAYER:  # Karawanenleute tragen ihre Rüstung als festen Wert
		if not c.worn_armor.is_empty() and (not c.items.has(c.worn_armor) or world.data.items.get(c.worn_armor, {}).get("kind", "") != "armor"):
			c.worn_armor = ""  # zerbrochen, geplündert oder unbekannt
		var worn: Dictionary = world.data.items.get(c.worn_armor, {})
		c.armor = world.data.balf("character.armor") + float(worn.get("armor", 0.0))
		c.armor_slow = float(worn.get("slow", 0.0))  # schwere Rüstung verlangsamt, solange sie getragen wird
	if not c.items.has(c.active_weapon):
		c.active_weapon = ""
		for item_id: String in c.items:
			if world.data.items[item_id]["kind"] == "weapon":
				c.active_weapon = item_id
				break
	var weapon: Dictionary = world.data.items.get(c.active_weapon, {})
	if weapon.get("attack", "") == "melee":
		c.melee_damage = float(weapon["damage"])
		c.melee_range = float(weapon["range"])
		c.melee_cooldown = float(weapon["cooldown"])
		c.melee_effect = String(weapon.get("effect", ""))
	else:
		c.melee_damage = 0.0
		c.melee_effect = ""


## Herstellen: baut einen Gegenstand (Ausrüstung) oder ein Verbrauchsgut (Rohstoff mit 'cost'). Braucht der Eintrag
## eine Station ('needs_building': Werkbank, Schmelzofen, Schmiede, Lagerfeuer), muss sie in Reichweite stehen.
## Rückgabe: leer = gebaut, sonst der Grund.
static func craft(world: SimWorld, c: SimCharacter, item_id: String) -> String:
	if world.data.resources.has(item_id) and world.data.resources[item_id].has("cost"):
		return _craft_consumable(world, c, item_id)
	var def: Dictionary = world.data.items.get(item_id, {})
	if def.is_empty():
		return "unbekannter Gegenstand"
	if c.items.has(item_id):
		return "schon vorhanden"
	var cost: Dictionary = def.get("cost", {})
	if cost.is_empty():
		return "nicht baubar"
	var station := station_reason(world, c, item_id)
	if not station.is_empty():
		return station
	for rid: String in cost:
		var needed := int(cost[rid])
		if int(c.inventory.get(rid, 0)) < needed:
			return "zu wenig %s (%d nötig)" % [world.data.resources[rid]["name"], needed]
	for rid: String in cost:
		c.inventory[rid] = int(c.inventory[rid]) - int(cost[rid])
	c.items.append(item_id)
	c.durability[item_id] = {"left": float(def["durability"]), "max": float(def["durability"])}
	refresh_equipment(world, c)
	world.events.append({"type": "craft", "id": c.id, "item": item_id})
	return ""


static func durability_left(world: SimWorld, c: SimCharacter, item_id: String) -> float:
	return float(c.durability.get(item_id, {}).get("left", 0.0))


static func durability_max(world: SimWorld, c: SimCharacter, item_id: String) -> float:
	return float(c.durability.get(item_id, {}).get("max", 0.0))


## Reparaturkosten: Anteil der Baukosten, aufgerundet. Leer = nicht reparierbar.
static func repair_cost(world: SimWorld, item_id: String) -> Dictionary:
	var cost: Dictionary = world.data.items.get(item_id, {}).get("cost", {})
	var result := {}
	for rid: String in cost:
		result[rid] = int(ceilf(float(cost[rid]) * world.data.balf("wear.repair_cost_fraction")))
	return result


## Warum die Werkbank einen Gegenstand nicht reparieren kann; leer = möglich.
static func repair_reason(world: SimWorld, c: SimCharacter, item_id: String) -> String:
	if not c.items.has(item_id):
		return "nicht vorhanden"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	var cost := repair_cost(world, item_id)
	if cost.is_empty():
		return "nicht reparierbar"
	var station := station_reason(world, c, item_id)
	if not station.is_empty():
		return station
	var left := durability_left(world, c, item_id)
	var current_max := durability_max(world, c, item_id)
	if left >= current_max - 0.001:
		return "nicht abgenutzt"
	var next_max := current_max - float(world.data.items[item_id]["durability"]) * world.data.balf("wear.repair_max_loss")
	if next_max < 1.0:
		return "zu abgenutzt, nicht mehr reparierbar"
	for rid: String in cost:
		if int(c.inventory.get(rid, 0)) < int(cost[rid]):
			return "zu wenig %s (%d nötig)" % [world.data.resources[rid]["name"], int(cost[rid])]
	return ""


## Repariert an der Werkbank: zurück auf das gesunkene Maximum (nie wieder 100 %). Rückgabe: Grund oder leer.
static func repair(world: SimWorld, c: SimCharacter, item_id: String) -> String:
	var reason := repair_reason(world, c, item_id)
	if not reason.is_empty():
		return reason
	var cost := repair_cost(world, item_id)
	for rid: String in cost:
		c.inventory[rid] = int(c.inventory[rid]) - int(cost[rid])
	var next_max := durability_max(world, c, item_id) - float(world.data.items[item_id]["durability"]) * world.data.balf("wear.repair_max_loss")
	c.durability[item_id] = {"left": next_max, "max": next_max}
	world.events.append({"type": "repair", "id": c.id, "item": item_id, "max": next_max})
	return ""


## Eine Nutzung abziehen; bei 0 zerbricht der Gegenstand (Ereignis, Chronik für Offline-Charaktere).
static func wear(world: SimWorld, c: SimCharacter, item_id: String, amount: float = 1.0) -> void:
	if not c.items.has(item_id):
		return
	if not c.durability.has(item_id):
		c.durability[item_id] = {"left": float(world.data.items[item_id]["durability"]), "max": float(world.data.items[item_id]["durability"])}
	var entry: Dictionary = c.durability[item_id]
	entry["left"] = float(entry["left"]) - amount
	if float(entry["left"]) > 0.0:
		return
	c.items.erase(item_id)
	c.durability.erase(item_id)
	refresh_equipment(world, c)
	world.events.append({"type": "item_broken", "id": c.id, "item": item_id})
	if c.kind == SimCharacter.Kind.PLAYER and c.control == SimCharacter.Controller.RULES:
		SimChronicle.add(world, c, "%s zerbrochen" % world.data.items[item_id]["name"])


## Getragene Rüstung (Kennung) oder leer.
static func armor_item_of(world: SimWorld, c: SimCharacter) -> String:
	return c.worn_armor if c.items.has(c.worn_armor) else ""


## Rüstung anlegen (leer = ablegen). Explizit, nie automatisch: der Spieler entscheidet, was er trägt
## (Design: schwere Rüstung verlangsamt, Gegenmittel ist Ablegen). Rückgabe: Grund oder leer.
static func equip_armor(world: SimWorld, c: SimCharacter, item_id: String) -> String:
	if c.dead:
		return "tot"
	if not item_id.is_empty():
		if not c.items.has(item_id):
			return "nicht vorhanden"
		if world.data.items.get(item_id, {}).get("kind", "") != "armor":
			return "keine Rüstung"
		if c.worn_armor == item_id:
			return "schon angelegt"
	elif c.worn_armor.is_empty():
		return "nichts angelegt"
	c.worn_armor = item_id
	refresh_equipment(world, c)
	world.events.append({"type": "equip", "id": c.id, "item": item_id})
	return ""


## Besessene Rüstungen (Kennungen), in Datenreihenfolge.
static func owned_armors(world: SimWorld, c: SimCharacter) -> Array[String]:
	var result: Array[String] = []
	for item_id: String in world.data.item_order:
		if c.items.has(item_id) and world.data.items[item_id].get("kind", "") == "armor":
			result.append(item_id)
	return result


static func _craft_consumable(world: SimWorld, c: SimCharacter, rid: String) -> String:
	var def: Dictionary = world.data.resources[rid]
	var cost: Dictionary = def["cost"]
	var station := station_reason(world, c, rid)
	if not station.is_empty():
		return station
	for need: String in cost:
		if int(c.inventory.get(need, 0)) < int(cost[need]):
			return "zu wenig %s (%d nötig)" % [world.data.resources[need]["name"], int(cost[need])]
	var produced := int(def.get("yield", 1))
	if c.inventory_count() - _cost_total(cost) + produced > world.data.bali("inventory.capacity"):
		return "Inventar voll"
	for need: String in cost:
		c.inventory[need] = int(c.inventory[need]) - int(cost[need])
	c.inventory[rid] = int(c.inventory.get(rid, 0)) + produced
	world.events.append({"type": "craft", "id": c.id, "item": rid})
	return ""


## Warum ein Verbrauchsgut gerade nicht herstellbar ist (für NPC-Regeln); leer = möglich.
## ignore_station: die Station prüft der Aufrufer selbst (der NPC läuft erst hin).
static func craft_reason(world: SimWorld, c: SimCharacter, rid: String, ignore_station: bool = false) -> String:
	if not world.data.resources.has(rid) or not world.data.resources[rid].has("cost"):
		return "kein herstellbares Verbrauchsgut"
	var cost: Dictionary = world.data.resources[rid]["cost"]
	if not ignore_station:
		var station := station_reason(world, c, rid)
		if not station.is_empty():
			return station
	for need: String in cost:
		if int(c.inventory.get(need, 0)) < int(cost[need]):
			return "zu wenig %s (%d nötig)" % [world.data.resources[need]["name"], int(cost[need])]
	if c.inventory_count() - _cost_total(cost) + int(world.data.resources[rid].get("yield", 1)) > world.data.bali("inventory.capacity"):
		return "Inventar voll"
	return ""


## Nächstes Bauteil einer Art (beliebiger Besitzer) in Interaktionsreichweite, sonst null.
static func building_part_near(world: SimWorld, c: SimCharacter, part: String) -> SimBuilding:
	var reach := world.data.balf("character.interact_range") + 0.5
	for b: SimBuilding in world.map.buildings.values():
		if b.part == part and b.center().distance_to(c.pos) <= reach:
			return b
	return null


## Warum die Station eines Gegenstands/Verbrauchsguts fehlt ("Werkbank nicht in Reichweite"); leer = von Hand oder Station da.
static func station_reason(world: SimWorld, c: SimCharacter, item_id: String) -> String:
	var needs := world.data.station_of(item_id)
	if needs.is_empty() or building_part_near(world, c, needs) != null:
		return ""
	return "%s nicht in Reichweite" % world.data.buildings[needs]["name"]


## Nächste Station einer Art (beliebiger Besitzer) innerhalb der Leine eines NPC, sonst null. Ohne Leine: überall.
static func station_in_leash(world: SimWorld, c: SimCharacter, part: String) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := INF
	for b: SimBuilding in world.map.buildings.values():
		if b.part != part:
			continue
		if c.leash_radius > 0.0 and b.center().distance_to(c.leash_center) > c.leash_radius + 0.5:
			continue
		var d := b.center().distance_squared_to(c.pos)
		if d < best_d:
			best_d = d
			best = b
	return best


## Munition einer Waffe (Kennung des Verbrauchsguts) oder leer, wenn sie keine braucht.
static func ammo_of(world: SimWorld, weapon_id: String) -> String:
	return String(world.data.items.get(weapon_id, {}).get("ammo", ""))


## Kann mit dieser Waffe geschossen werden? (Keine Munition nötig oder Munition dabei.)
static func has_ammo(world: SimWorld, c: SimCharacter, weapon_id: String) -> bool:
	var ammo := ammo_of(world, weapon_id)
	return ammo.is_empty() or int(c.inventory.get(ammo, 0)) > 0


static func _cost_total(cost: Dictionary) -> int:
	var total := 0
	for amount: Variant in cost.values():
		total += int(amount)
	return total


## Passendstes Heilmittel im Inventar: erst eines, das einen laufenden Effekt kuriert, sonst das stärkste,
## wenn Leben fehlt. Leer, wenn nichts hilft.
static func heal_item_of(world: SimWorld, c: SimCharacter) -> String:
	var best := ""
	var best_heal := -1.0
	for rid: String in world.data.resource_order:
		var def: Dictionary = world.data.resources[rid]
		if not def.has("heal") or int(c.inventory.get(rid, 0)) <= 0:
			continue
		for effect: String in def.get("cures", []):
			if SimEffects.has_effect(world, c, effect):
				return rid
		if c.hp < c.max_hp and float(def["heal"]) > best_heal and float(def["heal"]) > 0.0:
			best_heal = float(def["heal"])
			best = rid
	return best


## Heilung = Kanalisierung: heal_time Sekunden ohne Angriff (Laufen erlaubt), dann +heal Leben, Verband weg.
static func update_healing(world: SimWorld, c: SimCharacter, intent: SimIntent, dt: float) -> void:
	if not intent.heal or intent.shoot or intent.melee:
		c.heal_progress = 0.0
		return
	var rid := heal_item_of(world, c)
	if rid.is_empty():
		c.heal_progress = 0.0
		return
	var def: Dictionary = world.data.resources[rid]
	c.heal_progress += dt
	if c.heal_progress + 0.0001 >= float(def["heal_time"]):
		c.heal_progress = 0.0
		var before := c.hp
		c.hp = minf(c.max_hp, c.hp + float(def["heal"]))
		c.inventory[rid] = int(c.inventory[rid]) - 1
		var cured: Array[String] = []
		for effect: String in def.get("cures", []):
			if c.effects.erase(effect):
				cured.append(effect)
		world.events.append({"type": "healed", "id": c.id, "amount": c.hp - before, "resource": rid, "left": int(c.inventory[rid]), "cured": cured})


static func set_active_weapon(world: SimWorld, c: SimCharacter, item_id: String) -> bool:
	if not c.items.has(item_id) or world.data.items.get(item_id, {}).get("kind", "") != "weapon":
		return false
	c.active_weapon = item_id
	refresh_equipment(world, c)
	return true


static func owned_weapons(world: SimWorld, c: SimCharacter) -> Array[String]:
	var result: Array[String] = []
	for item_id: String in c.items:
		if world.data.items.get(item_id, {}).get("kind", "") == "weapon":
			result.append(item_id)
	return result
