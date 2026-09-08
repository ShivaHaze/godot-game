class_name NetProtocol
extends RefCounted
## Nachrichtenformat des Netzwerk-Spikes: Dictionaries, binär per var_to_bytes.
## Kanal 0 zuverlässig (Beitritt, Ausloggen, Werkbank, eigene Details), Kanal 1 unzuverlässig-sequenziert
## (Absichten, Snapshots). Snapshots enthalten nur die Umgebung des Empfängers (Area of Interest):
## pro Charakter eine kompakte Zeile [id, PackedFloat32Array(px, py, fx, fy, hp, sammeln), flags];
## Stammdaten (Name, Art, Besitzer) gehen nur, wenn der Empfänger den Charakter noch nicht kennt.
## Die eigenen Details (Regeln, Chronik, Marker, Ausrüstung) gehen zuverlässig und nur bei Änderung.
## Regeln anderer Charaktere werden nie gesendet (Design: Regelwerk anderer ist verborgen).

const CHANNEL_RELIABLE: int = 0
const CHANNEL_FAST: int = 1
const CHANNELS: int = 2
const AOI_RADIUS: float = 22.0          # Kacheln um den eigenen Charakter
const CHRONICLE_TAIL: int = 40          # Zeilen der eigenen Chronik
const SNAPSHOT_EVERY_TICKS: int = 2     # 20 Hz Sim -> 10 Hz Snapshots

const FLAG_DEAD: int = 1
const FLAG_HIDDEN: int = 2
const FLAG_BLEEDING: int = 4
const FLAG_POISONED: int = 8
const FLAG_SICK: int = 16
const CONTROL_SHIFT: int = 5


static func encode(msg: Dictionary) -> PackedByteArray:
	return var_to_bytes(msg)


static func decode(bytes: PackedByteArray) -> Dictionary:
	var value: Variant = bytes_to_var(bytes)
	return value if value is Dictionary else {}


# --- Client -> Server -----------------------------------------------------

static func intent_to_msg(intent: SimIntent) -> Dictionary:
	return {
		"t": "intent",
		"m": [intent.move.x, intent.move.y],
		"a": [intent.aim.x, intent.aim.y],
		"s": intent.shoot, "i": intent.interact, "e": intent.eat, "h": intent.heal,
	}


## Absicht aus einer Nachricht, gegen Unsinn abgesichert (Länge, NaN).
static func msg_to_intent(msg: Dictionary) -> SimIntent:
	var intent := SimIntent.new()
	intent.move = _safe_vector(msg.get("m"))
	if intent.move.length_squared() > 1.0:
		intent.move = intent.move.normalized()
	intent.aim = _safe_vector(msg.get("a"))
	intent.shoot = bool(msg.get("s", false))
	intent.interact = bool(msg.get("i", false))
	intent.eat = bool(msg.get("e", false))
	intent.heal = bool(msg.get("h", false))
	return intent


static func _safe_vector(value: Variant) -> Vector2:
	if not (value is Array) or value.size() != 2:
		return Vector2.ZERO
	var x := float(value[0])
	var y := float(value[1])
	if is_nan(x) or is_nan(y) or is_inf(x) or is_inf(y):
		return Vector2.ZERO
	return Vector2(clampf(x, -1000.0, 1000.0), clampf(y, -1000.0, 1000.0))


# --- Server -> Client -----------------------------------------------------

## Stammdaten eines Charakters (einmal je Empfänger, solange er in Sicht bleibt).
static func character_intro(c: SimCharacter, named: bool = true, guild: String = "") -> Dictionary:
	return {"i": c.id, "n": c.name if named else "", "k": c.kind, "o": c.owner_id, "mh": c.max_hp, "g": guild, "b": c.boss, "cr": c.caravan_role, "ci": c.caravan_id}


## Bewegliche Daten eines Charakters, kompakt.
static func character_dynamic(c: SimCharacter) -> Array:
	var flags := (FLAG_DEAD if c.dead else 0) | (FLAG_HIDDEN if c.hidden else 0) | (FLAG_BLEEDING if c.effects.has("bleeding") else 0) | (FLAG_POISONED if c.effects.has("poison") else 0) | (FLAG_SICK if c.effects.has("sick") else 0) | (int(c.control) << CONTROL_SHIFT)
	return [c.id, PackedFloat32Array([c.pos.x, c.pos.y, c.facing.x, c.facing.y, c.hp, c.gather_progress, c.heal_progress]), flags]


