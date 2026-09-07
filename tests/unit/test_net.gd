extends GutTest
## Netzwerk: Protokoll (Snapshot/Absicht), Server und Client über ENet-Loopback.

const PORT: int = 7801

var data: SimData


func before_each() -> void:
	data = SimData.load_from_dir("res://data")


func test_intent_roundtrip_and_sanitizing() -> void:
	var intent := SimIntent.new()
	intent.move = Vector2(3, 4)
	intent.aim = Vector2(1, 0)
	intent.shoot = true
	var back := NetProtocol.msg_to_intent(NetProtocol.decode(NetProtocol.encode(NetProtocol.intent_to_msg(intent))))
	assert_almost_eq(back.move.length(), 1.0, 0.001, "Bewegung auf Länge 1 begrenzt")
	assert_eq(back.aim, Vector2(1, 0))
	assert_true(back.shoot)
	var bad := NetProtocol.msg_to_intent({"t": "intent", "m": [NAN, 1.0], "a": "unsinn"})
	assert_eq(bad.move, Vector2.ZERO)
	assert_eq(bad.aim, Vector2.ZERO)


func test_snapshot_contains_only_aoi_and_own_details() -> void:
	var world := SimWorld.new(data, 2)
	var id := world.setup_new_game()
	var me := world.get_character(id)
	me.pos = Vector2(5.5, 5.5)
	var far := world.spawn_player(Vector2(38.5, 28.5), "p2", "Fern")
	far.rules = data.roles["hide"]["rules"]
	var near := world.spawn_player(Vector2(8.5, 5.5), "p3", "Nah")
	world.add_marker(id)
	world.tick()
	var known := {}
	var node_state := {}
	var snap := NetProtocol.snapshot(world, id, known, node_state)
	var ids := {}
	for row: Array in snap["chars"]:
		ids[int(row[0])] = row
	assert_true(ids.has(id))
	assert_true(ids.has(near.id))
	assert_false(ids.has(far.id), "außer Sicht")
	assert_eq(snap["intro"].size(), ids.size(), "beim ersten Mal Stammdaten für alle in Sicht")
	for intro: Dictionary in snap["intro"]:
		assert_false(intro.has("rules"), "fremde Regeln werden nie gesendet")
	assert_true(snap.has("nodes"), "erster Snapshot bringt die Quellen mit")
	var second := NetProtocol.snapshot(world, id, known, node_state)
	assert_false(second.has("intro"), "bekannte Charaktere: keine Stammdaten mehr")
	assert_false(second.has("nodes"), "unveränderte Quellen gehen nicht nochmal mit")
	var block := NetProtocol.self_block(me)
	assert_eq(block["markers"].size(), 1)
	assert_eq(block["rules"].size(), 3)
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	NetProtocol.apply_self(mirror, id, NetProtocol.decode(NetProtocol.encode({"self": block}))["self"])
	assert_eq(mirror.characters.size(), ids.size())
	assert_eq(mirror.get_character(id).markers[0]["name"], "Marker 1")
	assert_eq(mirror.get_character(near.id).name, "Nah")
	assert_almost_eq(mirror.get_character(near.id).pos.x, 8.5, 0.001)
	assert_eq(mirror.time, world.time)
	var bytes := NetProtocol.encode(second).size()
	assert_lt(bytes, 60 * ids.size() + 200, "kompakt: unter 60 Byte je Charakter (%d Byte für %d)" % [bytes, ids.size()])


