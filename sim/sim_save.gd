class_name SimSave
extends RefCounted
## Serialisierung des kompletten Weltzustands nach/aus Dictionary (JSON-fähig).
## Grundlage für Spielstände und später für Snapshots im Netzwerk. Nach dem Laden simuliert
## die Welt identisch weiter (Test: gleicher Verlauf vor und nach Speichern/Laden).
## Das Dictionary ist JSON-fähig (Vektoren als [x, y]); die Datei wird aber binär (store_var) geschrieben,
## weil Godots Textformate floats runden und der Verlauf nach dem Laden sonst abweicht.
## Ganze Zahlen werden beim Laden trotzdem zurückgewandelt (Snapshots über JSON bleiben möglich),
## 64-Bit-Werte (RNG) stehen als Text.

const VERSION: int = 1

const CHARACTER_FLOATS: Array[String] = [
	"move_speed", "collision_radius", "hp", "max_hp", "armor", "death_time",
	"melee_damage", "melee_range", "melee_cooldown", "hunger", "fire_cooldown",
	"last_damage_time", "gather_progress", "heal_progress", "hide_progress", "revealed_until",
	"decision_timer", "leash_radius", "ai_timer", "bite_cooldown", "logout_time", "lod_accumulator",
]
const CHARACTER_INTS: Array[String] = [
	"id", "kind", "control", "last_attacker_id", "active_rule_index", "last_logged_rule_index", "marker_counter",
]
const CHARACTER_STRINGS: Array[String] = ["name", "owner_id", "role_id", "ai_state", "active_weapon"]
const CHARACTER_BOOLS: Array[String] = ["dead", "hidden", "transition_logged"]
const CHARACTER_VECTORS: Array[String] = ["pos", "prev_pos", "facing", "logout_pos", "leash_center", "ai_target_pos", "home_pos"]


# --- Welt -----------------------------------------------------------------

static func world_to_dict(world: SimWorld) -> Dictionary:
	var characters := []
	for c: SimCharacter in world.characters.values():
		characters.append(character_to_dict(c))
	var projectiles := []
	for p: SimProjectile in world.projectiles:
		projectiles.append({
			"owner_id": p.owner_id, "pos": v2(p.pos), "prev_pos": v2(p.prev_pos),
			"velocity": v2(p.velocity), "damage": p.damage, "lifetime": p.lifetime,
		})
	var nodes := []
	for node: SimResourceNode in world.map.nodes.values():
		nodes.append({"cell": v2i(node.cell), "amount": node.amount, "regrow_timer": node.regrow_timer})
	var buildings := []
	for b: SimBuilding in world.map.buildings.values():
		buildings.append({"id": b.id, "part": b.part, "owner": b.owner_id, "origin": v2i(b.origin), "rotation": b.rotation, "hp": b.hp, "max_hp": b.max_hp, "placed_time": b.placed_time, "contents": b.contents.duplicate(), "offers": b.offers.duplicate(true), "label": b.label, "triggered_until": b.triggered_until})
	return {
		"version": VERSION,
		"time": world.time,
		"tick_count": world.tick_count,
		"next_id": world._next_id,
		"wolf_respawn_timer": world._wolf_respawn_timer,
		"rng_seed": str(world.rng.seed),
		"rng_state": str(world.rng.state),
		"unlocks": world.unlocks_by_owner.duplicate(true),
		"characters": characters,
		"projectiles": projectiles,
		"nodes": nodes,
		"buildings": buildings,
		"next_building_id": world._next_building_id,
		"claims": world.claims.to_list(),
		"next_claim_id": world.claims.next_id(),
	}


