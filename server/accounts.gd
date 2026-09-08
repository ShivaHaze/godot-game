class_name Accounts
extends RefCounted
## Konten: der Name ist die Identität eines Spielers, das Passwort schützt sie. Beim ersten Beitritt mit einem neuen
## Namen wird das Konto mit dem gewählten Passwort angelegt, danach muss es stimmen. Passwörter liegen nie im Klartext:
## PBKDF2 mit HMAC-SHA256, zufälligem Salz und vielen Runden; der Vergleich läuft in konstanter Zeit.
## Die Ablage steckt hinter `store` (Datei jetzt, Datenbank in Schritt 52), damit der Wechsel lokal bleibt.
## Bekannte Grenze des Prototyps: das Passwort geht unverschlüsselt über ENet (DTLS später).

const MIN_PASSWORD_LENGTH: int = 4
const NAME_MIN: int = 2
const NAME_MAX: int = 24
const ITERATIONS: int = 10000
const SALT_BYTES: int = 16
const HASH_BYTES: int = 32

var store: AccountStore
var _records: Dictionary = {}   # Schlüssel (Name in Kleinbuchstaben) -> {name, salt, hash, iterations, created_at, last_login_at}


func _init(p_store: AccountStore = null) -> void:
	store = p_store if p_store != null else AccountFileStore.new()
	_records = store.load_all()


func count() -> int:
	return _records.size()


func has(name: String) -> bool:
	return _records.has(_key(name))


## Anmelden oder beim ersten Mal anlegen. Rückgabe: leer = angenommen, sonst der Grund für den Spieler.
func login(name: String, password: String) -> String:
	var trimmed := name.strip_edges()
	if trimmed.length() < NAME_MIN or trimmed.length() > NAME_MAX:
		return "Name braucht %d bis %d Zeichen" % [NAME_MIN, NAME_MAX]
	if password.length() < MIN_PASSWORD_LENGTH:
		return "Passwort braucht mindestens %d Zeichen" % MIN_PASSWORD_LENGTH
	var key := _key(trimmed)
	var now := int(Time.get_unix_time_from_system())
	if not _records.has(key):
		var salt := Crypto.new().generate_random_bytes(SALT_BYTES)
		var record := {"name": trimmed, "salt": salt, "hash": hash_password(password, salt, ITERATIONS), "iterations": ITERATIONS, "created_at": now, "last_login_at": now}
		_records[key] = record
		store.save(key, record)
		return ""
	var record: Dictionary = _records[key]
	var expected: PackedByteArray = record["hash"]
	var actual := hash_password(password, record["salt"], int(record["iterations"]))
	if not constant_time_equal(expected, actual):
		return "falsches Passwort für „%s“" % record["name"]
	record["last_login_at"] = now
	store.save(key, record)
	return ""


## Anzeigename, wie beim Anlegen geschrieben (Groß-/Kleinschreibung bleibt erhalten).
func display_name(name: String) -> String:
	var record: Dictionary = _records.get(_key(name), {})
	return String(record.get("name", name.strip_edges()))


static func _key(name: String) -> String:
	return name.strip_edges().to_lower()


## PBKDF2-HMAC-SHA256, ein Block (32 Byte): U1 = HMAC(P, S‖1), Ui = HMAC(P, Ui−1), Ergebnis = U1 ⊕ … ⊕ Un.
static func hash_password(password: String, salt: PackedByteArray, iterations: int) -> PackedByteArray:
	var crypto := Crypto.new()
	var key := password.to_utf8_buffer()
	var block := salt.duplicate()
	block.append_array(PackedByteArray([0, 0, 0, 1]))
	var u := crypto.hmac_digest(HashingContext.HASH_SHA256, key, block)
	var result := u.duplicate()
	for i in range(1, iterations):
		u = crypto.hmac_digest(HashingContext.HASH_SHA256, key, u)
		for j in HASH_BYTES:
			result[j] = result[j] ^ u[j]
	return result


## Vergleich ohne frühen Abbruch, damit die Laufzeit nichts über den Inhalt verrät.
static func constant_time_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff := 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0


## Ablage der Konten: laden und je Konto speichern.
class AccountStore:
	extends RefCounted

	func load_all() -> Dictionary:
		return {}

	func save(_key: String, _record: Dictionary) -> void:
		pass


## Binäre Datei (var_to_bytes) unter user://; Schritt 52 ersetzt sie durch die Datenbank.
class AccountFileStore:
	extends AccountStore

	const PATH: String = "user://accounts.dat"

	var path: String = PATH
	var _all: Dictionary = {}

	func _init(p_path: String = PATH) -> void:
		path = p_path

	func load_all() -> Dictionary:
		_all = {}
		if path.is_empty() or not FileAccess.file_exists(path):
			return _all
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return _all
		var parsed: Variant = file.get_var()
		file.close()
		if parsed is Dictionary:
			_all = parsed
		return _all.duplicate(true)

	func save(key: String, record: Dictionary) -> void:
		_all[key] = record.duplicate()
		if path.is_empty():
			return
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			push_error("Konten konnten nicht gespeichert werden: %s" % path)
			return
		file.store_var(_all)
		file.close()
