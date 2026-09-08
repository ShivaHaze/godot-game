class_name SimData
extends RefCounted
## Lädt und validiert alle Datendateien aus data/ (JSON). Reine Daten, keine Nodes.
## Fehler landen in `errors`; leer = gültig. Zahlen aus JSON sind immer float,
## Aufrufer holen sie über bali()/balf().

const FILE_NAMES: Dictionary = {
	"balance": "balance.json",
	"resources": "resources.json",
	"tiles": "tiles.json",
	"map": "map.json",
	"conditions": "conditions.json",
	"actions": "actions.json",
	"roles": "roles.json",
	"items": "items.json",
	"buildings": "buildings.json",
}

const ALLOWED_OPS: Array[String] = ["<", "<=", ">", ">=", "==", "!=", "has"]
const PARAM_TYPES: Array[String] = ["int", "float", "choice", "place", "resource", "radius", "sensor", "product"]
const PLACE_HERE: String = "here"

## Pflichtschlüssel in balance.json als Punktpfade. Tippfehler fallen so beim Laden auf.
const REQUIRED_BALANCE: Array[String] = [
	"tick_rate", "clock_start_hour", "time_skip_hours",
	"character.max_hp", "character.armor", "character.move_speed",
	"character.weakened_speed_multiplier", "character.collision_radius", "character.interact_range",
	"hunger.max", "hunger.start", "hunger.hungry_threshold",
	"hunger.decay_per_second_live", "hunger.decay_per_second_offline",
	"inventory.capacity",
	"gathering.gather_time", "gathering.node_regrow_time",
	"combat.front_arc_degrees", "combat.back_arc_degrees",
	"combat.side_damage_multiplier", "combat.back_damage_multiplier", "combat.back_armor_ignore",
	"combat.min_damage", "combat.under_attack_window",
	"wolf.max_hp", "wolf.armor", "wolf.move_speed", "wolf.bite_damage", "wolf.bite_range",
	"wolf.bite_cooldown", "wolf.aggro_radius", "wolf.flee_hp_percent", "wolf.flee_duration",
	"wolf.wander_radius", "wolf.respawn_time", "wolf.max_alive", "wolf.give_up_radius", "wolf.regen_per_second",
	"logout.transition_seconds", "logout.combat_window",
	"npc.default_leash_radius", "npc.preferred_combat_range", "npc.hide_delay",
	"npc.reveal_radius", "npc.reveal_duration", "npc.decision_interval", "npc.skip_relog_minutes",
	"offline.coarse_tick_dt", "offline.hot_radius", "offline.lod_radius",
	"building.reach", "building.refund_fraction", "building.melee_damage_multiplier", "building.table_capacity", "building.table_max_offers", "building.sign_max_length", "building.sign_read_distance",
	"effects.bleeding.duration", "effects.bleeding.damage_per_second", "effects.poison.duration", "effects.poison.damage_per_second", "effects.sick.duration", "effects.sick.chance_per_hour", "letters.max_length",
	"wear.repair_cost_fraction", "wear.repair_max_loss",
	"market.depot_capacity", "zones.market.depot_fee", "zones.outpost.depot_fee", "combat.name_range", "combat.corpse_rot_hours", "claim.guild_tiles_per_member", "guild.xp_per_rule", "guild.xp_per_level", "guild.max_level",
	"claim.max_tiles_solo", "claim.tile_cost_wood", "claim.upkeep_base", "claim.upkeep_growth", "claim.stock_capacity",
	"claim.shrink_interval_hours", "claim.grace_hours", "claim.min_anchor_distance", "claim.foreign_decay_multiplier",
	"toll.grace_seconds", "toll.pass_hours", "toll.forget_hours",
	"events.boss.interval_hours", "events.boss.first_after_hours", "events.boss.lifetime_hours", "events.boss.max_hp", "events.boss.bite_damage",
]