func test_server_and_client_over_loopback() -> void:
	var world := SimWorld.new(data, 4)
	world.setup_new_game()
	world.characters.erase(1)
	var server := NetServer.new()
	assert_eq(server.start(data, world, PORT, 8), OK)
	var client := NetClient.new()
	assert_eq(client.connect_to(data, "127.0.0.1", PORT, "Anna"), OK)
	var joined := false
	for i in 200:
		server.update(0.05)
		client.poll()
		await wait_frames(1)
		if client.joined:
			joined = true
			break
	assert_true(joined, "Beitritt bestätigt")
	var me := world.get_character(client.my_id)
	assert_not_null(me)
	assert_eq(me.owner_id, "Anna")
	assert_eq(me.control, SimCharacter.Controller.PLAYER)
	# Absicht: nach rechts laufen
	var intent := SimIntent.new()
	intent.move = Vector2.RIGHT
	var start_x := me.pos.x
	for i in 40:
		client.send_intent(intent)
		server.update(0.05)
		client.poll()
		await wait_frames(1)
	assert_gt(me.pos.x, start_x + 1.0, "Server hat die Absicht angewendet")
	assert_gt(client.snapshots_in, 5, "Snapshots kommen an")
	for i in 20:
		server.update(0.05)  # ohne neue Absicht bleibt der Charakter stehen (Absicht verfällt)
		client.poll()
		await wait_frames(1)
	var mirrored := client.me()
	assert_not_null(mirrored)
	assert_almost_eq(mirrored.pos.x, me.pos.x, 0.5, "Spiegelwelt folgt")
	# Ausloggen per Nachricht: Charakter wird NPC
	client.send({"t": "logout", "rules": data.roles["guard"]["rules"], "role": "guard"}, true)
	for i in 10:
		server.update(0.05)
		client.poll()
		await wait_frames(1)
	assert_eq(me.control, SimCharacter.Controller.RULES)
	assert_eq(me.role_id, "guard")
	# Trennen und wiederkommen: derselbe Charakter wird übernommen
	client.disconnect_from_server()
	for i in 10:
		server.update(0.05)
		await wait_frames(1)
	var client2 := NetClient.new()
	assert_eq(client2.connect_to(data, "127.0.0.1", PORT, "Anna"), OK)
	for i in 200:
		server.update(0.05)
		client2.poll()
		await wait_frames(1)
		if client2.joined:
			break
	assert_eq(client2.my_id, me.id, "Rückkehrer bekommt seinen NPC zurück")
	assert_eq(me.control, SimCharacter.Controller.PLAYER, "und ist wieder eingeloggt")
	client2.disconnect_from_server()
	server.stop()


func test_client_receives_server_map() -> void:
	var server_data := SimData.load_from_dir("res://data")
	assert_true(server_data.apply_map(MapGen.generate(60, 40, 3)).is_empty())
	var world := SimWorld.new(server_data, 6)
	world.setup_new_game()
	world.characters.erase(1)
	var server := NetServer.new()
	assert_eq(server.start(server_data, world, PORT + 2, 8), OK)
	var client := NetClient.new()
	client.connect_to(data, "127.0.0.1", PORT + 2, "Cleo")
	for i in 200:
		server.update(0.05)
		client.poll()
		await wait_frames(1)
		if client.joined:
			break
	assert_true(client.joined)
	assert_eq(client.mirror.map.width, 60, "Karte kommt vom Server")
	assert_eq(client.mirror.map.height, 40)
	assert_eq(client.mirror.map.nodes.size(), world.map.nodes.size())
	client.disconnect_from_server()
	server.stop()


func test_disconnect_turns_character_into_npc() -> void:
	var world := SimWorld.new(data, 5)
	world.setup_new_game()
	world.characters.erase(1)
	var server := NetServer.new()
	assert_eq(server.start(data, world, PORT + 1, 8), OK)
	var client := NetClient.new()
	client.connect_to(data, "127.0.0.1", PORT + 1, "Ben")
	for i in 200:
		server.update(0.05)
		client.poll()
		await wait_frames(1)
		if client.joined:
			break
	var me := world.get_character(client.my_id)
	client.disconnect_from_server()
	for i in 40:
		server.update(0.05)
		await wait_frames(1)
	assert_eq(me.control, SimCharacter.Controller.RULES, "getrennt = NPC mit Default-Regeln")
	assert_true(world.in_transition(me), "Übergang läuft, kein sofortiger Schutz")
	server.stop()