## Baut eine Welt aus einem Dictionary. null bei falscher Version oder fehlenden Feldern.
static func world_from_dict(data: SimData, dict: Dictionary) -> SimWorld:
	if int(dict.get("version", -1)) != VERSION:
		push_warning("Spielstand hat Version %s, erwartet %d" % [dict.get("version"), VERSION])
		return null
	for key: String in ["time", "tick_count", "next_id", "characters", "nodes", "rng_seed", "rng_state"]:
		if not dict.has(key):
			push_warning("Spielstand: Feld fehlt: %s" % key)
			return null
	var world := SimWorld.new(data, 0)
	world.time = float(dict["time"])
	world.tick_count = int(dict["tick_count"])
	world._next_id = int(dict["next_id"])
	world._wolf_respawn_timer = float(dict.get("wolf_respawn_timer", 0.0))
	world.rng.seed = String(dict["rng_seed"]).to_int()
	world.rng.state = String(dict["rng_state"]).to_int()
	world.unlocks_by_owner = {}
	for owner: Variant in dict.get("unlocks", {}):
		world.unlocks_by_owner[String(owner)] = {}
		for fact: Variant in dict["unlocks"][owner]:
			world.unlocks_by_owner[String(owner)][String(fact)] = true
	for entry: Dictionary in dict["characters"]:
		var c := character_from_dict(data, entry)
		world.characters[c.id] = c
	for entry: Dictionary in dict.get("projectiles", []):
		var p := SimProjectile.new()
		p.owner_id = int(entry["owner_id"])
		p.pos = to_v2(entry["pos"])
		p.prev_pos = to_v2(entry.get("prev_pos", entry["pos"]))
		p.velocity = to_v2(entry["velocity"])
		p.damage = float(entry["damage"])
		p.lifetime = float(entry["lifetime"])
		world.projectiles.append(p)
	for entry: Dictionary in dict["nodes"]:
		var node := world.map.node_at(to_v2i(entry["cell"]))
		if node != null:
			node.amount = int(entry["amount"])
			node.regrow_timer = float(entry.get("regrow_timer", 0.0))
	world._next_building_id = int(dict.get("next_building_id", 1))
	for entry: Dictionary in dict.get("buildings", []):
		var part := String(entry["part"])
		if not data.buildings.has(part):
			continue
		var b := SimBuilding.new()
		b.id = int(entry["id"])
		b.part = part
		b.owner_id = String(entry["owner"])
		b.origin = to_v2i(entry["origin"])
		b.rotation = int(entry["rotation"])
		b.hp = float(entry["hp"])
		b.max_hp = float(entry.get("max_hp", data.buildings[part]["hp"]))
		b.placed_time = float(entry.get("placed_time", 0.0))
		b.label = String(entry.get("label", ""))
		b.triggered_until = float(entry.get("triggered_until", -1.0))
		b.cells = SimBuilding.cells_for(data.buildings[part]["size"], b.origin, b.rotation)
		for rid: Variant in entry.get("contents", {}):
			b.contents[String(rid)] = int(entry["contents"][rid])
		for offer: Dictionary in entry.get("offers", []):
			b.offers.append({"sell": String(offer["sell"]), "sell_amount": int(offer["sell_amount"]), "price": String(offer["price"]), "price_amount": int(offer["price_amount"])})
		world.map.add_building(b)
	world.claims.load_list(dict.get("claims", []), int(dict.get("next_claim_id", 1)))
	var owners := {}
	for c: SimCharacter in world.characters.values():
		owners[c.owner_id] = true
	for owner: String in owners:
		world.refresh_places(owner)
	return world


# --- Charakter ------------------------------------------------------------

static func character_to_dict(c: SimCharacter) -> Dictionary:
	var dict := {}
	for key: String in CHARACTER_FLOATS + CHARACTER_INTS + CHARACTER_STRINGS + CHARACTER_BOOLS:
		dict[key] = c.get(key)
	for key: String in CHARACTER_VECTORS:
		dict[key] = v2(c.get(key))
	dict["gather_target"] = v2i(c.gather_target)
	dict["inventory"] = c.inventory.duplicate()
	var skipped := []
	for index: int in c.skipped_rules:
		skipped.append({"index": index, "reason": c.skipped_rules[index]["reason"], "time": c.skipped_rules[index]["time"]})
	dict["skipped_rules"] = skipped
	dict["items"] = c.items.duplicate()
	dict["rules"] = c.rules.duplicate(true)
	var markers := []
	for marker: Dictionary in c.markers:
		markers.append({"id": marker["id"], "name": marker["name"], "pos": v2(marker["pos"])})
	dict["markers"] = markers
	var chronicle := []
	for entry: Dictionary in c.chronicle:
		var copy := entry.duplicate()
		if copy.has("pos"):
			copy["pos"] = v2(copy["pos"])
		chronicle.append(copy)
	dict["chronicle"] = chronicle
	return dict


