class_name SimClaims
extends RefCounted
## Land (Claims): Anker + zusammenhängende Kacheln, Unterhalt in Holz am Anker, Rechte, Verlust stufenweise.
## Design [E]: Anker nur live; Kacheln nur zusammenhängend vom Anker; Claims überlappen nie; Unterhalt
## überproportional und physisch am Anker; nur Eigentümer bauen; Rohstoffe nur für Eigentümer-NPCs, Fremde live =
## Diebstahl; fehlender Unterhalt lässt den Claim von außen schrumpfen; zerstörter Anker gibt nach Schonfrist frei.
## Reine Logik ohne Nodes; gehört zu SimWorld (world.claims).

var claims: Dictionary = {}          # id -> SimClaim
var tile_owner: Dictionary = {}      # Vector2i -> claim id
var _next_id: int = 1


# --- Abfragen -------------------------------------------------------------

func claim_at(tile: Vector2i) -> SimClaim:
	return claims.get(tile_owner.get(tile, -1))


func claim_at_pos(pos: Vector2) -> SimClaim:
	return claim_at(SimMap.cell_of(pos))


func claim_of_owner(owner_id: String) -> SimClaim:
	for claim: SimClaim in claims.values():
		if claim.owner_id == owner_id:
			return claim
	return null


## Ist die Kachel fremdes Land für diesen Besitzer?
func is_foreign(tile: Vector2i, owner_id: String) -> bool:
	var claim := claim_at(tile)
	return claim != null and claim.owner_id != owner_id


## Unterhalt je Stunde in Holz: base × n × (1 + n / growth) – überproportional.
static func upkeep_per_hour(data: SimData, tiles: int) -> float:
	return data.balf("claim.upkeep_base") * tiles * (1.0 + tiles / data.balf("claim.upkeep_growth"))


func hours_left(data: SimData, claim: SimClaim) -> float:
	var rate := upkeep_per_hour(data, claim.tiles.size())
	return INF if rate <= 0.0 else claim.stock / rate


# --- Anker ----------------------------------------------------------------

## Warum hier kein Anker stehen darf; leer = erlaubt. (Bauregeln prüft can_place, hier nur das Land.)
func anchor_reason(data: SimData, c: SimCharacter, tile: Vector2i) -> String:
	var own := claim_of_owner(c.owner_id)
	if own != null:
		if own.anchor_building_id >= 0:
			return "du hast schon einen Anker (Solo: einer)"
		if not own.tiles.has(tile):
			return "neu verankern nur auf dem eigenen Land (Schonfrist)"
		return ""
	if is_foreign(tile, c.owner_id):
		return "fremder Claim"
	var min_distance := data.balf("claim.min_anchor_distance")
	for claim: SimClaim in claims.values():
		if claim.owner_id != c.owner_id and claim.anchor_tile.distance_to(tile) < min_distance:
			return "zu nah an einem fremden Anker"
	return ""


## Neuer Anker: Claim mit der Ankerkachel als erster Kachel (oder Wiederaufbau in der Schonfrist).
func on_anchor_placed(world: SimWorld, b: SimBuilding) -> SimClaim:
	var tile := SimMap.cell_of(b.center())
	var existing := claim_of_owner(b.owner_id)
	if existing != null and existing.anchor_building_id < 0 and existing.tiles.has(tile):
		existing.anchor_building_id = b.id
		existing.anchor_tile = tile
		existing.grace_until = -1.0
		world.events.append({"type": "claim_restored", "claim": existing.id, "owner": b.owner_id})
		return existing
	var claim := SimClaim.new()
	claim.id = _next_id
	_next_id += 1
	claim.owner_id = b.owner_id
	claim.anchor_building_id = b.id
	claim.anchor_tile = tile
	claim.tiles[tile] = true
	claim.stock = 0.0
	claims[claim.id] = claim
	tile_owner[tile] = claim.id
	world.events.append({"type": "claim_created", "claim": claim.id, "owner": b.owner_id, "tile": tile})
	world.unlock(b.owner_id, "owned_anchor")
	return claim