## Snapshot für einen Empfänger. `known` (id -> true) sind die Charaktere, die der Empfänger schon kennt;
## `node_state` (Vector2i -> Vorrat) ist sein letzter Stand der Quellen. Beides wird hier fortgeschrieben,
## Quellen gehen nur als Änderung mit.
static func snapshot(world: SimWorld, viewer_id: int, known: Dictionary, node_state: Dictionary, building_state: Dictionary = {}, claim_state: Dictionary = {}) -> Dictionary:
	var viewer := world.get_character(viewer_id)
	if viewer == null:
		return {}
	var center := viewer.pos
	var r2 := AOI_RADIUS * AOI_RADIUS
	var chars := []
	var intros := []
	var now_known := {}
	for c: SimCharacter in world.characters.values():
		if c.pos.distance_squared_to(center) > r2 and c.id != viewer_id:
			continue
		chars.append(character_dynamic(c))
		# known[id]: true = Stammdaten mit Name geschickt, false = ohne Name (noch zu weit weg)
		var named := world.knows_name(viewer, c)
		var state: Variant = known.get(c.id)
		if state == null or (state == false and named):
			intros.append(character_intro(c, named, world.guilds.name_of(c.owner_id)))
		now_known[c.id] = named or state == true
	known.clear()
	known.merge(now_known)
	var projectiles := PackedFloat32Array()
	for p: SimProjectile in world.projectiles:
		if p.pos.distance_squared_to(center) <= r2:
			projectiles.append_array(PackedFloat32Array([p.pos.x, p.pos.y, p.velocity.x, p.velocity.y]))
	var nodes := PackedInt32Array()
	for node: SimResourceNode in world.map.nodes.values():
		if node.center().distance_squared_to(center) <= r2 and int(node_state.get(node.cell, -1)) != node.amount:
			node_state[node.cell] = node.amount
			nodes.append_array(PackedInt32Array([node.cell.x, node.cell.y, node.amount]))
	var snap := {
		"t": "snap",
		"time": world.time,
		"you": viewer_id,
		"chars": chars,
		"proj": projectiles,
		"me": PackedFloat32Array([viewer.hunger, viewer.armor]),
	}
	if not nodes.is_empty():
		snap["nodes"] = nodes
	if not intros.is_empty():
		snap["intro"] = intros
	# Bauteile: neu/verändert im Sichtbereich, plus entfernte, die der Empfänger kannte
	var built := []
	for b: SimBuilding in world.map.buildings.values():
		if b.center().distance_squared_to(center) > r2 or not SimDefense.building_visible_to(world, b, viewer.owner_id):
			continue
		var triggered := world.time < b.triggered_until
		# Depot: nur der eigene Bestand geht raus (als contents); fremde Bestände bleiben geheim
		var shown: Dictionary = SimTrade.depot_stock(world, b, viewer.owner_id) if SimTrade.is_depot(world, b) else b.contents
		var signature := [b.hp, shown, b.offers, b.label, triggered].hash()
		if building_state.has(b.id) and int(building_state[b.id]) == signature:
			continue
		building_state[b.id] = signature
		built.append([b.id, b.part, b.owner_id, b.origin.x, b.origin.y, b.rotation, b.hp, b.max_hp, shown.duplicate(), b.offers.duplicate(true), b.label, triggered])
	var removed := PackedInt32Array()
	for id: int in building_state.keys():
		if not world.map.buildings.has(id):
			removed.append(id)
			building_state.erase(id)
	if not built.is_empty():
		snap["bld"] = built
	if not removed.is_empty():
		snap["bld_rm"] = removed
	# Claims: ganze Claims, wenn sich etwas geändert hat (Kacheln, Anker, Vorrat grob)
	var claim_rows := []
	for claim: SimClaim in world.claims.claims.values():
		var tiles := PackedInt32Array()
		for tile: Vector2i in claim.tiles:
			tiles.append_array(PackedInt32Array([tile.x, tile.y]))
		var signature := [claim.owner_id, claim.anchor_building_id, tiles.size(), int(claim.stock), claim.anchor_tile.x, claim.anchor_tile.y].hash()
		if int(claim_state.get(claim.id, 0)) == signature:
			continue
		claim_state[claim.id] = signature
		claim_rows.append([claim.id, claim.owner_id, claim.anchor_building_id, claim.anchor_tile.x, claim.anchor_tile.y, tiles, claim.stock, world.claims.hours_left(world.data, claim)])
	var claims_removed := PackedInt32Array()
	for id: int in claim_state.keys():
		if not world.claims.claims.has(id):
			claims_removed.append(id)
			claim_state.erase(id)
	if not claim_rows.is_empty():
		snap["clm"] = claim_rows
	if not claims_removed.is_empty():
		snap["clm_rm"] = claims_removed
	# Karawanen in Sicht: Rast, Kasse und Fracht für die Handelstafel
	var caravan_rows := []
	for caravan: Dictionary in world.caravans.values():
		var leader := world.get_character(int(caravan["leader"]))
		if leader == null or leader.dead or leader.pos.distance_squared_to(center) > r2:
			continue
		caravan_rows.append([int(caravan["id"]), leader.id, String(caravan["leg"]), SimTrade.caravan_copper(world, leader), SimTrade.caravan_cargo(world, leader)])
	if not caravan_rows.is_empty():
		snap["cv"] = caravan_rows
	return snap


