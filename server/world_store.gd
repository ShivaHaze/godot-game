class_name WorldStore
extends RefCounted
## Persistenz der Welt in SQLite (Erweiterung godot-sqlite): eine Datei je Welt, Transaktionen, Sicherung per Kopie.
## Das Format bleibt das Dictionary aus SimSave (exakt, binär je Zeile), aufgeteilt in Zeilen je Charakter, Bauteil,
## Claim und Quelle plus einem Weltblock; abfragbare Spalten (Besitzer, Name, Art, Position) liegen daneben.
## Geschrieben wird nur, was sich seit dem letzten Mal geändert hat – zwei Sekunden alter Zustand pro Zeile als Vergleich.
## Schema mit Versionsnummer und Migrationen von Anfang an; nur Standard-SQL, damit ein Umzug (Postgres) lokal bleibt.

const SCHEMA_VERSION: int = 1
const WORLD_KEYS: Array[String] = [
	"version", "time", "tick_count", "next_id", "wolf_respawn_timer", "rng_seed", "rng_state", "projectiles",
	"next_building_id", "next_claim_id", "guilds", "letters", "next_boss_time", "next_caravan_time", "caravans",
]

var path: String = ""
var db: SQLite = null
var last_written: int = 0      # Zeilen der letzten Speicherung (eingefügt oder geändert)
var last_deleted: int = 0
var _cache: Dictionary = {}    # "characters:12" -> PackedByteArray des zuletzt geschriebenen Zustands


## Datenbank öffnen oder anlegen; legt das Schema an und führt Migrationen aus.
func open(p_path: String) -> Error:
	path = p_path
	db = SQLite.new()
	db.path = path
	db.verbosity_level = SQLite.QUIET
	db.foreign_keys = false
	if not db.open_db():
		push_error("Datenbank lässt sich nicht öffnen: %s (%s)" % [path, db.error_message])
		db = null
		return ERR_CANT_OPEN
	_exec("PRAGMA journal_mode=WAL;")
	_exec("PRAGMA synchronous=NORMAL;")
	_migrate()
	return OK


func close() -> void:
	if db != null:
		db.close_db()
		db = null
	_cache.clear()


func is_open() -> bool:
	return db != null


## Gibt es schon eine gespeicherte Welt?
func has_world() -> bool:
	return _scalar("SELECT COUNT(*) AS n FROM world;", "n") > 0