## Anker weg (zerstört oder verfallen): Schonfrist beginnt; danach wird das Land frei.
func on_building_removed(world: SimWorld, building_id: int) -> void:
	for claim: SimClaim in claims.values():
		if claim.anchor_building_id == building_id:
			claim.anchor_building_id = -1
			claim.grace_until = world.time + world.data.balf("claim.grace_hours") * 3600.0
			world.events.append({"type": "claim_anchor_lost", "claim": claim.id, "owner": claim.owner_id})


# --- Kacheln --------------------------------------------------------------

## Warum die Kachel nicht beansprucht werden kann; leer = möglich.
func claim_tile_reason(world: SimWorld, c: SimCharacter, tile: Vector2i) -> String:
	var data := world.data
	var claim := claim_of_owner(c.owner_id)
	if claim == null or claim.anchor_building_id < 0:
		return "du brauchst einen stehenden Anker"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	if tile_owner.has(tile):
		return "schon beansprucht" if tile_owner[tile] == claim.id else "fremder Claim"
	if not world.map.in_bounds(tile) or world.map.tile_id(tile) == "obstacle":
		return "kein Land"
	if world.map.zone(tile) == "market":
		return "Marktland gehört niemandem"
	if claim.tiles.size() >= data.bali("claim.max_tiles_solo"):
		return "Obergrenze erreicht (%d Kacheln)" % data.bali("claim.max_tiles_solo")
	var adjacent := false
	for step: Vector2i in SimMap.NEIGHBORS_4:
		if claim.tiles.has(tile + step):
			adjacent = true
	if not adjacent:
		return "muss an den Claim angrenzen"
	if SimMap.cell_center(tile).distance_to(c.pos) > data.balf("building.reach"):
		return "zu weit weg"
	var cost := data.bali("claim.tile_cost_wood")
	if int(c.inventory.get("wood", 0)) < cost:
		return "zu wenig Holz (%d nötig)" % cost
	return ""


func claim_tile(world: SimWorld, c: SimCharacter, tile: Vector2i) -> bool:
	if not claim_tile_reason(world, c, tile).is_empty():
		return false
	var claim := claim_of_owner(c.owner_id)
	c.inventory["wood"] = int(c.inventory["wood"]) - world.data.bali("claim.tile_cost_wood")
	claim.tiles[tile] = true
	tile_owner[tile] = claim.id
	world.events.append({"type": "claim_tile", "claim": claim.id, "id": c.id, "tile": tile})
	return true


## Eigene Kachel aufgeben (nicht die Ankerkachel). Ohne Rückgabe.
func release_tile(world: SimWorld, c: SimCharacter, tile: Vector2i) -> bool:
	var claim := claim_at(tile)
	if claim == null or claim.owner_id != c.owner_id or tile == claim.anchor_tile:
		return false
	_drop_tile(world, claim, tile)
	return true


func _drop_tile(world: SimWorld, claim: SimClaim, tile: Vector2i) -> void:
	claim.tiles.erase(tile)
	tile_owner.erase(tile)
	world.events.append({"type": "claim_tile_lost", "claim": claim.id, "tile": tile})


# --- Unterhalt ------------------------------------------------------------

## Holz am Anker abliefern. Rückgabe: abgeliefertes Holz.
func deposit(world: SimWorld, c: SimCharacter, claim: SimClaim, amount: int) -> int:
	if claim == null or claim.anchor_building_id < 0 or amount <= 0:
		return 0
	var room := int(floorf(world.data.balf("claim.stock_capacity") - claim.stock))
	var moved := mini(mini(amount, int(c.inventory.get("wood", 0))), room)
	if moved <= 0:
		return 0
	c.inventory["wood"] = int(c.inventory["wood"]) - moved
	claim.stock += moved
	world.events.append({"type": "deposit", "claim": claim.id, "id": c.id, "amount": moved, "stock": claim.stock})
	return moved


