class_name SimTrade
extends RefCounted
## Handel: Handelstisch (Lager, Angebote, Kauf, Beute bei Zerstörung), Markt- und Outpost-Depots (Gebühr als Senke,
## Bestände je Besitzer) und Lieferung in Bauteile (Anker, Tisch, Turret, Depot). Tausch ohne Währung (Design).
## Reine Logik über dem Weltzustand (world als erster Parameter).


## Bauteile, in die geliefert werden kann (Anker nimmt Holz für den Unterhalt, Handelstisch alles).
static func is_container(world: SimWorld, b: SimBuilding) -> bool:
	return b != null and (b.part == "anchor" or is_trade_table(world, b) or is_depot(world, b) or SimDefense.is_turret(world, b))


## Liefert alles von `rid` in ein eigenes Bauteil (Anker: nur Holz; Handelstisch: alles) in Reichweite. Rückgabe: Menge.
static func deliver_to(world: SimWorld, c: SimCharacter, b: SimBuilding, rid: String) -> int:
	if not is_container(world, b) or (not world.allied(b.owner_id, c.owner_id) and not is_depot(world, b)) or c.dead:
		return 0
	if b.center().distance_to(c.pos) > world.data.balf("character.interact_range") + 0.5:
		return 0
	var amount := int(c.inventory.get(rid, 0))
	if amount <= 0:
		return 0
	if is_depot(world, b):
		if not depot_deposit(world, c, b, rid, amount, true).is_empty():
			return 0
		return amount - int(c.inventory.get(rid, 0))
	if SimDefense.is_turret(world, b):
		return SimDefense.turret_load(world, c, b, amount) if rid == String(world.data.buildings[b.part]["turret"]["ammo"]) else 0
	if b.part == "anchor":
		if rid != "wood":
			return 0
		var claim := world.claims.claim_at(SimMap.cell_of(b.center()))  # auch der Anker eines Gildenmitglieds
		if claim == null:
			claim = world.claims.claim_of_owner(c.owner_id)
		return world.claims.deposit(world, c, claim, amount)
	var before := int(b.contents.get(rid, 0))
	if not table_deposit(world, c, b, rid, amount, true).is_empty():
		return 0
	return int(b.contents.get(rid, 0)) - before


## Eigenes Bauteil mit Aufnahme (Anker/Tisch) nahe einer Position, sonst null.
static func container_near(world: SimWorld, owner_id: String, pos: Vector2, radius: float) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := radius
	for b: SimBuilding in world.map.buildings.values():
		if not is_container(world, b) or (not world.allied(b.owner_id, owner_id) and not is_depot(world, b)):
			continue
		var d := b.center().distance_to(pos)
		if d <= best_d:
			best_d = d
			best = b
	return best


static func is_depot(world: SimWorld, b: SimBuilding) -> bool:
	return b != null and bool(world.data.buildings.get(b.part, {}).get("depot", false))


static func depots(world: SimWorld) -> Array[SimBuilding]:
	var result: Array[SimBuilding] = []
	for b: SimBuilding in world.map.buildings.values():
		if is_depot(world, b):
			result.append(b)
	result.sort_custom(func(a: SimBuilding, b: SimBuilding) -> bool: return a.id < b.id)
	return result


## Gebühr eines Depots (nach seiner Zone).
static func depot_fee_of(world: SimWorld, b: SimBuilding) -> float:
	return float(world.zone_at(b.center()).get("depot_fee", 0.2))


## Depot in Interaktionsreichweite, sonst null.
static func depot_near(world: SimWorld, c: SimCharacter) -> SimBuilding:
	for b: SimBuilding in world.map.buildings.values():
		if is_depot(world, b) and b.center().distance_to(c.pos) <= world.data.balf("character.interact_range") + 0.5:
			return b
	return null


## Eigener Bestand in einem Depot (Verweis). Im Client-Spiegel liegt der eigene Bestand in `contents`.
static func depot_stock(world: SimWorld, b: SimBuilding, owner_id: String) -> Dictionary:
	if b.stores.has(owner_id):
		return b.stores[owner_id]
	return b.contents if b.stores.is_empty() else {}


static func depot_stock_count(world: SimWorld, b: SimBuilding, owner_id: String) -> int:
	var total := 0
	for amount: int in depot_stock(world, b, owner_id).values():
		total += amount
	return total


