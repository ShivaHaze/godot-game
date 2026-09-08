extends GutTest
## Konten: erster Beitritt legt das Konto an, danach muss das Passwort stimmen; Hashes mit Salz und Runden,
## Vergleich in konstanter Zeit; der Server lehnt falsche Passwörter und doppelte Anmeldungen ab.

const PORT: int = 7805
const ACCOUNTS_PATH: String = "user://test_accounts.dat"

var data: SimData


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	if FileAccess.file_exists(ACCOUNTS_PATH):
		DirAccess.remove_absolute(ACCOUNTS_PATH)


func after_each() -> void:
	if FileAccess.file_exists(ACCOUNTS_PATH):
		DirAccess.remove_absolute(ACCOUNTS_PATH)


func _memory_accounts() -> Accounts:
	return Accounts.new(Accounts.AccountFileStore.new(""))


func test_password_hash_is_salted_iterated_and_compared_in_constant_time() -> void:
	var salt_a := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
	var salt_b := PackedByteArray([9, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
	var a := Accounts.hash_password("geheim", salt_a, 50)
	assert_eq(a.size(), Accounts.HASH_BYTES)
	assert_eq(Accounts.hash_password("geheim", salt_a, 50), a, "deterministisch")
	assert_ne(Accounts.hash_password("geheim", salt_b, 50), a, "anderes Salz, anderer Hash")
	assert_ne(Accounts.hash_password("Geheim", salt_a, 50), a, "anderes Passwort, anderer Hash")
	assert_ne(Accounts.hash_password("geheim", salt_a, 51), a, "andere Rundenzahl, anderer Hash")
	assert_true(Accounts.constant_time_equal(a, a.duplicate()))
	assert_false(Accounts.constant_time_equal(a, Accounts.hash_password("x", salt_a, 50)))
	assert_false(Accounts.constant_time_equal(a, a.slice(0, 31)), "verschiedene Länge")
	var started := Time.get_ticks_msec()
	Accounts.hash_password("geheim", salt_a, Accounts.ITERATIONS)
	assert_lt(Time.get_ticks_msec() - started, 2000, "eine Anmeldung darf nicht Sekunden dauern")


func test_first_login_creates_then_password_must_match() -> void:
	var accounts := _memory_accounts()
	assert_eq(accounts.login("Anna", "geheim"), "")
	assert_eq(accounts.count(), 1)
	assert_true(accounts.has("anna"), "Groß-/Kleinschreibung egal")
	assert_eq(accounts.login("anna", "geheim"), "", "derselbe Name in anderer Schreibung")
	assert_eq(accounts.display_name("ANNA"), "Anna", "Anzeigename wie beim Anlegen")
	assert_eq(accounts.login("Anna", "falsch"), "falsches Passwort für „Anna“")
	assert_eq(accounts.login("Ben", "abc"), "Passwort braucht mindestens 4 Zeichen")
	assert_eq(accounts.login("B", "geheim"), "Name braucht 2 bis 24 Zeichen")
	assert_eq(accounts.login("  ", "geheim"), "Name braucht 2 bis 24 Zeichen")
	assert_eq(accounts.count(), 1, "abgelehnte Beitritte legen nichts an")


func test_accounts_persist_in_the_store() -> void:
	var accounts := Accounts.new(Accounts.AccountFileStore.new(ACCOUNTS_PATH))
	assert_eq(accounts.login("Anna", "geheim"), "")
	assert_eq(accounts.login("Ben", "passwort"), "")
	var reloaded := Accounts.new(Accounts.AccountFileStore.new(ACCOUNTS_PATH))
	assert_eq(reloaded.count(), 2, "geladen")
	assert_eq(reloaded.login("Anna", "geheim"), "")
	assert_eq(reloaded.login("Ben", "geheim"), "falsches Passwort für „Ben“")
	assert_eq(reloaded.login("Cleo", "neu1234"), "", "neues Konto auch nach dem Laden")


func test_server_rejects_wrong_password_and_double_login() -> void:
	var world := SimWorld.new(data, 5)
	world.setup_new_game()
	world.characters.erase(1)
	var server := NetServer.new()
	server.accounts = _memory_accounts()
	assert_eq(server.start(data, world, PORT), OK)
	var anna := NetClient.new()
	assert_eq(anna.connect_to(data, "127.0.0.1", PORT, "Anna", "geheim"), OK)
	_pump(server, [anna], 40)
	assert_true(anna.joined, "erster Beitritt legt das Konto an")
	# Falsches Passwort: Ablehnung mit Grund, keine Figur
	var impostor := NetClient.new()
	assert_eq(impostor.connect_to(data, "127.0.0.1", PORT, "anna", "falsch"), OK)
	_pump(server, [anna, impostor], 40)
	assert_false(impostor.joined)
	assert_eq(_reject_reason(impostor), "falsches Passwort für „Anna“")
	assert_eq(server.rejected, 1)
	# Richtiges Passwort, aber schon online
	var twin := NetClient.new()
	assert_eq(twin.connect_to(data, "127.0.0.1", PORT, "Anna", "geheim"), OK)
	_pump(server, [anna, twin], 40)
	assert_false(twin.joined)
	assert_eq(_reject_reason(twin), "„Anna“ ist schon eingeloggt")
	var characters := 0
	for c: SimCharacter in world.characters.values():
		if c.owner_id == "Anna":
			characters += 1
	assert_eq(characters, 1, "nur eine Figur je Name")
	# Nach dem Trennen kommt Anna mit Passwort in ihre Figur zurück
	anna.disconnect_from_server()
	_pump(server, [], 20)
	var back := NetClient.new()
	assert_eq(back.connect_to(data, "127.0.0.1", PORT, "Anna", "geheim"), OK)
	_pump(server, [back], 40)
	assert_true(back.joined)
	assert_eq(back.my_id, anna.my_id, "dieselbe Figur")
	# Ohne Passwort geht auf einem Server mit Konten nichts
	var nobody := NetClient.new()
	assert_eq(nobody.connect_to(data, "127.0.0.1", PORT, "Dora", ""), OK)
	_pump(server, [back, nobody], 40)
	assert_false(nobody.joined)
	assert_eq(_reject_reason(nobody), "Passwort braucht mindestens 4 Zeichen")
	for client: NetClient in [back, impostor, twin, nobody]:
		client.disconnect_from_server()
	server.stop()


func test_open_server_without_accounts_accepts_names_only() -> void:
	var world := SimWorld.new(data, 6)
	world.setup_new_game()
	world.characters.erase(1)
	var server := NetServer.new()
	assert_eq(server.start(data, world, PORT + 1), OK)
	var bot := NetClient.new()
	assert_eq(bot.connect_to(data, "127.0.0.1", PORT + 1, "bot01"), OK)
	_pump(server, [bot], 40)
	assert_true(bot.joined, "offener Server: Name reicht")
	bot.disconnect_from_server()
	server.stop()


func test_runner_flag_open_disables_accounts() -> void:
	var runner := ServerRunner.new()
	runner.data_dir = ""
	runner.configure(PackedStringArray(["7810", "0", "0", "open"]))
	assert_false(runner.use_accounts, "'open' schaltet Konten ab")
	assert_eq(runner.port, 7810)
	var secured := ServerRunner.new()
	secured.configure(PackedStringArray(["7811"]))
	assert_true(secured.use_accounts, "sonst Konten in der Datenbank")


func _pump(server: NetServer, clients: Array, frames: int) -> void:
	for i in frames:
		server.update(0.05)
		for client: NetClient in clients:
			client.poll()
		OS.delay_msec(5)


func _reject_reason(client: NetClient) -> String:
	for msg: Dictionary in client.messages:
		if msg.get("t", "") == "reject":
			return String(msg.get("reason", ""))
	return ""