## Unterhalt abziehen; ohne Vorrat schrumpft der Claim von außen; nach der Schonfrist ohne Anker wird er frei.
func update(world: SimWorld, dt: float) -> void:
	if claims.is_empty():
		return
	var data := world.data
	for id: int in claims.keys():
		var claim: SimClaim = claims[id]
		if claim.anchor_building_id < 0:
			if world.time >= claim.grace_until:
				_dissolve(world, claim, "Schonfrist abgelaufen")
			continue
		var rate := upkeep_per_hour(data, claim.tiles.size()) / 3600.0
		claim.stock = maxf(0.0, claim.stock - rate * dt)
		if claim.stock > 0.0:
			claim.starving_since = -1.0
			continue
		if claim.starving_since < 0.0:
			claim.starving_since = world.time
			world.events.append({"type": "claim_starving", "claim": claim.id, "owner": claim.owner_id})
		var interval := data.balf("claim.shrink_interval_hours") * 3600.0
		while world.time - claim.starving_since >= interval and claim.tiles.size() > 1:
			claim.starving_since += interval
			_drop_tile(world, claim, _farthest_tile(claim))
			world.events.append({"type": "claim_shrink", "claim": claim.id, "owner": claim.owner_id, "tiles": claim.tiles.size()})


func _farthest_tile(claim: SimClaim) -> Vector2i:
	var best := claim.anchor_tile
	var best_d := -1.0
	for tile: Vector2i in claim.tiles:
		if tile == claim.anchor_tile:
			continue
		var d := Vector2(tile).distance_squared_to(Vector2(claim.anchor_tile))
		if d > best_d:
			best_d = d
			best = tile
	return best


func _dissolve(world: SimWorld, claim: SimClaim, reason: String) -> void:
	for tile: Vector2i in claim.tiles.keys():
		tile_owner.erase(tile)
	claims.erase(claim.id)
	world.events.append({"type": "claim_dissolved", "claim": claim.id, "owner": claim.owner_id, "reason": reason})


# --- Serialisierung -------------------------------------------------------

func to_list() -> Array:
	var result := []
	for claim: SimClaim in claims.values():
		var tiles := PackedInt32Array()
		for tile: Vector2i in claim.tiles:
			tiles.append_array(PackedInt32Array([tile.x, tile.y]))
		result.append({
			"id": claim.id, "owner": claim.owner_id, "anchor_building": claim.anchor_building_id,
			"anchor_tile": [claim.anchor_tile.x, claim.anchor_tile.y], "tiles": tiles, "stock": claim.stock,
			"starving_since": claim.starving_since, "grace_until": claim.grace_until,
		})
	return result


func load_list(list: Array, next_id: int) -> void:
	claims.clear()
	tile_owner.clear()
	_next_id = next_id
	for entry: Dictionary in list:
		var claim := SimClaim.new()
		claim.id = int(entry["id"])
		claim.owner_id = String(entry["owner"])
		claim.anchor_building_id = int(entry["anchor_building"])
		claim.anchor_tile = Vector2i(int(entry["anchor_tile"][0]), int(entry["anchor_tile"][1]))
		claim.stock = float(entry.get("stock", 0.0))
		claim.starving_since = float(entry.get("starving_since", -1.0))
		claim.grace_until = float(entry.get("grace_until", -1.0))
		var tiles: PackedInt32Array = entry["tiles"]
		for i in range(0, tiles.size() - 1, 2):
			var tile := Vector2i(tiles[i], tiles[i + 1])
			claim.tiles[tile] = true
			tile_owner[tile] = claim.id
		claims[claim.id] = claim
		_next_id = maxi(_next_id, claim.id + 1)


func next_id() -> int:
	return _next_id