static func _depot_reason(world: SimWorld, c: SimCharacter, b: SimBuilding, allow_npc: bool) -> String:
	if not is_depot(world, b):
		return "kein Depot"
	if c.dead or (c.control != SimCharacter.Controller.PLAYER and not allow_npc):
		return "nur live"
	if b.center().distance_to(c.pos) > world.data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	return ""


## Einlagern: die Gebühr (Anteil) geht verloren – die Senke des neutralen Markts. Rückgabe: Grund oder leer.
static func depot_deposit(world: SimWorld, c: SimCharacter, b: SimBuilding, rid: String, amount: int, allow_npc: bool = false) -> String:
	var reason := _depot_reason(world, c, b, allow_npc)
	if not reason.is_empty():
		return reason
	if not world.data.resources.has(rid):
		return "unbekannter Rohstoff"
	if bool(world.data.resources[rid].get("raid_good", false)) and not bool(world.zone_at(b.center()).get("raid_goods", false)):
		return "Raidware: am neutralen Markt nicht handelbar"
	amount = mini(amount, int(c.inventory.get(rid, 0)))
	if amount <= 0:
		return "nichts einzulagern"
	var capacity := world.data.bali("market.depot_capacity")
	var room := capacity - depot_stock_count(world, b, c.owner_id)
	if room <= 0:
		return "Depot voll (%d)" % capacity
	var keep_fraction := 1.0 - depot_fee_of(world, b)
	var kept := int(floorf(float(amount) * keep_fraction))
	if kept <= 0:
		return "zu wenig, die Gebühr frisst alles"
	if kept > room:
		amount = mini(int(ceilf(float(room) / keep_fraction)), int(c.inventory.get(rid, 0)))
		kept = mini(room, int(floorf(float(amount) * keep_fraction)))
	if not b.stores.has(c.owner_id):
		b.stores[c.owner_id] = {}
	b.stores[c.owner_id][rid] = int(b.stores[c.owner_id].get(rid, 0)) + kept
	c.inventory[rid] = int(c.inventory[rid]) - amount
	world.events.append({"type": "depot_deposit", "id": c.id, "building": b.id, "resource": rid, "amount": amount, "kept": kept, "fee": amount - kept})
	return ""


## Entnehmen ist gebührenfrei; nur so viel, wie ins Inventar passt.
static func depot_withdraw(world: SimWorld, c: SimCharacter, b: SimBuilding, rid: String, amount: int) -> String:
	var reason := _depot_reason(world, c, b, false)
	if not reason.is_empty():
		return reason
	var stock := depot_stock(world, b, c.owner_id)
	amount = mini(amount, int(stock.get(rid, 0)))
	if amount <= 0:
		return "nichts im Depot"
	var room := world.data.bali("inventory.capacity") - c.inventory_count()
	if room <= 0:
		return "Inventar voll"
	amount = mini(amount, room)
	stock[rid] = int(stock[rid]) - amount
	if int(stock[rid]) <= 0:
		stock.erase(rid)
	c.inventory[rid] = int(c.inventory.get(rid, 0)) + amount
	world.events.append({"type": "depot_withdraw", "id": c.id, "building": b.id, "resource": rid, "amount": amount})
	return ""


static func is_trade_table(world: SimWorld, b: SimBuilding) -> bool:
	return b != null and bool(world.data.buildings.get(b.part, {}).get("trade", false))


## Handelstisch in Interaktionsreichweite des Charakters (nächster), sonst null.
static func trade_table_near(world: SimWorld, c: SimCharacter) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := world.data.balf("character.interact_range") + 0.5
	for b: SimBuilding in world.map.buildings.values():
		if not is_trade_table(world, b):
			continue
		var d := b.center().distance_to(c.pos)
		if d <= best_d:
			best_d = d
			best = b
	return best


static func _table_owner_reason(world: SimWorld, c: SimCharacter, b: SimBuilding, allow_npc: bool = false) -> String:
	if not is_trade_table(world, b):
		return "kein Handelstisch"
	if b.owner_id != c.owner_id:
		return "nicht dein Tisch"
	if c.dead or (c.control != SimCharacter.Controller.PLAYER and not allow_npc):
		return "nur live"
	if b.center().distance_to(c.pos) > world.data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	return ""


