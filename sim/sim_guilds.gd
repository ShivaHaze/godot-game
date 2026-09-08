class_name SimGuilds
extends RefCounted
## Gilden: Gruppen von Besitzern (owner_id). Mitglieder sind Verbündete: sie bauen und sammeln auf den Claims
## der anderen, gehen durch deren Türen, teilen den Alarm der Sensoren und werden von Turrets und Fallen verschont.
## Unbegrenzte Größe, keine Verwaltung – Verrat bleibt möglich (Design). Zahlen in balance.json `guild`.

const NAME_MIN: int = 3
const NAME_MAX: int = 20

var guilds: Dictionary = {}     # id -> {"name": String, "leader": String, "members": Array[String]}
var member_of: Dictionary = {}  # owner_id -> guild id
var invites: Dictionary = {}    # owner_id -> guild id (offene Einladung)
var _next_id: int = 1


func guild_of(owner_id: String) -> int:
	return int(member_of.get(owner_id, -1))


func name_of(owner_id: String) -> String:
	var id := guild_of(owner_id)
	return String(guilds[id]["name"]) if id >= 0 else ""


func members_of(owner_id: String) -> Array[String]:
	var id := guild_of(owner_id)
	var result: Array[String] = []
	if id >= 0:
		result.assign(guilds[id]["members"])
	return result


## Offline-Leistung: Punkte der Gilde eines Besitzers erhöhen (nur Mitglieder).
func add_xp(owner_id: String, amount: int) -> void:
	var id := guild_of(owner_id)
	if id >= 0:
		guilds[id]["xp"] = int(guilds[id].get("xp", 0)) + amount


func xp_of(owner_id: String) -> int:
	var id := guild_of(owner_id)
	return int(guilds[id].get("xp", 0)) if id >= 0 else 0


## Gildenstufe (1 ohne Punkte); 0 = keine Gilde.
func level_of(owner_id: String, xp_per_level: int, max_level: int) -> int:
	var id := guild_of(owner_id)
	if id < 0:
		return 0
	return mini(max_level, 1 + int(guilds[id].get("xp", 0)) / maxi(1, xp_per_level))


## Verbündet: derselbe Besitzer oder dieselbe Gilde.
func allied(a: String, b: String) -> bool:
	if a == b:
		return true
	var ga := guild_of(a)
	return ga >= 0 and ga == guild_of(b)


func found(owner_id: String, name: String) -> String:
	if guild_of(owner_id) >= 0:
		return "du bist schon in einer Gilde"
	name = name.strip_edges()
	if name.length() < NAME_MIN or name.length() > NAME_MAX:
		return "Name braucht %d bis %d Zeichen" % [NAME_MIN, NAME_MAX]
	for g: Dictionary in guilds.values():
		if String(g["name"]).to_lower() == name.to_lower():
			return "den Namen gibt es schon"
	var id := _next_id
	_next_id += 1
	guilds[id] = {"name": name, "leader": owner_id, "members": [owner_id], "xp": 0}
	member_of[owner_id] = id
	invites.erase(owner_id)
	return ""


func invite(inviter: String, invitee: String) -> String:
	var id := guild_of(inviter)
	if id < 0:
		return "du bist in keiner Gilde"
	if invitee == inviter:
		return "dich selbst kannst du nicht einladen"
	if guild_of(invitee) >= 0:
		return "%s ist schon in einer Gilde" % invitee
	invites[invitee] = id
	return ""


func accept(owner_id: String) -> String:
	if not invites.has(owner_id):
		return "keine Einladung"
	if guild_of(owner_id) >= 0:
		return "du bist schon in einer Gilde"
	var id := int(invites[owner_id])
	invites.erase(owner_id)
	if not guilds.has(id):
		return "die Gilde gibt es nicht mehr"
	guilds[id]["members"].append(owner_id)
	member_of[owner_id] = id
	return ""


func leave(owner_id: String) -> String:
	var id := guild_of(owner_id)
	if id < 0:
		return "du bist in keiner Gilde"
	var g: Dictionary = guilds[id]
	g["members"].erase(owner_id)
	member_of.erase(owner_id)
	if g["members"].is_empty():
		guilds.erase(id)
	elif g["leader"] == owner_id:
		g["leader"] = g["members"][0]
	return ""


## Client-Spiegel: Mitgliedschaft aus Stammdaten übernehmen (Name reicht; leer = keine Gilde).
func register(owner_id: String, name: String) -> void:
	if name.is_empty():
		if guild_of(owner_id) >= 0:
			leave(owner_id)
		return
	if name_of(owner_id) == name:
		return
	if guild_of(owner_id) >= 0:
		leave(owner_id)
	for id: int in guilds:
		if String(guilds[id]["name"]) == name:
			guilds[id]["members"].append(owner_id)
			member_of[owner_id] = id
			return
	var id := _next_id
	_next_id += 1
	guilds[id] = {"name": name, "leader": owner_id, "members": [owner_id]}
	member_of[owner_id] = id


func to_dict() -> Dictionary:
	var list := []
	for id: int in guilds:
		var g: Dictionary = guilds[id]
		list.append({"id": id, "name": g["name"], "leader": g["leader"], "members": Array(g["members"]).duplicate(), "xp": int(g.get("xp", 0))})
	var open := {}
	for owner: String in invites:
		open[owner] = int(invites[owner])
	return {"guilds": list, "invites": open, "next_id": _next_id}


func load_dict(dict: Dictionary) -> void:
	guilds = {}
	member_of = {}
	invites = {}
	for entry: Dictionary in dict.get("guilds", []):
		var id := int(entry["id"])
		var members: Array = []
		for m: Variant in entry.get("members", []):
			members.append(String(m))
			member_of[String(m)] = id
		guilds[id] = {"name": String(entry["name"]), "leader": String(entry.get("leader", members[0] if not members.is_empty() else "")), "members": members, "xp": int(entry.get("xp", 0))}
	for owner: Variant in dict.get("invites", {}):
		invites[String(owner)] = int(dict["invites"][owner])
	_next_id = int(dict.get("next_id", 1))
	for id: int in guilds:
		_next_id = maxi(_next_id, id + 1)
