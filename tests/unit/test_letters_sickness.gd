extends GutTest
## Briefe (liegen beim Server bis zum Einloggen) und Krankheit als Ereignis (langsam, hungrig, Medizin heilt).

const PORT: int = 7813
const OPEN: Vector2 = Vector2(20.5, 5.5)


func test_sickness_slows_hungers_and_medicine_cures() -> void:
	var data := SimData.load_from_dir("res://data")
	data.balance["effects"]["sick"]["chance_per_hour"] = 0.0
	var world := SimWorld.new(data, 261)
	world.lod_enabled = false
	var player := world.get_character(world.setup_new_game())
	player.pos = Vector2(10.5, 5.5)
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.control = SimCharacter.Controller.NONE
			c.pos = Vector2(38.5, 28.5)
	var walk := SimIntent.new()
	walk.move = Vector2.RIGHT
	var start := player.pos
	var hunger_start := player.hunger
	for i in 20:
		world.set_intent(player.id, walk)
		world.tick()
	var healthy_distance := player.pos.distance_to(start)
	var healthy_hunger := hunger_start - player.hunger
	SimEffects.apply_effect(world, player, "sick", -1)
	assert_true(SimEffects.has_effect(world, player, "sick"))
	player.pos = start
	hunger_start = player.hunger
	for i in 20:
		world.set_intent(player.id, walk)
		world.tick()
	assert_almost_eq(player.pos.distance_to(start) / healthy_distance, 0.75, 0.03, "25 % langsamer")
	assert_almost_eq((hunger_start - player.hunger) / healthy_hunger, 2.0, 0.05, "doppelt so hungrig")
	player.inventory["medicine"] = 1
	assert_eq(SimCrafting.heal_item_of(world, player), "medicine", "Medizin gegen Krankheit")
	var heal := SimIntent.new()
	heal.heal = true
	for i in 20 * 2 + 1:
		world.set_intent(player.id, heal)
		world.tick()
	assert_false(SimEffects.has_effect(world, player, "sick"), "geheilt")
	# Ohne Medizin klingt sie nach der Dauer ab; Chronik beim Offline-Charakter
	world.logout(player.id, data.roles["hide"]["rules"])
	SimEffects.apply_effect(world, player, "sick", -1)
	world.advance(data.balf("effects.sick.duration") + 5.0)
	assert_false(SimEffects.has_effect(world, player, "sick"))
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("erkrankt"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])


func test_sickness_strikes_randomly() -> void:
	var data := SimData.load_from_dir("res://data")
	data.balance["effects"]["sick"]["chance_per_hour"] = 60.0  # praktisch sicher innerhalb weniger Minuten
	var world := SimWorld.new(data, 262)
	world.lod_enabled = false
	var player := world.get_character(world.setup_new_game())
	world.logout(player.id, data.roles["hide"]["rules"])
	var struck := false
	for i in 20 * 60 * 5:
		world.tick()
		if SimEffects.has_effect(world, player, "sick"):
			struck = true
			break
	assert_true(struck, "Krankheit trifft zufällig")


func test_letters_in_sim_and_save() -> void:
	var data := SimData.load_from_dir("res://data")
	var world := SimWorld.new(data, 263)
	world.setup_new_game()
	world.spawn_player(OPEN, "p2", "Nachbar")
	assert_eq(world.send_letter("p1", "p9", "Hallo"), "Empfänger „p9“ unbekannt")
	assert_eq(world.send_letter("p1", "p1", "Hallo"), "an dich selbst?")
	assert_eq(world.send_letter("p1", "p2", ""), "Empfänger und Text nötig")
	assert_eq(world.send_letter("p1", "p2", "  Treffen am Markt  "), "")
	assert_eq(world.send_letter("p2", "p1", "Gern"), "")
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	var mail := copy.take_letters("p2")
	assert_eq(mail.size(), 1)
	assert_eq(mail[0]["from"], "p1")
	assert_eq(mail[0]["text"], "Treffen am Markt", "getrimmt")
	assert_eq(copy.take_letters("p2").size(), 0, "abgeholt")
	assert_eq(copy.take_letters("p1").size(), 1)


func test_letter_over_loopback_delivered_on_join() -> void:
	var data := SimData.load_from_dir("res://data")
	var world := SimWorld.new(data, 264)
	world.setup_new_game()
	world.characters.erase(1)
	var server := NetServer.new()
	assert_eq(server.start(data, world, PORT, 8), OK)
	var a := NetClient.new()
	var b := NetClient.new()
	a.connect_to(data, "127.0.0.1", PORT, "Anna")
	b.connect_to(data, "127.0.0.1", PORT, "Ben")
	for i in 200:
		server.update(0.05)
		a.poll()
		b.poll()
		await wait_frames(1)
		if a.joined and b.joined:
			break
	assert_true(a.joined and b.joined)
	b.disconnect_from_server()
	for i in 6:
		server.update(0.05)
		a.poll()
		await wait_frames(1)
	a.messages.clear()
	a.send({"t": "letter", "to": "Ben", "text": "Komm zum Anker"}, true)
	for i in 6:
		server.update(0.05)
		a.poll()
		await wait_frames(1)
	var hinterlegt := false
	for msg: Dictionary in a.messages:
		if msg.get("t", "") == "info" and String(msg.get("text", "")).contains("hinterlegt"):
			hinterlegt = true
	assert_true(hinterlegt, "Anna: %s" % [a.messages])
	assert_eq(world.letters.get("Ben", []).size(), 1, "liegt beim Server")
	# Ben loggt sich wieder ein und bekommt den Brief
	var b2 := NetClient.new()
	b2.connect_to(data, "127.0.0.1", PORT, "Ben")
	for i in 200:
		server.update(0.05)
		a.poll()
		b2.poll()
		await wait_frames(1)
		if b2.joined:
			break
	for i in 6:
		server.update(0.05)
		b2.poll()
		await wait_frames(1)
	var letters := []
	for msg: Dictionary in b2.messages:
		if msg.get("t", "") == "chat" and msg.get("scope", "") == "letter":
			letters.append(msg)
	assert_eq(letters.size(), 1, "Ben: %s" % [b2.messages])
	assert_eq(letters[0]["from"], "Anna")
	assert_eq(letters[0]["text"], "Komm zum Anker")
	assert_true(world.letters.get("Ben", []).is_empty(), "abgeholt")
	a.disconnect_from_server()
	b2.disconnect_from_server()
	server.stop()