## Besitzer legt Waren hinein. Rückgabe: Grund oder leer.
static func table_deposit(world: SimWorld, c: SimCharacter, b: SimBuilding, rid: String, amount: int, allow_npc: bool = false) -> String:
	var reason := _table_owner_reason(world, c, b, allow_npc)
	if not reason.is_empty():
		return reason
	if not world.data.resources.has(rid) or amount <= 0:
		return "ungültig"
	amount = mini(amount, int(c.inventory.get(rid, 0)))
	amount = mini(amount, world.data.bali("building.table_capacity") - b.contents_count())
	if amount <= 0:
		return "nichts zu lagern oder Tisch voll"
	c.inventory[rid] = int(c.inventory[rid]) - amount
	b.contents[rid] = int(b.contents.get(rid, 0)) + amount
	world.events.append({"type": "table_change", "building": b.id, "id": c.id})
	return ""


static func table_withdraw(world: SimWorld, c: SimCharacter, b: SimBuilding, rid: String, amount: int) -> String:
	var reason := _table_owner_reason(world, c, b)
	if not reason.is_empty():
		return reason
	amount = mini(amount, int(b.contents.get(rid, 0)))
	amount = mini(amount, world.data.bali("inventory.capacity") - c.inventory_count())
	if amount <= 0:
		return "nichts zu entnehmen oder Inventar voll"
	b.contents[rid] = int(b.contents[rid]) - amount
	if b.contents[rid] <= 0:
		b.contents.erase(rid)
	c.inventory[rid] = int(c.inventory.get(rid, 0)) + amount
	world.events.append({"type": "table_change", "building": b.id, "id": c.id})
	return ""


## Angebote setzen: Liste von {sell, sell_amount, price, price_amount}.
static func table_set_offers(world: SimWorld, c: SimCharacter, b: SimBuilding, offers: Array) -> String:
	var reason := _table_owner_reason(world, c, b)
	if not reason.is_empty():
		return reason
	if offers.size() > world.data.bali("building.table_max_offers"):
		return "höchstens %d Angebote" % world.data.bali("building.table_max_offers")
	var clean := []
	for offer: Variant in offers:
		if not (offer is Dictionary):
			return "ungültiges Angebot"
		var sell := String(offer.get("sell", ""))
		var price := String(offer.get("price", ""))
		var sell_amount := int(offer.get("sell_amount", 0))
		var price_amount := int(offer.get("price_amount", 0))
		if not world.data.resources.has(sell) or not world.data.resources.has(price) or sell == price:
			return "ungültiges Angebot"
		if sell_amount < 1 or sell_amount > 99 or price_amount < 1 or price_amount > 99:
			return "Mengen 1 bis 99"
		clean.append({"sell": sell, "sell_amount": sell_amount, "price": price, "price_amount": price_amount})
	b.offers = clean
	world.events.append({"type": "table_change", "building": b.id, "id": c.id})
	return ""


## Kauf durch einen Live-Charakter: zahlt den Preis in den Tisch, nimmt die Ware. Rückgabe: Grund oder leer.
static func table_buy(world: SimWorld, c: SimCharacter, b: SimBuilding, index: int) -> String:
	if not is_trade_table(world, b):
		return "kein Handelstisch"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	if b.center().distance_to(c.pos) > world.data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	if index < 0 or index >= b.offers.size():
		return "kein solches Angebot"
	var offer: Dictionary = b.offers[index]
	var sell := String(offer["sell"])
	var price := String(offer["price"])
	var sell_amount := int(offer["sell_amount"])
	var price_amount := int(offer["price_amount"])
	if int(b.contents.get(sell, 0)) < sell_amount:
		return "ausverkauft"
	if int(c.inventory.get(price, 0)) < price_amount:
		return "zu wenig %s (%d nötig)" % [world.data.resources[price]["name"], price_amount]
	if c.inventory_count() - price_amount + sell_amount > world.data.bali("inventory.capacity"):
		return "Inventar zu voll"
	if b.contents_count() - sell_amount + price_amount > world.data.bali("building.table_capacity"):
		return "Tisch kann die Bezahlung nicht fassen"
	c.inventory[price] = int(c.inventory[price]) - price_amount
	c.inventory[sell] = int(c.inventory.get(sell, 0)) + sell_amount
	b.contents[sell] = int(b.contents[sell]) - sell_amount
	if b.contents[sell] <= 0:
		b.contents.erase(sell)
	b.contents[price] = int(b.contents.get(price, 0)) + price_amount
	world.events.append({"type": "trade", "building": b.id, "id": c.id, "owner": b.owner_id, "sell": sell, "sell_amount": sell_amount, "price": price, "price_amount": price_amount})
	return ""


