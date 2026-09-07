class_name NetClient
extends RefCounted
## Netzwerk-Client: verbindet per ENet, sendet Absichten, empfängt Snapshots in eine Spiegelwelt (SimWorld ohne
## Tick), die die Darstellung wie die lokale Welt liest. Wird vom Spiel (main.gd) und von den Bots (tools/bot_clients.gd) genutzt.

var mirror: SimWorld
var my_id: int = -1
var connected: bool = false
var joined: bool = false
var player_name: String = ""
var last_snapshot_usec: int = 0
var snapshot_interval: float = 0.1
var messages: Array[Dictionary] = []   # zuverlässige Nachrichten des Servers (welcome, info), vom Aufrufer geleert

# Statistik
var bytes_in: int = 0
var snapshots_in: int = 0
var chars_in_last_snapshot: int = 0

var _enet: ENetConnection
var _peer: ENetPacketPeer


func connect_to(data: SimData, host: String, port: int, name: String) -> Error:
	player_name = name
	var own_data := SimData.load_from_dir("res://data")  # eigene Kopie: die Karte kommt vom Server
	if not own_data.is_valid():
		own_data = data
	mirror = SimWorld.new(own_data, 0)
	mirror.lod_enabled = false
	_enet = ENetConnection.new()
	var err := _enet.create_host(1, NetProtocol.CHANNELS)
	if err != OK:
		return err
	_peer = _enet.connect_to_host(host, port, NetProtocol.CHANNELS)
	if _peer == null:
		return ERR_CANT_CONNECT
	return OK


func disconnect_from_server() -> void:
	if _peer != null:
		_peer.peer_disconnect()
	if _enet != null:
		_enet.service(10)
		_enet.destroy()
	_enet = null
	_peer = null
	connected = false
	joined = false


## Ereignisse abholen. Snapshots landen in der Spiegelwelt, andere Nachrichten in `messages`.
func poll() -> void:
	if _enet == null:
		return
	while true:
		var event: Array = _enet.service(0)
		var kind: int = event[0]
		if kind == ENetConnection.EVENT_NONE or kind == ENetConnection.EVENT_ERROR:
			break
		match kind:
			ENetConnection.EVENT_CONNECT:
				connected = true
				send({"t": "join", "name": player_name}, true)
			ENetConnection.EVENT_DISCONNECT:
				connected = false
				joined = false
			ENetConnection.EVENT_RECEIVE:
				var packet: PackedByteArray = _peer.get_packet()
				bytes_in += packet.size()
				var msg := NetProtocol.decode(packet)
				match String(msg.get("t", "")):
					"snap":
						snapshots_in += 1
						chars_in_last_snapshot = msg.get("chars", []).size()
						var now := Time.get_ticks_usec()
						if last_snapshot_usec > 0:
							snapshot_interval = clampf((now - last_snapshot_usec) / 1_000_000.0, 0.02, 0.5)
						last_snapshot_usec = now
						NetProtocol.apply_snapshot(mirror, msg)
					"welcome":
						my_id = int(msg.get("id", -1))
						if msg.has("map") and mirror.data.apply_map(msg["map"]).is_empty():
							mirror.map = SimMap.new(mirror.data)
						joined = true
						messages.append(msg)
					"self":
						NetProtocol.apply_self(mirror, int(msg.get("you", my_id)), msg.get("self", {}))
					_:
						messages.append(msg)


func send(msg: Dictionary, reliable: bool) -> void:
	if _peer == null or not connected:
		return
	var bytes := NetProtocol.encode(msg)
	if reliable:
		_peer.send(NetProtocol.CHANNEL_RELIABLE, bytes, ENetPacketPeer.FLAG_RELIABLE)
	else:
		_peer.send(NetProtocol.CHANNEL_FAST, bytes, 0)
	_enet.flush()


func send_intent(intent: SimIntent) -> void:
	send(NetProtocol.intent_to_msg(intent), false)


func me() -> SimCharacter:
	return mirror.get_character(my_id) if mirror != null else null


## Interpolationsanteil zwischen dem vorletzten und dem letzten Snapshot.
func render_alpha() -> float:
	if last_snapshot_usec == 0:
		return 1.0
	return clampf((Time.get_ticks_usec() - last_snapshot_usec) / 1_000_000.0 / snapshot_interval, 0.0, 1.0)