var balance: Dictionary = {}
var resources: Dictionary = {}          # id -> Definition
var resource_order: Array[String] = []
var tiles: Dictionary = {}              # id -> Definition
var tile_by_char: Dictionary = {}       # Zeichen -> Kachel-id
var map_width: int = 0
var map_height: int = 0
var map_rows: PackedStringArray = []
var map_tile_ids: Array[String] = []    # width*height, zeilenweise; Spawn-Zeichen werden zu "floor"
var player_spawns: Array[Vector2i] = []
var wolf_spawns: Array[Vector2i] = []
var depot_spawns: Array[Vector2i] = []   # Markt-Depots (Zeichen D), liegen auf Marktboden
var conditions: Dictionary = {}         # id -> Definition
var condition_order: Array[String] = []
var else_condition_id: String = ""
var actions: Dictionary = {}            # id -> Definition
var action_order: Array[String] = []
var roles: Dictionary = {}              # id -> Definition (rules bereits normalisiert)
var role_order: Array[String] = []
var default_rules: Array = []
var items: Dictionary = {}              # id -> Definition (Waffen, Rüstung)
var item_order: Array[String] = []
var buildings: Dictionary = {}          # id -> Bauteil-Definition
var building_order: Array[String] = []
var errors: PackedStringArray = []


static func load_from_dir(dir: String) -> SimData:
	var data := SimData.new()
	var raw := {}
	for key: String in FILE_NAMES:
		var path: String = dir.path_join(FILE_NAMES[key])
		if not FileAccess.file_exists(path):
			data.errors.append("Datei fehlt: %s" % path)
			continue
		var json := JSON.new()
		var err := json.parse(FileAccess.get_file_as_string(path))
		if err != OK:
			data.errors.append("Ungültiges JSON in %s, Zeile %d: %s" % [path, json.get_error_line(), json.get_error_message()])
			continue
		if not (json.data is Dictionary):
			data.errors.append("Oberste Ebene muss ein Objekt sein: %s" % path)
			continue
		raw[key] = json.data
	if data.errors.is_empty():
		data._parse_all(raw)
	return data


## Für Tests: Abschnitte direkt als Dictionaries übergeben (Schlüssel wie FILE_NAMES).
static func from_dicts(raw: Dictionary) -> SimData:
	var data := SimData.new()
	for key: String in FILE_NAMES:
		if not raw.has(key) or not (raw[key] is Dictionary):
			data.errors.append("Abschnitt fehlt oder ist kein Objekt: %s" % key)
	if data.errors.is_empty():
		data._parse_all(raw)
	return data


func is_valid() -> bool:
	return errors.is_empty()


## Balancing-Wert per Punktpfad, z. B. "hunger.hungry_threshold". Fehlt er, gibt es einen Fehler und null.
func bal(path: String) -> Variant:
	var value: Variant = _lookup(balance, path)
	if value == null:
		push_error("balance.json: Schlüssel fehlt: %s" % path)
	return value


func balf(path: String) -> float:
	var value: Variant = bal(path)
	return float(value) if value != null else 0.0


func bali(path: String) -> int:
	var value: Variant = bal(path)
	return int(value) if value != null else 0


## Tauscht die Karte gegen ein map.json-Dictionary (generierte Karte, Karte vom Server). Rückgabe: Fehlerliste (leer = ok).
func apply_map(raw: Dictionary) -> PackedStringArray:
	var previous_errors := errors.size()
	map_width = 0
	map_height = 0
	map_rows = PackedStringArray()
	map_tile_ids = []
	player_spawns = []
	wolf_spawns = []
	depot_spawns = []
	_parse_map(raw)
	var problems := errors.slice(previous_errors)
	errors.resize(previous_errors)
	return problems


## Roh-Dictionary der aktuellen Karte (für Übertragung und Speicherung).
func map_dict() -> Dictionary:
	return {"width": map_width, "height": map_height, "rows": Array(map_rows), "spawn_chars": {"P": "player", "W": "wolf", "D": "depot", "R": "depot_outpost"}}