## Tisch zerstört: der Inhalt fällt dem Zerstörer zu (so weit Platz ist), sonst verfällt er.
static func loot_table(world: SimWorld, b: SimBuilding, attacker_id: int) -> void:
	var taker := world.get_character(attacker_id)
	if taker == null or b.contents.is_empty():
		return
	var capacity := world.data.bali("inventory.capacity")
	var taken := {}
	for rid: String in b.contents.keys():
		var moved := mini(int(b.contents[rid]), capacity - taker.inventory_count())
		if moved <= 0:
			continue
		taker.inventory[rid] = int(taker.inventory.get(rid, 0)) + moved
		taken[rid] = moved
	if not taken.is_empty():
		world.events.append({"type": "loot", "id": taker.id, "from": -1, "items": taken, "equipment": [], "table": b.id})
	b.contents.clear()


# --- Karawane -------------------------------------------------------------
## Die Karawane handelt nur bei der Rast: sie kauft Waren aus events.caravan.prices (lot Stück für pay Kupfer) und
## verkauft ihre Fracht zu pay × markup. Fracht liegt auf den Lasttieren, die Kasse beim Händler – beides Beute.

static func caravan_currency(world: SimWorld) -> String:
	return String(world.data.balance["events"]["caravan"].get("currency", "copper"))


## Karawanenhändler in Interaktionsreichweite, sonst null.
static func caravan_trader_near(world: SimWorld, c: SimCharacter) -> SimCharacter:
	var reach := world.data.balf("character.interact_range") + 0.5
	for other: SimCharacter in world.spatial.query(c.pos, reach):
		if other.dead or other.kind != SimCharacter.Kind.CARAVAN or other.caravan_role != "trader":
			continue
		if other.pos.distance_to(c.pos) <= reach:
			return other
	return null


static func caravan_resting(world: SimWorld, trader: SimCharacter) -> bool:
	return String(world.caravans.get(trader.caravan_id, {}).get("leg", "")) == "rest"


## Kasse der Karawane (im Client-Spiegel aus dem Snapshot).
static func caravan_copper(world: SimWorld, trader: SimCharacter) -> int:
	var caravan: Dictionary = world.caravans.get(trader.caravan_id, {})
	if caravan.has("copper"):
		return int(caravan["copper"])
	return int(trader.inventory.get(caravan_currency(world), 0))


## Fracht aller lebenden Lasttiere (im Client-Spiegel aus dem Snapshot).
static func caravan_cargo(world: SimWorld, trader: SimCharacter) -> Dictionary:
	var caravan: Dictionary = world.caravans.get(trader.caravan_id, {})
	if caravan.has("cargo"):
		return caravan["cargo"]
	var cargo := {}
	for member_id: int in caravan.get("members", []):
		var member := world.get_character(member_id)
		if member == null or member.dead or member.caravan_role != "animal":
			continue
		for rid: String in member.inventory:
			cargo[rid] = int(cargo.get(rid, 0)) + int(member.inventory[rid])
	return cargo


## Verkaufspreis der Karawane je Los: Einkaufspreis × Aufschlag, aufgerundet.
static func caravan_ask_price(world: SimWorld, rid: String) -> int:
	var spec: Dictionary = world.data.balance["events"]["caravan"]
	var price: Dictionary = spec["prices"].get(rid, {})
	return int(ceilf(float(price.get("pay", 1)) * float(spec.get("markup", 2.0))))


