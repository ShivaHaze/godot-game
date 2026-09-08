class_name SimToll
extends RefCounted
## Zoll: Eigentümer-NPCs setzen Regeln gegen Fremde durch (Design). Der Claim merkt sich je Fremdem die unbezahlte
## Zeit im Claim (Schuld); Zahlung per E beim Zöllner gibt einen Passierschein. Zahlen in balance.json `toll`.
## Reine Logik über dem Weltzustand (world als erster Parameter).


## Claim, für den ein Charakter Zoll eintreibt: der eigene, sonst der verbündete, auf dem er steht.
static func toll_claim_of(world: SimWorld, c: SimCharacter) -> SimClaim:
	var own := world.claims.claim_of_owner(c.owner_id)
	if own != null:
		return own
	var here := world.claims.claim_at_pos(c.pos)
	return here if here != null and world.allied(here.owner_id, c.owner_id) else null


## Zoll-Eintrag eines Fremden an einem Claim; verjährt nach toll.forget_hours ohne Besuch. Setzt last_seen.
static func toll_entry(world: SimWorld, claim: SimClaim, owner_id: String) -> Dictionary:
	var entry: Dictionary = claim.toll.get(owner_id, {})
	if entry.is_empty() or world.time - float(entry.get("last_seen", -1e9)) > world.data.balf("toll.forget_hours") * 3600.0:
		entry = {"debt": 0.0, "paid_until": -1.0, "last_seen": world.time, "demanded": false, "attacking": false}
		claim.toll[owner_id] = entry
	entry["last_seen"] = world.time
	return entry


## Hat der Fremde an diesem Claim gerade Freigang (Zoll gezahlt)?
static func has_toll_pass(world: SimWorld, claim: SimClaim, owner_id: String) -> bool:
	if claim == null or not claim.toll.has(owner_id):
		return false
	return world.time < float(claim.toll[owner_id].get("paid_until", -1.0))


## Freigang am Claim, auf dem ein Bauteil steht (Turrets und Fallen verschonen zahlende Gäste).
static func has_toll_pass_at(world: SimWorld, b: SimBuilding, owner_id: String) -> bool:
	if world.claims.claims.is_empty():
		return false
	return has_toll_pass(world, world.claims.claim_at(SimMap.cell_of(b.center())), owner_id)


## Zollpflichtige im Claim: lebende, sichtbare Menschen anderer Besitzer ohne Freigang.
static func toll_liable_in_claim(world: SimWorld, c: SimCharacter, claim: SimClaim) -> Array[SimCharacter]:
	var result: Array[SimCharacter] = []
	for other: SimCharacter in world.characters.values():
		if other == c or other.dead or other.hidden or other.kind != SimCharacter.Kind.PLAYER or world.allied(other.owner_id, c.owner_id):
			continue
		if claim.tiles.has(SimMap.cell_of(other.pos)) and not has_toll_pass(world, claim, other.owner_id):
			result.append(other)
	return result


## Zöllner in Reichweite, der von diesem Charakter gerade Zoll verlangt, sonst null.
static func toll_keeper_near(world: SimWorld, c: SimCharacter) -> SimCharacter:
	var reach := world.data.balf("character.interact_range") + 0.5
	for other: SimCharacter in world.spatial.query(c.pos, reach):
		if other == c or other.dead or other.kind != SimCharacter.Kind.PLAYER or other.control != SimCharacter.Controller.RULES or world.allied(other.owner_id, c.owner_id):
			continue
		if other.pos.distance_to(c.pos) > reach or other.active_rule_index < 0 or other.active_rule_index >= other.rules.size():
			continue
		if String(other.rules[other.active_rule_index]["then"]["action"]) != "toll":
			continue
		var claim := toll_claim_of(world, other)
		if claim != null and claim.toll.has(c.owner_id) and bool(claim.toll[c.owner_id].get("demanded", false)):
			return other
	return null


## Zoll zahlen (live per E beim Zöllner): Ware wandert in sein Inventar, der Claim gibt Freigang. true = Zöllner war da.
static func pay_toll(world: SimWorld, c: SimCharacter) -> bool:
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return false
	var keeper := toll_keeper_near(world, c)
	if keeper == null:
		return false
	var params: Dictionary = keeper.rules[keeper.active_rule_index]["then"]["params"]
	var rid := String(params["resource"])
	var amount := int(params["amount"])
	if int(c.inventory.get(rid, 0)) < amount:
		world.events.append({"type": "toll_short", "id": c.id, "keeper": keeper.id, "resource": rid, "amount": amount, "reason": "zu wenig %s (%d nötig)" % [world.data.resources[rid]["name"], amount]})
		return true
	if keeper.inventory_count() + amount > world.data.bali("inventory.capacity"):
		world.events.append({"type": "toll_short", "id": c.id, "keeper": keeper.id, "resource": rid, "amount": amount, "reason": "der Zöllner hat keinen Platz mehr"})
		return true
	c.inventory[rid] = int(c.inventory[rid]) - amount
	keeper.inventory[rid] = int(keeper.inventory.get(rid, 0)) + amount
	var claim := toll_claim_of(world, keeper)
	var entry := toll_entry(world, claim, c.owner_id)
	var hours := world.data.balf("toll.pass_hours")
	entry["paid_until"] = world.time + hours * 3600.0
	entry["debt"] = 0.0
	entry["demanded"] = false
	entry["attacking"] = false
	world.events.append({"type": "toll_paid", "id": c.id, "keeper": keeper.id, "owner": keeper.owner_id, "resource": rid, "amount": amount, "hours": hours})
	SimChronicle.add(world, keeper, "Zoll kassiert: %d %s von %s (Freigang %d h)" % [amount, world.data.resources[rid]["name"], world.describe(keeper, c), int(hours)])
	return true
