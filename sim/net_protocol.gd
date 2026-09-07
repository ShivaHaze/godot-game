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
const CONTROL_SHIFT: int = 2


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
		"s": intent.shoot, "i": intent.interact, "e": intent.eat,
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
static func character_intro(c: SimCharacter) -> Dictionary:
	return {"i": c.id, "n": c.name, "k": c.kind, "o": c.owner_id, "mh": c.max_hp}


## Bewegliche Daten eines Charakters, kompakt.
static func character_dynamic(c: SimCharacter) -> Array:
	var flags := (FLAG_DEAD if c.dead else 0) | (FLAG_HIDDEN if c.hidden else 0) | (int(c.control) << CONTROL_SHIFT)
	return [c.id, PackedFloat32Array([c.pos.x, c.pos.y, c.facing.x, c.facing.y, c.hp, c.gather_progress]), flags]


## Snapshot für einen Empfänger. `known` (id -> true) sind die Charaktere, die der Empfänger schon kennt;
## `node_state` (Vector2i -> Vorrat) ist sein letzter Stand der Quellen. Beides wird hier fortgeschrieben,
## Quellen gehen nur als Änderung mit.
static func snapshot(world: SimWorld, viewer_id: int, known: Dictionary, node_state: Dictionary) -> Dictionary:
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
		now_known[c.id] = true
		if not known.has(c.id):
			intros.append(character_intro(c))
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
		"inv": viewer.inventory.duplicate(), "items": viewer.items.duplicate(),
		"weapon": viewer.active_weapon, "rules": viewer.rules.duplicate(true),
		"role": viewer.role_id, "markers": markers, "chronicle": chronicle,
		"logout_time": viewer.logout_time, "last_damage_time": viewer.last_damage_time,
		"logout_pos": [viewer.logout_pos.x, viewer.logout_pos.y],
		"leash": [viewer.leash_center.x, viewer.leash_center.y, viewer.leash_radius],
		"chronicle_total": viewer.chronicle.size(),
	}


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
		c.name = String(intro["n"])
		c.kind = int(intro["k"]) as SimCharacter.Kind
		c.owner_id = String(intro["o"])
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
		c.dead = (flags & FLAG_DEAD) != 0
		c.hidden = (flags & FLAG_HIDDEN) != 0
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
