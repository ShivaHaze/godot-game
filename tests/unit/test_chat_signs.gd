extends GutTest
## Schilder (Text, Rechte, Übertragung) und Chat (nah/global) über den Server.

const PORT: int = 7811
const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData


func before_each() -> void:
	data = SimData.load_from_dir("res://data")


func test_sign_text_rules_and_snapshot() -> void:
	var world := SimWorld.new(data, 91)
	world.lod_enabled = false
	var player := world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.inventory["wood"] = 10
	var sign := SimConstruction.place_building(world, player, "sign", Vector2i(42, 11), 0)
	assert_not_null(sign)
	assert_eq(SimConstruction.sign_near(world, player), sign)
	assert_eq(SimConstruction.set_sign_text(world, player, sign, "  Willkommen, Fremde zahlen Zoll  "), "")
	assert_eq(sign.label, "Willkommen, Fremde zahlen Zoll")
	var long := ""
	for i in 100:
		long += "x"
	SimConstruction.set_sign_text(world, player, sign, long)
	assert_eq(sign.label.length(), data.bali("building.sign_max_length"), "gekürzt")
	var stranger := world.spawn_player(OPEN + Vector2(1, 0), "p2", "Fremder")
	assert_eq(SimConstruction.set_sign_text(world, stranger, sign, "Hacked"), "nicht dein Schild")
	world.logout(player.id, data.roles["guard"]["rules"])
	assert_eq(SimConstruction.set_sign_text(world, player, sign, "offline"), "nur live")
	world.tick()
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(NetProtocol.snapshot(world, stranger.id, {}, {}, {}))))
	assert_eq(mirror.map.buildings[sign.id].label.length(), data.bali("building.sign_max_length"), "Fremde lesen den Text")


func test_chat_near_and_global_over_loopback() -> void:
	var world := SimWorld.new(data, 92)
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
	# Ben nah bei Anna, Cleo weit weg
	world.get_character(a.my_id).pos = OPEN
	world.get_character(b.my_id).pos = OPEN + Vector2(5, 0)
	world.get_character(c.my_id).pos = Vector2(38.5, 28.5)
	a.messages.clear()
	b.messages.clear()
	c.messages.clear()
	a.send({"t": "chat", "text": "Hallo Nachbar", "scope": "near"}, true)
	for i in 10:
		server.update(0.05)
		a.poll()
		b.poll()
		c.poll()
		await wait_frames(1)
	assert_eq(_chats(b).size(), 1, "Ben hört den Nah-Chat")
	assert_eq(_chats(b)[0]["from"], "Anna")
	assert_eq(_chats(a).size(), 1, "Anna hört sich selbst")
	assert_eq(_chats(c).size(), 0, "Cleo ist zu weit weg")
	a.messages.clear()
	b.messages.clear()
	c.messages.clear()
	c.send({"t": "chat", "text": "Kauft Beeren am Markt!", "scope": "global"}, true)
	for i in 10:
		server.update(0.05)
		a.poll()
		b.poll()
		c.poll()
		await wait_frames(1)
	assert_eq(_chats(a).size(), 1, "global erreicht alle")
	assert_eq(_chats(a)[0]["scope"], "global")
	assert_false(_chats(a)[0].has("pos"), "keine Positionsdaten im globalen Chat")
	a.disconnect_from_server()
	b.disconnect_from_server()
	c.disconnect_from_server()
	server.stop()


func _chats(client: NetClient) -> Array:
	var result := []
	for msg: Dictionary in client.messages:
		if msg.get("t", "") == "chat":
			result.append(msg)
	return result