## Welt speichern: nur geänderte Zeilen, alles in einer Transaktion. force = alles schreiben (erstes Mal, Import).
func save(world: SimWorld, force: bool = false) -> Error:
	if db == null:
		return ERR_UNCONFIGURED
	var dict := SimSave.world_to_dict(world)
	var head := {}
	for key: String in WORLD_KEYS:
		if dict.has(key):
			head[key] = dict[key]
	last_written = 0
	last_deleted = 0
	var seen := {}
	if not _exec("BEGIN;"):
		return ERR_DATABASE_CANT_WRITE
	_put("world", "1", head, force, seen, func(blob: PackedByteArray) -> bool:
		return _run("INSERT INTO world (id, state) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state;", [blob]))
	for entry: Dictionary in dict["characters"]:
		var pos: Array = entry.get("pos", [0, 0])
		_put("characters", str(entry["id"]), entry, force, seen, func(blob: PackedByteArray) -> bool:
			return _run("INSERT INTO characters (id, owner, name, kind, control, dead, x, y, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
				+ "ON CONFLICT(id) DO UPDATE SET owner = excluded.owner, name = excluded.name, kind = excluded.kind, control = excluded.control, "
				+ "dead = excluded.dead, x = excluded.x, y = excluded.y, state = excluded.state;",
				[int(entry["id"]), String(entry["owner_id"]), String(entry["name"]), int(entry["kind"]), int(entry["control"]), 1 if bool(entry["dead"]) else 0, float(pos[0]), float(pos[1]), blob]))
	for entry: Dictionary in dict["buildings"]:
		_put("buildings", str(entry["id"]), entry, force, seen, func(blob: PackedByteArray) -> bool:
			return _run("INSERT INTO buildings (id, part, owner, state) VALUES (?, ?, ?, ?) "
				+ "ON CONFLICT(id) DO UPDATE SET part = excluded.part, owner = excluded.owner, state = excluded.state;",
				[int(entry["id"]), String(entry["part"]), String(entry["owner"]), blob]))
	for entry: Dictionary in dict["claims"]:
		_put("claims", str(entry["id"]), entry, force, seen, func(blob: PackedByteArray) -> bool:
			return _run("INSERT INTO claims (id, owner, state) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET owner = excluded.owner, state = excluded.state;",
				[int(entry["id"]), String(entry["owner"]), blob]))
	for entry: Dictionary in dict["nodes"]:
		var cell: Array = entry["cell"]
		var key := "%d,%d" % [int(cell[0]), int(cell[1])]
		_put("nodes", key, entry, force, seen, func(blob: PackedByteArray) -> bool:
			return _run("INSERT INTO nodes (cell, amount, regrow, state) VALUES (?, ?, ?, ?) ON CONFLICT(cell) DO UPDATE SET amount = excluded.amount, regrow = excluded.regrow, state = excluded.state;",
				[key, int(entry["amount"]), float(entry.get("regrow_timer", 0.0)), blob]))
	# Verschwundene Zeilen (verrottete Leichen, abgerissene Bauteile, aufgelöste Claims) löschen
	for cache_key: String in _cache.keys():
		if seen.has(cache_key):
			continue
		var parts := cache_key.split(":", true, 1)
		var table := parts[0]
		var id := parts[1]
		var ok := _run("DELETE FROM nodes WHERE cell = ?;", [id]) if table == "nodes" else _run("DELETE FROM %s WHERE id = ?;" % table, [int(id)])
		if ok:
			_cache.erase(cache_key)
			last_deleted += 1
	if not _exec("COMMIT;"):
		_exec("ROLLBACK;")
		return ERR_DATABASE_CANT_WRITE
	set_meta_value("saved_at", str(int(Time.get_unix_time_from_system())))
	return OK


## Welt laden. null, wenn keine gespeichert ist oder das Format nicht passt.
func load_world(data: SimData) -> SimWorld:
	if db == null or not has_world():
		return null
	var dict: Dictionary = {}
	for row: Dictionary in _rows("SELECT state FROM world WHERE id = 1;"):
		dict = _decode(row["state"])
	if dict.is_empty():
		return null
	_cache.clear()
	_cache["world:1"] = var_to_bytes(dict)
	dict["characters"] = []
	for row: Dictionary in _rows("SELECT id, state FROM characters ORDER BY id;"):
		var entry := _decode(row["state"])
		dict["characters"].append(entry)
		_cache["characters:%d" % int(row["id"])] = var_to_bytes(entry)
	dict["buildings"] = []
	for row: Dictionary in _rows("SELECT id, state FROM buildings ORDER BY id;"):
		var entry := _decode(row["state"])
		dict["buildings"].append(entry)
		_cache["buildings:%d" % int(row["id"])] = var_to_bytes(entry)
	dict["claims"] = []
	for row: Dictionary in _rows("SELECT id, state FROM claims ORDER BY id;"):
		var entry := _decode(row["state"])
		dict["claims"].append(entry)
		_cache["claims:%d" % int(row["id"])] = var_to_bytes(entry)
	dict["nodes"] = []
	for row: Dictionary in _rows("SELECT cell, state FROM nodes;"):
		var entry := _decode(row["state"])
		dict["nodes"].append(entry)
		_cache["nodes:%s" % String(row["cell"])] = var_to_bytes(entry)
	return SimSave.world_from_dict(data, dict)


## Alten Spielstand (server_save.dat) einmalig übernehmen. true, wenn importiert.
func import_legacy(data: SimData, legacy_path: String) -> bool:
	if db == null or has_world() or not FileAccess.file_exists(legacy_path):
		return false
	var saved := SimSave.load_from_file(data, legacy_path)
	if saved.is_empty():
		return false
	return save(saved["world"], true) == OK