## Eigene Details, die sich selten ändern (zuverlässig, nur bei Änderung senden).
static func self_block(viewer: SimCharacter) -> Dictionary:
	var chronicle := []
	var start := maxi(0, viewer.chronicle.size() - CHRONICLE_TAIL)
	for i in range(start, viewer.chronicle.size()):
		var entry: Dictionary = viewer.chronicle[i]
		var pos: Vector2 = entry.get("pos", Vector2.ZERO)
		chronicle.append([entry["clock"], entry["text"], pos.x, pos.y])
	var markers := []
	for marker: Dictionary in viewer.markers:
		markers.append({"id": marker["id"], "name": marker["name"], "pos": [marker["pos"].x, marker["pos"].y]})
	return {
		"inv": viewer.inventory.duplicate(), "items": viewer.items.duplicate(), "dur": viewer.durability.duplicate(true),
		"weapon": viewer.active_weapon, "armor": viewer.worn_armor, "rules": viewer.rules.duplicate(true),
		"role": viewer.role_id, "markers": markers, "chronicle": chronicle,
		"logout_time": viewer.logout_time, "last_damage_time": viewer.last_damage_time,
		"logout_pos": [viewer.logout_pos.x, viewer.logout_pos.y],
		"leash": [viewer.leash_center.x, viewer.leash_center.y, viewer.leash_radius],
		"chronicle_total": viewer.chronicle.size(),
		"reqs": {},
		"places": viewer.extra_places.duplicate(true),
		"guild": _guild_block(viewer),
	}


static func _guild_block(viewer: SimCharacter) -> Dictionary:
	return {}  # wird vom Server gefüllt (self_block_for)


## Selbstblock mit Gildendaten (der Server kennt die Welt).
static func self_block_for(world: SimWorld, viewer: SimCharacter) -> Dictionary:
	var block := self_block(viewer)
	var id := world.guilds.guild_of(viewer.owner_id)
	if id >= 0:
		var g: Dictionary = world.guilds.guilds[id]
		block["guild"] = {"name": g["name"], "leader": g["leader"], "members": Array(g["members"]).duplicate(), "xp": int(g.get("xp", 0)), "level": world.guild_level(viewer.owner_id)}
	var invite_id := int(world.guilds.invites.get(viewer.owner_id, -1))
	if invite_id >= 0 and world.guilds.guilds.has(invite_id):
		block["invite"] = String(world.guilds.guilds[invite_id]["name"])
	return block