static func character_from_dict(data: SimData, dict: Dictionary) -> SimCharacter:
	var c := SimCharacter.new()
	for key: String in CHARACTER_FLOATS:
		c.set(key, float(dict.get(key, c.get(key))))
	for key: String in CHARACTER_INTS:
		c.set(key, int(dict.get(key, c.get(key))))
	for key: String in CHARACTER_STRINGS:
		c.set(key, String(dict.get(key, c.get(key))))
	for key: String in CHARACTER_BOOLS:
		c.set(key, bool(dict.get(key, c.get(key))))
	for key: String in CHARACTER_VECTORS:
		c.set(key, to_v2(dict.get(key, [0, 0])))
	c.gather_target = to_v2i(dict.get("gather_target", [-1, -1]))
	c.skipped_rules = {}
	for entry: Variant in dict.get("skipped_rules", []):
		if entry is Dictionary:
			c.skipped_rules[int(entry["index"])] = {"reason": String(entry["reason"]), "time": float(entry["time"])}
	c.items = []
	for item_id: Variant in dict.get("items", []):
		c.items.append(String(item_id))
	c.inventory = {}
	for rid: Variant in dict.get("inventory", {}):
		c.inventory[String(rid)] = int(dict["inventory"][rid])
	c.rules = data.normalize_rule_list(dict.get("rules", []), "Spielstand Charakter %d" % c.id) if not dict.get("rules", []).is_empty() else []
	c.markers = []
	for marker: Dictionary in dict.get("markers", []):
		c.markers.append({"id": String(marker["id"]), "name": String(marker["name"]), "pos": to_v2(marker["pos"])})
	c.chronicle = []
	for entry: Dictionary in dict.get("chronicle", []):
		# Feste Schlüsselreihenfolge, damit Vergleiche vor/nach dem Laden identisch sind
		var restored := {"time": float(entry.get("time", 0.0)), "clock": String(entry.get("clock", "")), "text": String(entry.get("text", ""))}
		if entry.has("pos"):
			restored["pos"] = to_v2(entry["pos"])
		c.chronicle.append(restored)
	# Flüchtiger Zustand (Weg, Sammelziel-Referenz) wird nicht gespeichert; der Controller findet ihn neu.
	c.action_state = {}
	c.path.clear()
	return c


# --- Dateien --------------------------------------------------------------

static func save_to_file(world: SimWorld, path: String, extra: Dictionary = {}) -> Error:
	var dict := world_to_dict(world)
	dict["game"] = extra
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_var(dict)
	file.close()
	return OK


## Liest einen Spielstand. Ergebnis: {"world": SimWorld, "game": Dictionary} oder leer bei Fehler.
static func load_from_file(data: SimData, path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = file.get_var()
	file.close()
	if not (parsed is Dictionary):
		push_warning("Spielstand unlesbar: %s" % path)
		return {}
	var world := world_from_dict(data, parsed)
	if world == null:
		return {}
	return {"world": world, "game": parsed.get("game", {})}


# --- Hilfen ---------------------------------------------------------------

static func v2(v: Vector2) -> Array:
	return [v.x, v.y]


static func to_v2(a: Variant) -> Vector2:
	if a is Array and a.size() == 2:
		return Vector2(float(a[0]), float(a[1]))
	return Vector2.ZERO


static func v2i(v: Vector2i) -> Array:
	return [v.x, v.y]


static func to_v2i(a: Variant) -> Vector2i:
	if a is Array and a.size() == 2:
		return Vector2i(int(a[0]), int(a[1]))
	return Vector2i(-1, -1)
