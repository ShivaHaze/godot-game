class_name NetServer
extends RefCounted
## Autoritativer Server: hält die SimWorld, nimmt ENet-Verbindungen an, wendet Absichten an, tickt bei 20 Hz
## und verschickt Snapshots (Umgebung des jeweiligen Spielers). Beim Trennen bleibt der Charakter als NPC mit
## seinen Regeln in der Welt – der Kern des Spiels. Kein Rendering, läuft headless (server/server_main.gd).

var data: SimData
var world: SimWorld
var enet: ENetConnection
var peers: Dictionary = {}           # ENetPacketPeer -> {"char_id": int, "name": String, "intent": SimIntent}
var accumulator: float = 0.0
var tick_index: int = 0
const INTENT_TTL_TICKS: int = 10     # Ohne neue Absicht steht der Charakter nach 0,5 s still
const CHAT_NEAR_RADIUS: float = 12.0 # Nah-Chat: so weit trägt die Stimme
const CHAT_MAX_LENGTH: int = 160

# Statistik
var bytes_out: int = 0
var bytes_in: int = 0
var packets_in: int = 0
var tick_ms_sum: float = 0.0
var tick_ms_max: float = 0.0
var ticks_measured: int = 0


func start(p_data: SimData, p_world: SimWorld, port: int, max_peers: int = 64) -> Error:
	data = p_data
	world = p_world
	enet = ENetConnection.new()
	var err := enet.create_host_bound("*", port, max_peers, NetProtocol.CHANNELS)
	if err != OK:
		push_error("Server konnte Port %d nicht binden: %s" % [port, error_string(err)])
	return err


func stop() -> void:
	if enet != null:
		enet.destroy()
		enet = null


## Netzwerkereignisse abholen und die Sim um `delta` Sekunden (mit festem Tick) weiterrechnen.
func update(delta: float) -> void:
	_poll_network()
	accumulator += delta
	var ticks := 0
	while accumulator >= world.tick_dt and ticks < 5:
		for peer: ENetPacketPeer in peers:
			var info: Dictionary = peers[peer]
			var c := world.get_character(int(info["char_id"]))
			if c != null and c.control == SimCharacter.Controller.PLAYER and not c.dead and tick_index - int(info["intent_tick"]) < INTENT_TTL_TICKS:
				world.set_intent(c.id, info["intent"])
		var started := Time.get_ticks_usec()
		world.tick()
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		tick_ms_sum += ms
		tick_ms_max = maxf(tick_ms_max, ms)
		ticks_measured += 1
		tick_index += 1
		if tick_index % NetProtocol.SNAPSHOT_EVERY_TICKS == 0:
			_send_snapshots()
		accumulator -= world.tick_dt
		ticks += 1
	if ticks == 5:
		accumulator = 0.0


func _poll_network() -> void:
	if enet == null:
		return
	while true:
		var event: Array = enet.service(0)
		var kind: int = event[0]
		if kind == ENetConnection.EVENT_NONE or kind == ENetConnection.EVENT_ERROR:
			break
		var peer: ENetPacketPeer = event[1]
		match kind:
			ENetConnection.EVENT_CONNECT:
				peers[peer] = {"char_id": -1, "name": "", "intent": SimIntent.new(), "intent_tick": -1000, "known": {}, "nodes": {}, "buildings": {}, "claims": {}, "self_hash": 0}
			ENetConnection.EVENT_DISCONNECT:
				_on_disconnect(peer)
			ENetConnection.EVENT_RECEIVE:
				var packet := peer.get_packet()
				bytes_in += packet.size()
				packets_in += 1
				_on_message(peer, NetProtocol.decode(packet))