static func _caravan_reason(world: SimWorld, c: SimCharacter, trader: SimCharacter, rid: String) -> String:
	if trader == null or trader.dead or trader.kind != SimCharacter.Kind.CARAVAN or trader.caravan_role != "trader":
		return "kein Karawanenhändler"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	if trader.pos.distance_to(c.pos) > world.data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	if not caravan_resting(world, trader):
		return "die Karawane handelt nur bei der Rast"
	if not world.data.resources.has(rid) or rid == caravan_currency(world) or not world.data.balance["events"]["caravan"]["prices"].has(rid):
		return "das handelt die Karawane nicht"
	if bool(world.data.resources[rid].get("raid_good", false)):
		return "Raidware handelt die Karawane nicht"
	return ""


## Lasttier mit Platz für ein Los, sonst null.
static func _animal_with_room(world: SimWorld, trader: SimCharacter, lot: int) -> SimCharacter:
	var capacity := int(world.data.balance["events"]["caravan"]["animal"].get("cargo_capacity", 40))
	for member_id: int in world.caravans.get(trader.caravan_id, {}).get("members", []):
		var member := world.get_character(member_id)
		if member != null and not member.dead and member.caravan_role == "animal" and member.inventory_count() + lot <= capacity:
			return member
	return null


## Spieler verkauft ein Los an die Karawane: Ware aufs Lasttier, Kupfer aus der Kasse. Rückgabe: Grund oder leer.
static func caravan_sell(world: SimWorld, c: SimCharacter, trader: SimCharacter, rid: String) -> String:
	var reason := _caravan_reason(world, c, trader, rid)
	if not reason.is_empty():
		return reason
	var price: Dictionary = world.data.balance["events"]["caravan"]["prices"][rid]
	var lot := int(price["lot"])
	var pay := int(price["pay"])
	var currency := caravan_currency(world)
	if int(c.inventory.get(rid, 0)) < lot:
		return "zu wenig %s (%d nötig)" % [world.data.resources[rid]["name"], lot]
	if int(trader.inventory.get(currency, 0)) < pay:
		return "die Kasse der Karawane ist leer"
	var animal := _animal_with_room(world, trader, lot)
	if animal == null:
		return "die Lasttiere sind voll oder tot"
	if c.inventory_count() - lot + pay > world.data.bali("inventory.capacity"):
		return "Inventar voll"
	c.inventory[rid] = int(c.inventory[rid]) - lot
	c.inventory[currency] = int(c.inventory.get(currency, 0)) + pay
	trader.inventory[currency] = int(trader.inventory[currency]) - pay
	animal.inventory[rid] = int(animal.inventory.get(rid, 0)) + lot
	world.events.append({"type": "caravan_trade", "id": c.id, "kind": "sell", "resource": rid, "amount": lot, "copper": pay})
	return ""


## Spieler kauft ein Los aus der Fracht zum Aufschlag. Rückgabe: Grund oder leer.
static func caravan_buy(world: SimWorld, c: SimCharacter, trader: SimCharacter, rid: String) -> String:
	var reason := _caravan_reason(world, c, trader, rid)
	if not reason.is_empty():
		return reason
	var lot := int(world.data.balance["events"]["caravan"]["prices"][rid]["lot"])
	var ask := caravan_ask_price(world, rid)
	var currency := caravan_currency(world)
	if int(caravan_cargo(world, trader).get(rid, 0)) < lot:
		return "die Karawane hat davon nicht genug"
	if int(c.inventory.get(currency, 0)) < ask:
		return "zu wenig %s (%d nötig)" % [world.data.resources[currency]["name"], ask]
	if c.inventory_count() - ask + lot > world.data.bali("inventory.capacity"):
		return "Inventar voll"
	var left := lot
	for member_id: int in world.caravans[trader.caravan_id]["members"]:
		var member := world.get_character(member_id)
		if member == null or member.dead or member.caravan_role != "animal" or left <= 0:
			continue
		var take := mini(left, int(member.inventory.get(rid, 0)))
		if take > 0:
			member.inventory[rid] = int(member.inventory[rid]) - take
			left -= take
	c.inventory[currency] = int(c.inventory[currency]) - ask
	c.inventory[rid] = int(c.inventory.get(rid, 0)) + lot
	trader.inventory[currency] = int(trader.inventory.get(currency, 0)) + ask
	world.events.append({"type": "caravan_trade", "id": c.id, "kind": "buy", "resource": rid, "amount": lot, "copper": ask})
	return ""
