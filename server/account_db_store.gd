class_name AccountDbStore
extends Accounts.AccountStore
## Konten in einer eigenen SQLite-Datei (accounts.db), getrennt von der Welt: so kann sie später zu einem zentralen
## Kontodienst wandern, ohne die Weltpersistenz anzufassen. Passwörter liegen nur als Salz und Hash (siehe Accounts).

const SCHEMA_VERSION: int = 1

var path: String = ""
var db: SQLite = null


func _init(p_path: String) -> void:
	path = p_path
	db = SQLite.new()
	db.path = path
	db.verbosity_level = SQLite.QUIET
	if not db.open_db():
		push_error("Kontodatenbank lässt sich nicht öffnen: %s (%s)" % [path, db.error_message])
		db = null
		return
	db.query("PRAGMA journal_mode=WAL;")
	db.query("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
	db.query("CREATE TABLE IF NOT EXISTS accounts (key TEXT PRIMARY KEY, name TEXT NOT NULL, salt BLOB NOT NULL, hash BLOB NOT NULL, iterations INTEGER NOT NULL, created_at INTEGER NOT NULL, last_login_at INTEGER NOT NULL);")
	db.query_with_bindings("INSERT INTO meta (key, value) VALUES ('schema_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", [str(SCHEMA_VERSION)])


func close() -> void:
	if db != null:
		db.close_db()
		db = null


func load_all() -> Dictionary:
	var result := {}
	if db == null or not db.query("SELECT key, name, salt, hash, iterations, created_at, last_login_at FROM accounts;"):
		return result
	for row: Dictionary in db.query_result:
		result[String(row["key"])] = {
			"name": String(row["name"]), "salt": row["salt"], "hash": row["hash"], "iterations": int(row["iterations"]),
			"created_at": int(row["created_at"]), "last_login_at": int(row["last_login_at"]),
		}
	return result


func save(key: String, record: Dictionary) -> void:
	if db == null:
		return
	var ok := db.query_with_bindings(
		"INSERT INTO accounts (key, name, salt, hash, iterations, created_at, last_login_at) VALUES (?, ?, ?, ?, ?, ?, ?) "
		+ "ON CONFLICT(key) DO UPDATE SET name = excluded.name, salt = excluded.salt, hash = excluded.hash, iterations = excluded.iterations, last_login_at = excluded.last_login_at;",
		[key, String(record["name"]), record["salt"], record["hash"], int(record["iterations"]), int(record["created_at"]), int(record["last_login_at"])])
	if not ok:
		push_error("Konto konnte nicht gespeichert werden: %s" % db.error_message)


## Alte Kontodatei (accounts.dat) einmalig übernehmen. Rückgabe: Zahl der übernommenen Konten.
func import_legacy(legacy_path: String) -> int:
	if db == null or not FileAccess.file_exists(legacy_path) or not load_all().is_empty():
		return 0
	var legacy := Accounts.AccountFileStore.new(legacy_path).load_all()
	for key: String in legacy:
		save(key, legacy[key])
	return legacy.size()
