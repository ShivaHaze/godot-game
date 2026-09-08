extends GutTest
## Gilden über den Server: Befehle (gründen, einladen, annehmen, verlassen), Gildenchat nur für Mitglieder, Selbstblock mit Einladung.

const PORT: int = 7812


func test_guild_commands_and_guild_chat_over_loopback() -> void:
	var data := SimData.load_from_dir("res://data")
	var world := SimWorld.new(data, 251)
	world.setup_new_game()
	world.characters.erase(1)
	var server := NetServer.new()
	assert_eq(server.start(data, world, PORT, 8), OK)
	var a := NetClient.new()
	var b := NetClient.new()
	var c := NetClient.new()
	a.connect_to(data, "127.0.0.1", PORT, "Anna")
	b.connect_to(data, "127.0.0.1", PORT, "Ben")
	c.connect_to(data, "127.0.0.1", PORT, "Cleo")
	for i in 200:
		server.update(0.05)
		a.poll()
		b.poll()
		c.poll()
		await wait_frames(1)
		if a.joined and b.joined and c.joined:
			break
	assert_true(a.joined and b.joined and c.joined)
	# Anna gründet, lädt Ben ein; Ben nimmt an
	a.send({"t": "guild", "op": "found", "arg": "Grenzwacht"}, true)
	await _pump(server, [a, b, c], 6)
	assert_true(_infos(a).size() >= 1 and _infos(a)[0].contains("gegründet"), "Anna: %s" % [_infos(a)])
	assert_true(world.guilds.guild_of("Anna") >= 0)
	a.send({"t": "guild", "op": "invite", "arg": "Ben"}, true)
	await _pump(server, [a, b, c], 6)
	assert_true(_infos(b).size() >= 1 and _infos(b)[_infos(b).size() - 1].contains("Einladung"), "Ben: %s" % [_infos(b)])
	assert_eq(b.mirror.guild_invite_name, "Grenzwacht", "Einladung im Selbstblock")
	b.send({"t": "guild", "op": "accept", "arg": ""}, true)
	await _pump(server, [a, b, c], 6)
	assert_true(world.allied("Anna", "Ben"))
	assert_eq(b.mirror.guilds.name_of("Ben"), "Grenzwacht", "Ben sieht seine Gilde")
	assert_eq(a.mirror.guilds.members_of("Anna").size(), 2, "Anna sieht beide Mitglieder")
	assert_eq(b.mirror.guild_invite_name, "", "Einladung erledigt")
	# Gildenchat: Cleo hört nichts, Ben schon (egal wie weit weg)
	world.get_character(c.my_id).pos = world.get_character(a.my_id).pos + Vector2(1, 0)
	world.get_character(b.my_id).pos = Vector2(38.5, 28.5)
	a.messages.clear()
	b.messages.clear()
	c.messages.clear()
	a.send({"t": "chat", "text": "Sammelt euch am Anker", "scope": "guild"}, true)
	await _pump(server, [a, b, c], 6)
	assert_eq(_chats(b).size(), 1, "Ben hört den Gildenchat")
	assert_eq(_chats(b)[0]["scope"], "guild")
	assert_eq(_chats(c).size(), 0, "Cleo ist nicht in der Gilde")
	c.send({"t": "chat", "text": "Hallo?", "scope": "guild"}, true)
	await _pump(server, [a, b, c], 6)
	assert_eq(_chats(a).filter(func(m: Dictionary) -> bool: return m["from"] == "Cleo").size(), 0, "ohne Gilde kein Gildenchat")
	# Verlassen
	b.send({"t": "guild", "op": "leave", "arg": ""}, true)
	await _pump(server, [a, b, c], 6)
	assert_false(world.allied("Anna", "Ben"))
	assert_eq(b.mirror.guilds.name_of("Ben"), "")
	a.disconnect_from_server()
	b.disconnect_from_server()
	c.disconnect_from_server()
	server.stop()


func test_guild_command_texts_in_single_player() -> void:
	var data := SimData.load_from_dir("res://data")
	var world := SimWorld.new(data, 252)
	world.setup_new_game()
	assert_eq(world.guild_command("p1", "found", "Grenzwacht"), "Gilde „Grenzwacht“ gegründet.")
	assert_eq(world.guild_command("p1", "invite", "Niemand"), "Gilde: Spieler „Niemand“ ist unbekannt")
	assert_eq(world.guild_command("p1", "accept", ""), "Gilde: keine Einladung")
	assert_eq(world.guild_command("p1", "leave", ""), "Du hast „Grenzwacht“ verlassen.")
	assert_true(world.guild_command("p1", "", "").begins_with("Gilde: unbekannter Befehl"))


func _pump(server: NetServer, clients: Array, rounds: int) -> void:
	for i in rounds:
		server.update(0.05)
		for client: NetClient in clients:
			client.poll()
		await wait_frames(1)


func _infos(client: NetClient) -> Array:
	var result := []
	for msg: Dictionary in client.messages:
		if msg.get("t", "") == "info":
			result.append(String(msg.get("text", "")))
	return result


func _chats(client: NetClient) -> Array:
	var result := []
	for msg: Dictionary in client.messages:
		if msg.get("t", "") == "chat":
			result.append(msg)
	return result