func tile_id_at(x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= map_width or y >= map_height:
		return "obstacle"
	return map_tile_ids[y * map_width + x]


func tile_def_at(x: int, y: int) -> Dictionary:
	return tiles.get(tile_id_at(x, y), {})


func condition_def(id: String) -> Dictionary:
	return conditions.get(id, {})


## Freischalt-Bedingung eines Bausteins (Bedingung oder Aktion); leer = immer verfügbar.
func unlock_of(def: Dictionary) -> Dictionary:
	return def.get("unlock", {})


## Ist ein Baustein für einen Besitzer mit diesen Freischaltungen (fact -> true) nutzbar?
func is_unlocked(def: Dictionary, unlocks: Dictionary) -> bool:
	var unlock := unlock_of(def)
	return unlock.is_empty() or unlocks.has(unlock["fact"])


func action_def(id: String) -> Dictionary:
	return actions.get(id, {})


## Voreinstellung eines Parameters; 'radius' und 'resource' ohne default holen sie aus Balance/Ressourcen.
func param_default(param_def: Dictionary) -> Variant:
	if param_def.has("default"):
		return param_def["default"]
	match String(param_def.get("type", "")):
		"radius":
			return balf("npc.default_leash_radius")
		"place":
			return PLACE_HERE
		"sensor":
			return ""
		"resource":
			return resource_order[0] if not resource_order.is_empty() else ""
		"product":
			var products := craftable_resources()
			return products[0] if not products.is_empty() else ""
		"int", "float":
			return param_def.get("min", 0)
		"choice":
			var options: Array = param_def.get("options", [])
			return options[0]["value"] if not options.is_empty() else ""
	return null


## Prüft eine Regel und ergänzt fehlende Parameter mit Voreinstellungen. Fehler landen in `errors`.
func normalize_rule(rule: Variant, context: String) -> Dictionary:
	if not (rule is Dictionary):
		errors.append("%s: Regel ist kein Objekt" % context)
		return {}
	var result := {"if": {"condition": "", "params": {}}, "then": {"action": "", "params": {}}}
	var if_part: Variant = rule.get("if")
	var then_part: Variant = rule.get("then")
	if not (if_part is Dictionary) or not (then_part is Dictionary):
		errors.append("%s: Regel braucht 'if' und 'then'" % context)
		return {}
	var condition_id := String(if_part.get("condition", ""))
	if not conditions.has(condition_id):
		errors.append("%s: unbekannte Bedingung '%s'" % [context, condition_id])
		return {}
	var action_id := String(then_part.get("action", ""))
	if not actions.has(action_id):
		errors.append("%s: unbekannte Aktion '%s'" % [context, action_id])
		return {}
	result["if"]["condition"] = condition_id
	result["if"]["params"] = _normalize_params(conditions[condition_id]["params"], if_part.get("params", {}), context + " Bedingung")
	result["then"]["action"] = action_id
	result["then"]["params"] = _normalize_params(actions[action_id]["params"], then_part.get("params", {}), context + " Aktion")
	return result


## Prüft eine ganze Regelliste: letzte Zeile muss 'Sonst' sein, sonst nirgends.
func normalize_rule_list(rules: Variant, context: String) -> Array:
	var result: Array = []
	if not (rules is Array):
		errors.append("%s: Regelliste ist kein Array" % context)
		return result
	if rules.is_empty():
		errors.append("%s: Regelliste ist leer" % context)
		return result
	for i in rules.size():
		var normalized := normalize_rule(rules[i], "%s Regel %d" % [context, i + 1])
		if normalized.is_empty():
			continue
		var is_else: bool = normalized["if"]["condition"] == else_condition_id
		var is_last: bool = i == rules.size() - 1
		if is_last and not is_else:
			errors.append("%s: letzte Regel muss 'Sonst' sein" % context)
		if is_else and not is_last:
			errors.append("%s: 'Sonst' darf nur die letzte Regel sein (Regel %d)" % [context, i + 1])
		result.append(normalized)
	return result


## Ersetzt {name}-Platzhalter in Label/Chronik-Vorlagen durch Anzeigewerte.
func format_template(template: String, param_defs: Array, params: Dictionary, place_names: Dictionary = {}) -> String:
	var text := template
	for param_def: Dictionary in param_defs:
		var name := String(param_def["name"])
		var value: Variant = params.get(name, param_default(param_def))
		text = text.replace("{%s}" % name, display_value(param_def, value, place_names))
	return text


func display_value(param_def: Dictionary, value: Variant, place_names: Dictionary = {}) -> String:
	match String(param_def.get("type", "")):
		"place", "sensor":
			if value == PLACE_HERE:
				return "Hier"
			return String(place_names.get(value, value if not String(value).is_empty() else "(keiner)"))
		"resource", "product":
			return String(resources.get(value, {}).get("name", value))
		"choice":
			for option: Dictionary in param_def.get("options", []):
				if option["value"] == value:
					return String(option["label"])
			return String(value)
		"int":
			return str(int(value))
		"float", "radius":
			var f := float(value)
			return str(int(f)) if is_equal_approx(f, floorf(f)) else "%.1f" % f
	return str(value)


# --- Parsen ---------------------------------------------------------------

func _parse_all(raw: Dictionary) -> void:
	_parse_balance(raw["balance"])
	_parse_resources(raw["resources"])
	_parse_tiles(raw["tiles"])
	_parse_map(raw["map"])
	_parse_conditions(raw["conditions"])
	_parse_actions(raw["actions"])
	_parse_roles(raw["roles"])
	_parse_items(raw["items"])
	_parse_buildings(raw["buildings"])
	_check_stations()


## 'needs_building' in items.json/resources.json muss ein Bauteil mit 'station' (oder Lagerfeuer) nennen.
func _check_stations() -> void:
	for id: String in item_order:
		var needs := String(items[id].get("needs_building", ""))
		if not needs.is_empty() and not buildings.has(needs):
			errors.append("items.json: '%s' braucht unbekanntes Bauteil '%s'" % [id, needs])
	for id: String in resource_order:
		var needs := String(resources[id].get("needs_building", ""))
		if not needs.is_empty() and not buildings.has(needs):
			errors.append("resources.json: '%s' braucht unbekanntes Bauteil '%s'" % [id, needs])


## Station (Bauteil-Kennung), die ein Gegenstand oder Verbrauchsgut zum Herstellen braucht; leer = von Hand.
func station_of(item_id: String) -> String:
	if items.has(item_id):
		return String(items[item_id].get("needs_building", ""))
	return String(resources.get(item_id, {}).get("needs_building", ""))


func _parse_balance(raw: Dictionary) -> void:
	balance = raw
	for path: String in REQUIRED_BALANCE:
		var value: Variant = _lookup(balance, path)
		if value == null:
			errors.append("balance.json: Schlüssel fehlt: %s" % path)
		elif not _is_number(value):
			errors.append("balance.json: %s muss eine Zahl sein" % path)


func _parse_resources(raw: Dictionary) -> void:
	var list: Variant = raw.get("resources")
	if not (list is Array):
		errors.append("resources.json: 'resources' muss ein Array sein")
		return
	for entry: Variant in list:
		var context := "resources.json"
		if not _require_fields(entry, {"id": TYPE_STRING, "name": TYPE_STRING, "edible": TYPE_BOOL, "nutrition": TYPE_FLOAT, "color": TYPE_STRING}, context):
			continue
		var id := String(entry["id"])
		if resources.has(id):
			errors.append("%s: doppelte Kennung '%s'" % [context, id])
			continue
		if entry.has("cost") and not (entry["cost"] is Dictionary):
			errors.append("%s: 'cost' von '%s' muss ein Objekt sein" % [context, id])
			continue
		if entry.has("heal") and (not _is_number(entry["heal"]) or not _is_number(entry.get("heal_time"))):
			errors.append("%s: 'heal' braucht Zahlen heal und heal_time ('%s')" % [context, id])
			continue
		resources[id] = entry
		resource_order.append(id)
	if resources.is_empty():
		errors.append("resources.json: mindestens ein Rohstoff nötig")
	for id: String in resource_order:
		for rid: Variant in resources[id].get("cost", {}):
			if not resources.has(rid):
				errors.append("resources.json: '%s' braucht unbekannten Rohstoff '%s'" % [id, rid])


## Herstellbare Verbrauchsgüter (Rohstoffe mit 'cost'), in Reihenfolge.
func craftable_resources() -> Array[String]:
	var result: Array[String] = []
	for id: String in resource_order:
		if resources[id].has("cost"):
			result.append(id)
	return result


func _parse_tiles(raw: Dictionary) -> void:
	var list: Variant = raw.get("tiles")
	if not (list is Array):
		errors.append("tiles.json: 'tiles' muss ein Array sein")
		return
	for entry: Variant in list:
		var context := "tiles.json"
		if not _require_fields(entry, {"id": TYPE_STRING, "char": TYPE_STRING, "name": TYPE_STRING, "walkable": TYPE_BOOL, "color": TYPE_STRING}, context):
			continue
		var id := String(entry["id"])
		var ch := String(entry["char"])
		context = "tiles.json Kachel '%s'" % id
		if ch.length() != 1:
			errors.append("%s: 'char' muss genau ein Zeichen sein" % context)
			continue
		if tiles.has(id):
			errors.append("%s: doppelte Kennung" % context)
			continue
		if tile_by_char.has(ch):
			errors.append("%s: Zeichen '%s' schon vergeben" % [context, ch])
			continue
		if entry.has("resource"):
			if not resources.has(entry["resource"]):
				errors.append("%s: unbekannter Rohstoff '%s'" % [context, entry["resource"]])
			if not _is_number(entry.get("amount")) or float(entry.get("amount")) <= 0.0:
				errors.append("%s: 'amount' muss eine Zahl > 0 sein" % context)
		tiles[id] = entry
		tile_by_char[ch] = id
	if not tiles.has("floor") or not tiles.has("obstacle"):
		errors.append("tiles.json: Kacheln 'floor' und 'obstacle' sind Pflicht")


func _parse_map(raw: Dictionary) -> void:
	if not _require_fields(raw, {"width": TYPE_FLOAT, "height": TYPE_FLOAT, "rows": TYPE_ARRAY, "spawn_chars": TYPE_DICTIONARY}, "map.json"):
		return
	map_width = int(raw["width"])
	map_height = int(raw["height"])
	var rows: Array = raw["rows"]
	var spawn_chars: Dictionary = raw["spawn_chars"]
	if rows.size() != map_height:
		errors.append("map.json: %d Zeilen, aber height = %d" % [rows.size(), map_height])
		return
	map_rows = PackedStringArray()
	map_tile_ids = []
	for y in map_height:
		var row: Variant = rows[y]
		if not (row is String) or String(row).length() != map_width:
			errors.append("map.json: Zeile %d muss ein String mit %d Zeichen sein" % [y, map_width])
			return
		map_rows.append(row)
		for x in map_width:
			var ch := String(row)[x]
			if tile_by_char.has(ch):
				map_tile_ids.append(tile_by_char[ch])
			elif spawn_chars.has(ch):
				match String(spawn_chars[ch]):
					"player":
						map_tile_ids.append("floor")
						player_spawns.append(Vector2i(x, y))
					"wolf":
						map_tile_ids.append("floor")
						wolf_spawns.append(Vector2i(x, y))
					"depot":
						map_tile_ids.append("market" if tiles.has("market") else "floor")
						depot_spawns.append(Vector2i(x, y))
					"depot_outpost":
						map_tile_ids.append("outpost" if tiles.has("outpost") else "floor")
						depot_spawns.append(Vector2i(x, y))
					_:
						map_tile_ids.append("floor")
						errors.append("map.json: unbekannter Spawn-Typ '%s' für Zeichen '%s'" % [spawn_chars[ch], ch])
			else:
				errors.append("map.json: unbekanntes Zeichen '%s' bei x=%d y=%d" % [ch, x, y])
	if player_spawns.is_empty():
		errors.append("map.json: mindestens ein Spieler-Spawn (P) nötig")


func _parse_conditions(raw: Dictionary) -> void:
	var list: Variant = raw.get("conditions")
	if not (list is Array):
		errors.append("conditions.json: 'conditions' muss ein Array sein")
		return
	for entry: Variant in list:
		if not _require_fields(entry, {"id": TYPE_STRING, "label": TYPE_STRING, "params": TYPE_ARRAY, "check": TYPE_DICTIONARY}, "conditions.json"):
			continue
		var id := String(entry["id"])
		var context := "conditions.json Bedingung '%s'" % id
		if conditions.has(id):
			errors.append("%s: doppelte Kennung" % context)
			continue
		if not _validate_params(entry["params"], context):
			continue
		var check: Dictionary = entry["check"]
		if not (check.get("fact") is String) or String(check["fact"]).is_empty():
			errors.append("%s: check.fact fehlt" % context)
			continue
		if not ALLOWED_OPS.has(String(check.get("op", ""))):
			errors.append("%s: check.op muss einer von %s sein" % [context, ALLOWED_OPS])
			continue
		if check.has("param") == check.has("value"):
			errors.append("%s: check braucht genau eines von 'param' oder 'value'" % context)
			continue
		if check.has("param") and not _has_param(entry["params"], String(check["param"])):
			errors.append("%s: check.param '%s' ist nicht deklariert" % [context, check["param"]])
			continue
		if not entry.has("log"):
			entry["log"] = entry["label"]
		if entry.has("unlock") and not _require_fields(entry["unlock"], {"fact": TYPE_STRING, "label": TYPE_STRING}, context + " unlock"):
			continue
		if entry.get("is_else", false) == true:
			if not else_condition_id.is_empty():
				errors.append("%s: es darf nur eine 'Sonst'-Bedingung geben" % context)
				continue
			else_condition_id = id
		conditions[id] = entry
		condition_order.append(id)
	if else_condition_id.is_empty():
		errors.append("conditions.json: eine Bedingung mit is_else = true ('Sonst') ist Pflicht")


func _parse_actions(raw: Dictionary) -> void:
	var list: Variant = raw.get("actions")
	if not (list is Array):
		errors.append("actions.json: 'actions' muss ein Array sein")
		return
	for entry: Variant in list:
		if not _require_fields(entry, {"id": TYPE_STRING, "label": TYPE_STRING, "params": TYPE_ARRAY}, "actions.json"):
			continue
		var id := String(entry["id"])
		var context := "actions.json Aktion '%s'" % id
		if actions.has(id):
			errors.append("%s: doppelte Kennung" % context)
			continue
		if not _validate_params(entry["params"], context):
			continue
		if not entry.has("log"):
			entry["log"] = entry["label"]
		if entry.has("unlock") and not _require_fields(entry["unlock"], {"fact": TYPE_STRING, "label": TYPE_STRING}, context + " unlock"):
			continue
		actions[id] = entry
		action_order.append(id)
	if actions.is_empty():
		errors.append("actions.json: mindestens eine Aktion nötig")


func _parse_roles(raw: Dictionary) -> void:
	if not errors.is_empty():
		return  # Regeln brauchen gültige Bedingungen und Aktionen
	default_rules = normalize_rule_list(raw.get("default_rules"), "roles.json default_rules")
	var list: Variant = raw.get("roles")
	if not (list is Array):
		errors.append("roles.json: 'roles' muss ein Array sein")
		return
	for entry: Variant in list:
		if not _require_fields(entry, {"id": TYPE_STRING, "name": TYPE_STRING, "tip": TYPE_STRING, "rules": TYPE_ARRAY}, "roles.json"):
			continue
		var id := String(entry["id"])
		var context := "roles.json Rolle '%s'" % id
		if roles.has(id):
			errors.append("%s: doppelte Kennung" % context)
			continue
		entry["rules"] = normalize_rule_list(entry["rules"], context)
		roles[id] = entry
		role_order.append(id)
	if roles.is_empty():
		errors.append("roles.json: mindestens eine Rolle nötig")


func _parse_items(raw: Dictionary) -> void:
	var list: Variant = raw.get("items")
	if not (list is Array):
		errors.append("items.json: 'items' muss ein Array sein")
		return
	for entry: Variant in list:
		if not _require_fields(entry, {"id": TYPE_STRING, "name": TYPE_STRING, "kind": TYPE_STRING, "starting": TYPE_BOOL, "cost": TYPE_DICTIONARY, "durability": TYPE_FLOAT}, "items.json"):
			continue
		var id := String(entry["id"])
		var context := "items.json Gegenstand '%s'" % id
		if items.has(id):
			errors.append("%s: doppelte Kennung" % context)
			continue
		var ok := true
		match String(entry["kind"]):
			"weapon":
				match String(entry.get("attack", "")):
					"ranged":
						ok = _require_fields(entry, {"damage": TYPE_FLOAT, "projectile_speed": TYPE_FLOAT, "projectile_lifetime": TYPE_FLOAT, "cooldown": TYPE_FLOAT, "max_projectiles": TYPE_FLOAT}, context)
					"melee":
						ok = _require_fields(entry, {"damage": TYPE_FLOAT, "range": TYPE_FLOAT, "cooldown": TYPE_FLOAT}, context)
					_:
						errors.append("%s: 'attack' muss ranged oder melee sein" % context)
						ok = false
			"armor":
				ok = _require_fields(entry, {"armor": TYPE_FLOAT}, context)
			_:
				errors.append("%s: 'kind' muss weapon oder armor sein" % context)
				ok = false
		for rid: Variant in entry["cost"]:
			if not resources.has(rid):
				errors.append("%s: unbekannter Rohstoff '%s' in cost" % [context, rid])
				ok = false
			elif not _is_number(entry["cost"][rid]) or float(entry["cost"][rid]) <= 0.0:
				errors.append("%s: cost.%s muss eine Zahl > 0 sein" % [context, rid])
				ok = false
		if not ok:
			continue
		items[id] = entry
		item_order.append(id)


func _parse_buildings(raw: Dictionary) -> void:
	var list: Variant = raw.get("buildings")
	if not (list is Array):
		errors.append("buildings.json: 'buildings' muss ein Array sein")
		return
	for entry: Variant in list:
		if not _require_fields(entry, {"id": TYPE_STRING, "name": TYPE_STRING, "tier": TYPE_STRING, "cost": TYPE_DICTIONARY, "hp": TYPE_FLOAT, "size": TYPE_ARRAY, "passable": TYPE_STRING, "decay_per_hour": TYPE_FLOAT, "color": TYPE_STRING}, "buildings.json"):
			continue
		var id := String(entry["id"])
		var context := "buildings.json Bauteil '%s'" % id
		var ok := true
		if buildings.has(id):
			errors.append("%s: doppelte Kennung" % context)
			continue
		if not ["wood", "stone", "iron"].has(String(entry["tier"])):
			errors.append("%s: 'tier' muss wood, stone oder iron sein" % context)
			ok = false
		if not ["none", "owner", "all"].has(String(entry["passable"])):
			errors.append("%s: 'passable' muss none, owner oder all sein" % context)
			ok = false
		var size: Array = entry["size"]
		if size.size() != 2 or not _is_number(size[0]) or not _is_number(size[1]) or int(size[0]) < 1 or int(size[1]) < 1:
			errors.append("%s: 'size' muss [Breite, Höhe] in Halbzellen ≥ 1 sein" % context)
			ok = false
		for rid: Variant in entry["cost"]:
			if not resources.has(rid) or not _is_number(entry["cost"][rid]) or float(entry["cost"][rid]) <= 0.0:
				errors.append("%s: cost.%s ungültig" % [context, rid])
				ok = false
		if not ok:
			continue
		buildings[id] = entry
		building_order.append(id)


# --- Hilfsfunktionen ------------------------------------------------------

func _validate_params(params: Array, context: String) -> bool:
	var seen := {}
	for param: Variant in params:
		if not _require_fields(param, {"name": TYPE_STRING, "type": TYPE_STRING}, context + " Parameter"):
			return false
		var name := String(param["name"])
		var type := String(param["type"])
		var pcontext := "%s Parameter '%s'" % [context, name]
		if seen.has(name):
			errors.append("%s: doppelt" % pcontext)
			return false
		seen[name] = true
		if not PARAM_TYPES.has(type):
			errors.append("%s: unbekannter Typ '%s'" % [pcontext, type])
			return false
		match type:
			"int", "float":
				for key: String in ["default", "min", "max"]:
					if not _is_number(param.get(key)):
						errors.append("%s: '%s' muss eine Zahl sein" % [pcontext, key])
						return false
			"choice":
				var options: Variant = param.get("options")
				if not (options is Array) or options.is_empty():
					errors.append("%s: 'options' muss ein nicht-leeres Array sein" % pcontext)
					return false
				var values := []
				for option: Variant in options:
					if not _require_fields(option, {"value": TYPE_STRING, "label": TYPE_STRING}, pcontext + " Option"):
						return false
					values.append(option["value"])
				if not values.has(param.get("default")):
					errors.append("%s: 'default' muss eine der Optionen sein" % pcontext)
					return false
			"resource":
				if param.has("default") and not resources.has(param["default"]):
					errors.append("%s: unbekannter Rohstoff '%s'" % [pcontext, param["default"]])
					return false
			"product":
				if param.has("default") and not craftable_resources().has(param["default"]):
					errors.append("%s: '%s' ist kein herstellbares Verbrauchsgut" % [pcontext, param["default"]])
					return false
	return true


## Ergänzt fehlende Parameter mit Voreinstellungen und prüft Typen/Bereiche der vorhandenen.
func _normalize_params(param_defs: Array, given: Variant, context: String) -> Dictionary:
	var result := {}
	var given_dict: Dictionary = given if given is Dictionary else {}
	for param_def: Dictionary in param_defs:
		var name := String(param_def["name"])
		var value: Variant = given_dict.get(name, param_default(param_def))
		match String(param_def["type"]):
			"int", "float", "radius":
				if not _is_number(value):
					errors.append("%s: Parameter '%s' muss eine Zahl sein" % [context, name])
					value = param_default(param_def)
				elif param_def.has("min") and float(value) < float(param_def["min"]):
					value = param_def["min"]
				elif param_def.has("max") and float(value) > float(param_def["max"]):
					value = param_def["max"]
				value = int(value) if String(param_def["type"]) == "int" else float(value)
			"choice":
				var valid := false
				for option: Dictionary in param_def["options"]:
					if option["value"] == value:
						valid = true
				if not valid:
					errors.append("%s: Parameter '%s' hat ungültigen Wert '%s'" % [context, name, value])
					value = param_default(param_def)
			"resource":
				if not resources.has(value):
					errors.append("%s: Parameter '%s' nennt unbekannten Rohstoff '%s'" % [context, name, value])
					value = param_default(param_def)
			"product":
				if not craftable_resources().has(value):
					errors.append("%s: Parameter '%s' nennt kein herstellbares Verbrauchsgut ('%s')" % [context, name, value])
					value = param_default(param_def)
			"place":
				if not (value is String) or String(value).is_empty():
					errors.append("%s: Parameter '%s' braucht einen Ort" % [context, name])
					value = PLACE_HERE
			"sensor":
				if not (value is String):
					value = ""
		result[name] = value
	for key: Variant in given_dict:
		if not result.has(key):
			errors.append("%s: unbekannter Parameter '%s'" % [context, key])
	return result


func _has_param(params: Array, name: String) -> bool:
	for param: Dictionary in params:
		if param["name"] == name:
			return true
	return false


## Prüft Pflichtfelder mit Typ. TYPE_FLOAT akzeptiert auch int.
func _require_fields(entry: Variant, fields: Dictionary, context: String) -> bool:
	if not (entry is Dictionary):
		errors.append("%s: Eintrag ist kein Objekt" % context)
		return false
	for key: String in fields:
		if not entry.has(key):
			errors.append("%s: Feld '%s' fehlt" % [context, key])
			return false
		var expected: int = fields[key]
		var value: Variant = entry[key]
		var ok := typeof(value) == expected or (expected == TYPE_FLOAT and _is_number(value))
		if not ok:
			errors.append("%s: Feld '%s' hat falschen Typ" % [context, key])
			return false
	return true


static func _is_number(value: Variant) -> bool:
	return value is float or value is int


static func _lookup(dict: Dictionary, path: String) -> Variant:
	var current: Variant = dict
	for part: String in path.split("."):
		if not (current is Dictionary) or not current.has(part):
			return null
		current = current[part]
	return current