func _on_message(peer: ENetPacketPeer, msg: Dictionary) -> void:
	if not peers.has(peer) or msg.is_empty():
		return
	var info: Dictionary = peers[peer]
	var c := world.get_character(int(info["char_id"]))
	match String(msg.get("t", "")):
		"join":
			_on_join(peer, String(msg.get("name", "")).strip_edges().substr(0, 24))
		"intent":
			if c != null:
				info["intent"] = NetProtocol.msg_to_intent(msg)
				info["intent_tick"] = tick_index
		"logout":
			if c != null and c.control == SimCharacter.Controller.PLAYER and not c.dead:
				var rules: Variant = msg.get("rules", [])
				var before := data.errors.size()
				var normalized := data.normalize_rule_list(rules, "Netz")
				var ok := data.errors.size() == before
				data.errors.resize(before)
				if not ok or normalized.is_empty():
					normalized = data.default_rules.duplicate(true)
				c.role_id = String(msg.get("role", ""))
				var role_name := String(data.roles.get(c.role_id, {}).get("name", "eigene Regeln"))
				world.logout(c.id, normalized, role_name)
		"login":
			if c != null and c.control == SimCharacter.Controller.RULES:
				world.login(c.id)
		"marker":
			if c != null and c.control == SimCharacter.Controller.PLAYER and not c.dead and c.markers.size() < 20:
				world.add_marker(c.id)
		"marker_rename":
			if c != null:
				world.rename_marker(c.id, String(msg.get("id", "")), String(msg.get("name", "")).substr(0, 24))
		"marker_remove":
			if c != null:
				world.remove_marker(c.id, String(msg.get("id", "")))
		"craft":
			if c != null and c.control == SimCharacter.Controller.PLAYER and not c.dead:
				var reason := world.craft(c, String(msg.get("item", "")))
				_send(peer, {"t": "info", "text": ("%s gebaut." % data.items[msg["item"]]["name"]) if reason.is_empty() else "Geht nicht: %s" % reason}, true)
		"repair":
			if c != null and c.control == SimCharacter.Controller.PLAYER and not c.dead:
				var item_id := String(msg.get("item", ""))
				var reason := world.repair(c, item_id)
				_send(peer, {"t": "info", "text": ("%s repariert." % data.items.get(item_id, {}).get("name", item_id)) if reason.is_empty() else "Geht nicht: %s" % reason}, true)
		"weapon":
			if c != null:
				world.set_active_weapon(c, String(msg.get("item", "")))
		"build":
			if c != null:
				var origin := Vector2i(int(msg.get("x", 0)), int(msg.get("y", 0)))
				var reason := world.can_place(c, String(msg.get("part", "")), origin, int(msg.get("rot", 0)))
				if reason.is_empty():
					world.place_building(c, String(msg["part"]), origin, int(msg.get("rot", 0)))
				else:
					_send(peer, {"t": "info", "text": "Bauen geht nicht: %s" % reason}, true)
		"demolish":
			if c != null:
				var b: SimBuilding = world.map.buildings.get(int(msg.get("id", -1)))
				if world.can_demolish(c, b):
					world.remove_building(b.id, c)
		"table_deposit", "table_withdraw", "table_offers", "table_buy":
			if c != null:
				var b: SimBuilding = world.map.buildings.get(int(msg.get("id", -1)))
				var reason := "kein Handelstisch"
				match String(msg["t"]):
					"table_deposit":
						reason = world.table_deposit(c, b, String(msg.get("res", "")), int(msg.get("amount", 0)))
					"table_withdraw":
						reason = world.table_withdraw(c, b, String(msg.get("res", "")), int(msg.get("amount", 0)))
					"table_offers":
						reason = world.table_set_offers(c, b, msg.get("offers", []))
					"table_buy":
						reason = world.table_buy(c, b, int(msg.get("index", -1)))
				if not reason.is_empty():
					_send(peer, {"t": "info", "text": "Handel: %s" % reason}, true)
		"sign_text":
			if c != null:
				var b: SimBuilding = world.map.buildings.get(int(msg.get("id", -1)))
				var reason := world.set_sign_text(c, b, String(msg.get("text", "")))
				if not reason.is_empty():
					_send(peer, {"t": "info", "text": "Schild: %s" % reason}, true)
		"chat":
			if c != null:
				_relay_chat(c, String(msg.get("text", "")).strip_edges().substr(0, CHAT_MAX_LENGTH), String(msg.get("scope", "near")))
		"claim_tile":
			if c != null:
				var tile := Vector2i(int(msg.get("x", 0)), int(msg.get("y", 0)))
				var reason := world.claims.claim_tile_reason(world, c, tile)
				if reason.is_empty():
					world.claims.claim_tile(world, c, tile)
				else:
					_send(peer, {"t": "info", "text": "Beanspruchen geht nicht: %s" % reason}, true)
		"release_tile":
			if c != null:
				world.claims.release_tile(world, c, Vector2i(int(msg.get("x", 0)), int(msg.get("y", 0))))
		"respawn":
			if c != null and c.dead:
				var fresh := world.spawn_player(world.spawn_point_for(c.owner_id), c.owner_id, c.name)
				info["char_id"] = fresh.id
				info["known"] = {}
				info["nodes"] = {}
				info["buildings"] = {}
				info["claims"] = {}
				info["self_hash"] = 0
				_send(peer, {"t": "welcome", "id": fresh.id}, true)