## Spielt einen Snapshot in eine Spiegelwelt ein (Client). Charaktere außer Sicht verschwinden.
static func apply_snapshot(mirror: SimWorld, snap: Dictionary) -> void:
	mirror.time = float(snap.get("time", mirror.time))
	for intro: Dictionary in snap.get("intro", []):
		var id := int(intro["i"])
		var c := mirror.get_character(id)
		if c == null:
			c = SimCharacter.new()
			c.id = id
			mirror.characters[id] = c
		var name := String(intro["n"])
		if not name.is_empty() or c.name.is_empty() or c.name == "?":
			c.name = name  # leer = Name noch unbekannt (zu weit weg); ein bekannter Name bleibt
		c.kind = int(intro["k"]) as SimCharacter.Kind
		c.boss = bool(intro.get("b", false))
		c.caravan_role = String(intro.get("cr", ""))
		c.caravan_id = int(intro.get("ci", -1))
		c.owner_id = String(intro["o"])
		mirror.guilds.register(c.owner_id, String(intro.get("g", "")))
		c.max_hp = float(intro["mh"])
	var seen := {}
	for row: Array in snap.get("chars", []):
		var id := int(row[0])
		var values: PackedFloat32Array = row[1]
		var flags := int(row[2])
		seen[id] = true
		var c := mirror.get_character(id)
		var pos := Vector2(values[0], values[1])
		if c == null:
			c = SimCharacter.new()  # Stammdaten fehlen noch (Paketverlust); kommen mit dem nächsten Snapshot
			c.id = id
			c.name = "?"
			c.prev_pos = pos
			mirror.characters[id] = c
		elif c.prev_pos == Vector2.ZERO and c.pos == Vector2.ZERO:
			c.prev_pos = pos
		else:
			c.prev_pos = c.pos
		c.pos = pos
		c.facing = Vector2(values[2], values[3])
		c.hp = values[4]
		c.gather_progress = values[5]
		c.heal_progress = values[6] if values.size() > 6 else 0.0
		c.dead = (flags & FLAG_DEAD) != 0
		c.hidden = (flags & FLAG_HIDDEN) != 0
		if (flags & FLAG_BLEEDING) != 0:
			c.effects["bleeding"] = 1e18  # Dauer kennt der Client nicht; Anzeige bis der Server sie beendet
		else:
			c.effects.erase("bleeding")
		if (flags & FLAG_POISONED) != 0:
			c.effects["poison"] = 1e18
		else:
			c.effects.erase("poison")
		if (flags & FLAG_SICK) != 0:
			c.effects["sick"] = 1e18
		else:
			c.effects.erase("sick")
		c.control = (flags >> CONTROL_SHIFT) as SimCharacter.Controller
	for id: int in mirror.characters.keys():
		if not seen.has(id):
			mirror.characters.erase(id)
	mirror.projectiles.clear()
	var proj: PackedFloat32Array = snap.get("proj", PackedFloat32Array())
	for i in range(0, proj.size() - 3, 4):
		var p := SimProjectile.new()
		p.pos = Vector2(proj[i], proj[i + 1])
		p.velocity = Vector2(proj[i + 2], proj[i + 3])
		p.prev_pos = p.pos - p.velocity * mirror.tick_dt * SNAPSHOT_EVERY_TICKS
		mirror.projectiles.append(p)
	var nodes: PackedInt32Array = snap.get("nodes", PackedInt32Array())
	for i in range(0, nodes.size() - 2, 3):
		var node := mirror.map.node_at(Vector2i(nodes[i], nodes[i + 1]))
		if node != null:
			node.amount = nodes[i + 2]
	for row: Array in snap.get("bld", []):
		var id := int(row[0])
		var part := String(row[1])
		if not mirror.data.buildings.has(part):
			continue
		var b: SimBuilding = mirror.map.buildings.get(id)
		if b == null:
			b = SimBuilding.new()
			b.id = id
			b.part = part
			b.owner_id = String(row[2])
			b.origin = Vector2i(int(row[3]), int(row[4]))
			b.rotation = int(row[5])
			b.cells = SimBuilding.cells_for(mirror.data.buildings[part]["size"], b.origin, b.rotation)
			mirror.map.add_building(b)
		b.hp = float(row[6])
		b.max_hp = float(row[7])
		if row.size() > 9:
			b.contents = {}
			for rid: Variant in row[8]:
				b.contents[String(rid)] = int(row[8][rid])
			b.offers = []
			for offer: Dictionary in row[9]:
				b.offers.append({"sell": String(offer["sell"]), "sell_amount": int(offer["sell_amount"]), "price": String(offer["price"]), "price_amount": int(offer["price_amount"])})
		if row.size() > 11:
			b.label = String(row[10])
			b.triggered_until = mirror.time + 1.0 if bool(row[11]) else -1.0
	for id: int in snap.get("bld_rm", PackedInt32Array()):
		mirror.map.remove_building(id)
	for row: Array in snap.get("clm", []):
		var claim: SimClaim = mirror.claims.claims.get(int(row[0]))
		if claim == null:
			claim = SimClaim.new()
			claim.id = int(row[0])
			mirror.claims.claims[claim.id] = claim
		for tile: Vector2i in claim.tiles.keys():
			mirror.claims.tile_owner.erase(tile)
		claim.owner_id = String(row[1])
		claim.anchor_building_id = int(row[2])
		claim.anchor_tile = Vector2i(int(row[3]), int(row[4]))
		claim.tiles = {}
		var tiles: PackedInt32Array = row[5]
		for i in range(0, tiles.size() - 1, 2):
			var tile := Vector2i(tiles[i], tiles[i + 1])
			claim.tiles[tile] = true
			mirror.claims.tile_owner[tile] = claim.id
		claim.stock = float(row[6])
		claim.hours_left_hint = float(row[7])
	for id: int in snap.get("clm_rm", PackedInt32Array()):
		var claim: SimClaim = mirror.claims.claims.get(id)
		if claim != null:
			for tile: Vector2i in claim.tiles.keys():
				mirror.claims.tile_owner.erase(tile)
			mirror.claims.claims.erase(id)
	mirror.caravans = {}
	for row: Array in snap.get("cv", []):
		mirror.caravans[int(row[0])] = {"id": int(row[0]), "leader": int(row[1]), "leg": String(row[2]), "copper": int(row[3]), "cargo": row[4], "members": []}
	var you := mirror.get_character(int(snap.get("you", -1)))
	var me: PackedFloat32Array = snap.get("me", PackedFloat32Array())
	if you != null and me.size() >= 2:
		you.hunger = me[0]
		you.armor = me[1]