## Sicherungskopie (SQLite-Backup-API, konsistent auch im Betrieb). Behält die neuesten `keep` Dateien im Ordner.
func backup(dir: String, keep: int = 7, stamp: String = "") -> String:
	if db == null:
		return ""
	DirAccess.make_dir_recursive_absolute(dir)
	if stamp.is_empty():
		stamp = Time.get_datetime_string_from_system(true, false).replace(":", "-")
	var target := dir.path_join("world-%s.db" % stamp)
	if not db.backup_to(target):
		push_error("Sicherung fehlgeschlagen: %s (%s)" % [target, db.error_message])
		return ""
	var names: PackedStringArray = []
	for name: String in DirAccess.get_files_at(dir):
		if name.begins_with("world-") and name.ends_with(".db"):
			names.append(name)
	names.sort()
	while names.size() > keep:
		DirAccess.remove_absolute(dir.path_join(names[0]))
		names.remove_at(0)
	return target


func meta_value(key: String, default: String = "") -> String:
	for row: Dictionary in _rows_with("SELECT value FROM meta WHERE key = ?;", [key]):
		return String(row["value"])
	return default


func row_count(table: String) -> int:
	return _scalar("SELECT COUNT(*) AS n FROM %s;" % table, "n")


# --- intern ----------------------------------------------------------------

## Zeile schreiben, wenn sich der Zustand seit dem letzten Mal geändert hat.
func _put(table: String, id: String, entry: Dictionary, force: bool, seen: Dictionary, write: Callable) -> void:
	var key := "%s:%s" % [table, id]
	seen[key] = true
	var blob := var_to_bytes(entry)
	if not force and _cache.has(key) and _cache[key] == blob:
		return
	if write.call(blob):
		_cache[key] = blob
		last_written += 1


func _migrate() -> void:
	_exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
	var current := int(meta_value("schema_version", "0"))
	if current < 1:
		_exec("CREATE TABLE IF NOT EXISTS world (id INTEGER PRIMARY KEY CHECK (id = 1), state BLOB NOT NULL);")
		_exec("CREATE TABLE IF NOT EXISTS characters (id INTEGER PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL, kind INTEGER NOT NULL, control INTEGER NOT NULL, dead INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, state BLOB NOT NULL);")
		_exec("CREATE INDEX IF NOT EXISTS characters_owner ON characters (owner);")
		_exec("CREATE TABLE IF NOT EXISTS buildings (id INTEGER PRIMARY KEY, part TEXT NOT NULL, owner TEXT NOT NULL, state BLOB NOT NULL);")
		_exec("CREATE INDEX IF NOT EXISTS buildings_owner ON buildings (owner);")
		_exec("CREATE TABLE IF NOT EXISTS claims (id INTEGER PRIMARY KEY, owner TEXT NOT NULL, state BLOB NOT NULL);")
		_exec("CREATE TABLE IF NOT EXISTS nodes (cell TEXT PRIMARY KEY, amount INTEGER NOT NULL, regrow REAL NOT NULL, state BLOB NOT NULL);")
		set_meta_value("created_at", str(int(Time.get_unix_time_from_system())))
		current = 1
	# Künftige Migrationen: if current < 2: … ; current = 2
	set_meta_value("schema_version", str(SCHEMA_VERSION))


func set_meta_value(key: String, value: String) -> void:
	_run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", [key, value])


func _exec(sql: String) -> bool:
	if not db.query(sql):
		push_error("SQL fehlgeschlagen: %s – %s" % [sql.substr(0, 60), db.error_message])
		return false
	return true


func _run(sql: String, bindings: Array) -> bool:
	if not db.query_with_bindings(sql, bindings):
		push_error("SQL fehlgeschlagen: %s – %s" % [sql.substr(0, 60), db.error_message])
		return false
	return true


func _rows(sql: String) -> Array:
	if not db.query(sql):
		push_error("SQL fehlgeschlagen: %s – %s" % [sql.substr(0, 60), db.error_message])
		return []
	return db.query_result


func _rows_with(sql: String, bindings: Array) -> Array:
	if not db.query_with_bindings(sql, bindings):
		return []
	return db.query_result


func _scalar(sql: String, column: String) -> int:
	for row: Dictionary in _rows(sql):
		return int(row[column])
	return 0


static func _decode(blob: Variant) -> Dictionary:
	var value: Variant = bytes_to_var(blob)
	return value if value is Dictionary else {}