## Chat: nah = alle in CHAT_NEAR_RADIUS um den Sprecher (mit Name); global = alle, ohne Positionsdaten.
func _relay_chat(sender: SimCharacter, text: String, scope: String) -> void:
	if text.is_empty():
		return
	var global := scope == "global"
	var out := {"t": "chat", "from": sender.name, "text": text, "scope": "global" if global else "near"}
	for peer: ENetPacketPeer in peers:
		var info: Dictionary = peers[peer]
		var listener := world.get_character(int(info["char_id"]))
		if listener == null:
			continue
		if global or listener.pos.distance_to(sender.pos) <= CHAT_NEAR_RADIUS:
			_send(peer, out, true)


## Beitritt: bestehenden lebenden Charakter dieses Namens übernehmen (einloggen), sonst neu am Spawn.
func _on_join(peer: ENetPacketPeer, name: String) -> void:
	if name.is_empty():
		name = "Spieler"
	var info: Dictionary = peers[peer]
	info["name"] = name
	var existing: SimCharacter = null
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.PLAYER and c.owner_id == name and not c.dead:
			existing = c
			break
	var taken := false
	for other_info: Dictionary in peers.values():
		if existing != null and int(other_info["char_id"]) == existing.id and other_info != info:
			taken = true
	if existing != null and not taken:
		if existing.control == SimCharacter.Controller.RULES:
			world.login(existing.id)
		info["char_id"] = existing.id
	else:
		var fresh := world.spawn_player(world.spawn_point_for(name), name, name)
		info["char_id"] = fresh.id
	info["known"] = {}
	info["nodes"] = {}
	info["buildings"] = {}
	info["claims"] = {}
	info["self_hash"] = 0
	_send(peer, {"t": "welcome", "id": int(info["char_id"]), "time": world.time, "map": data.map_dict()}, true)


## Trennung: der Charakter wird zum NPC mit seinen aktuellen Regeln (Übergang läuft, kein sofortiger Schutz).
func _on_disconnect(peer: ENetPacketPeer) -> void:
	var info: Dictionary = peers.get(peer, {})
	peers.erase(peer)
	var c := world.get_character(int(info.get("char_id", -1)))
	if c != null and c.control == SimCharacter.Controller.PLAYER and not c.dead:
		var role_name := String(data.roles.get(c.role_id, {}).get("name", "Verbindung getrennt"))
		world.logout(c.id, c.rules, role_name)


func _send_snapshots() -> void:
	for peer: ENetPacketPeer in peers:
		var info: Dictionary = peers[peer]
		var char_id := int(info["char_id"])
		if char_id < 0:
			continue
		var snap := NetProtocol.snapshot(world, char_id, info["known"], info["nodes"], info["buildings"], info["claims"])
		if snap.is_empty():
			continue
		_send(peer, snap, false)
		# Eigene Details nur, wenn sich etwas geändert hat
		var block := NetProtocol.self_block(world.get_character(char_id))
		block["unlocks"] = world.unlocks_of(world.get_character(char_id).owner_id).duplicate()
		var h := block.hash()
		if h != int(info["self_hash"]):
			info["self_hash"] = h
			_send(peer, {"t": "self", "you": char_id, "self": block}, true)
	enet.flush()  # sofort rausschicken, nicht erst beim nächsten service()


func _send(peer: ENetPacketPeer, msg: Dictionary, reliable: bool) -> void:
	var bytes := NetProtocol.encode(msg)
	bytes_out += bytes.size()
	if reliable:
		peer.send(NetProtocol.CHANNEL_RELIABLE, bytes, ENetPacketPeer.FLAG_RELIABLE)
	else:
		peer.send(NetProtocol.CHANNEL_FAST, bytes, 0)


func connected_count() -> int:
	return peers.size()


## Statistik-Zeile und Zähler zurücksetzen.
func stats_line(interval_seconds: float) -> String:
	var avg := tick_ms_sum / maxf(1.0, ticks_measured)
	var npcs := 0
	var online := 0
	for c: SimCharacter in world.characters.values():
		if c.kind != SimCharacter.Kind.PLAYER or c.dead:
			continue
		if c.control == SimCharacter.Controller.RULES:
			npcs += 1
		elif c.control == SimCharacter.Controller.PLAYER:
			online += 1
	var line := "%s · Peers %d · online %d · NPCs %d · Wölfe %d · Tick Ø %.2f ms max %.2f ms · raus %.1f KB/s · rein %.1f KB/s (%d Pakete/s)" % [
		world.clock_string(), peers.size(), online, npcs, world.count_alive_wolves(), avg, tick_ms_max,
		bytes_out / 1024.0 / interval_seconds, bytes_in / 1024.0 / interval_seconds, int(packets_in / interval_seconds),
	]
	bytes_out = 0
	bytes_in = 0
	packets_in = 0
	tick_ms_sum = 0.0
	tick_ms_max = 0.0
	ticks_measured = 0
	return line