## Eigene Details in die Spiegelwelt übernehmen.
static func apply_self(mirror: SimWorld, you_id: int, block: Dictionary) -> void:
	var you := mirror.get_character(you_id)
	if you == null:
		you = SimCharacter.new()
		you.id = you_id
		mirror.characters[you_id] = you
	you.inventory = {}
	for rid: Variant in block.get("inv", {}):
		you.inventory[String(rid)] = int(block["inv"][rid])
	you.items = []
	for item_id: Variant in block.get("items", []):
		you.items.append(String(item_id))
	you.active_weapon = String(block.get("weapon", ""))
	you.worn_armor = String(block.get("armor", ""))
	you.durability = {}
	for item_id: Variant in block.get("dur", {}):
		var entry: Dictionary = block["dur"][item_id]
		you.durability[String(item_id)] = {"left": float(entry["left"]), "max": float(entry["max"])}
	you.rules = block.get("rules", [])
	you.role_id = String(block.get("role", ""))
	you.markers = []
	for marker: Dictionary in block.get("markers", []):
		you.markers.append({"id": String(marker["id"]), "name": String(marker["name"]), "pos": Vector2(marker["pos"][0], marker["pos"][1])})
	you.chronicle = []
	for entry: Array in block.get("chronicle", []):
		you.chronicle.append({"time": 0.0, "clock": String(entry[0]), "text": String(entry[1]), "pos": Vector2(entry[2], entry[3])})
	you.logout_time = float(block.get("logout_time", -1e9))
	you.last_damage_time = float(block.get("last_damage_time", -1e9))
	var lp: Array = block.get("logout_pos", [0, 0])
	you.logout_pos = Vector2(lp[0], lp[1])
	var leash: Array = block.get("leash", [0, 0, 0])
	you.leash_center = Vector2(leash[0], leash[1])
	you.leash_radius = float(leash[2])
	mirror.guild_invite_name = String(block.get("invite", ""))
	var guild: Dictionary = block.get("guild", {})
	if guild.is_empty():
		mirror.guilds.register(you.owner_id, "")
	else:
		for member: Variant in guild.get("members", []):
			mirror.guilds.register(String(member), String(guild["name"]))
		var gid := mirror.guilds.guild_of(you.owner_id)
		if gid >= 0:
			mirror.guilds.guilds[gid]["leader"] = String(guild.get("leader", you.owner_id))
			mirror.guilds.guilds[gid]["xp"] = int(guild.get("xp", 0))
	you.extra_places = {}
	for pid: Variant in block.get("places", {}):
		var place: Dictionary = block["places"][pid]
		var pos: Variant = place.get("pos", Vector2.ZERO)
		you.extra_places[String(pid)] = {"name": String(place.get("name", pid)), "pos": pos if pos is Vector2 else Vector2(pos[0], pos[1])}
	var reqs := {}
	for fact: Variant in block.get("reqs", {}):
		reqs[String(fact)] = bool(block["reqs"][fact])
	mirror.prereqs_override[you.owner_id] = reqs  # Voraussetzungen der Bausteine kennt der Server
