extends Node2D
## Zeichnet den Sim-Zustand als Rechtecke, Linien und Labels. Liest nur, verändert nie.
## Weltkoordinaten der Sim (Kacheln) × TILE = Pixel.

const TILE: float = 32.0

var world: SimWorld
var alpha: float = 0.0             # Anteil zwischen letztem und aktuellem Tick (weiche Bewegung)
var viewer_owner: String = "p1"    # Versteckte Charaktere anderer Besitzer werden nicht gezeichnet
var show_leashes: bool = true
var preview_rules: Array = []      # Regeln aus dem offenen Ausloggen-Menü (Leinen-Vorschau); leer = keine Vorschau
var trail_character_id: int = -1   # Chronik-Spur dieses Charakters zeichnen (Orte der Einträge, nummeriert)
var ghost: Dictionary = {}          # Bau-Vorschau: {"cells": Array[Vector2i], "valid": bool}

var _building_colors: Dictionary = {}

var _tile_colors: Dictionary = {}
var _resource_colors: Dictionary = {}


func _draw() -> void:
	if world == null:
		return
	_draw_tiles()
	_draw_claims()
	_draw_buildings()
	_draw_trail()
	_draw_markers()
	_draw_characters()
	_draw_ghost()
	_draw_projectiles()
	_draw_events()


static func to_pixels(pos: Vector2) -> Vector2:
	return pos * TILE


func mouse_world_pos() -> Vector2:
	return get_global_mouse_position() / TILE


func _tile_color(tile_id: String) -> Color:
	if not _tile_colors.has(tile_id):
		_tile_colors[tile_id] = Color.html(String(world.data.tiles[tile_id].get("color", "#ff00ff")))
	return _tile_colors[tile_id]


func _resource_color(resource_id: String) -> Color:
	if not _resource_colors.has(resource_id):
		_resource_colors[resource_id] = Color.html(String(world.data.resources[resource_id].get("color", "#ff00ff")))
	return _resource_colors[resource_id]


func _draw_tiles() -> void:
	var map := world.map
	for y in map.height:
		for x in map.width:
			var cell := Vector2i(x, y)
			draw_rect(Rect2(x * TILE, y * TILE, TILE, TILE), _tile_color(map.tile_id(cell)))
			var node := map.node_at(cell)
			if node != null and node.amount > 0:
				# Vorrat als innerer Block: schrumpft mit dem Vorrat
				var frac := float(node.amount) / float(node.max_amount)
				var size := TILE * 0.7 * frac
				var center := SimMap.cell_center(cell) * TILE
				draw_rect(Rect2(center - Vector2(size, size) * 0.5, Vector2(size, size)), _resource_color(node.resource))


func _draw_markers() -> void:
	for c: SimCharacter in world.characters.values():
		if c.kind != SimCharacter.Kind.PLAYER or c.owner_id != viewer_owner:
			continue
		for marker: Dictionary in c.markers:
			var p: Vector2 = marker["pos"] * TILE
			draw_circle(p, 5.0, Color(1.0, 0.85, 0.2))
			draw_string(ThemeDB.fallback_font, p + Vector2(8, 4), String(marker["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.85, 0.2))
		if c.control == SimCharacter.Controller.RULES:
			var here: Vector2 = c.logout_pos * TILE
			draw_circle(here, 4.0, Color(0.6, 0.8, 1.0))
			draw_string(ThemeDB.fallback_font, here + Vector2(8, 4), "Hier", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.8, 1.0))
		# Leinen: beim NPC immer, beim Live-Spieler nur als Vorschau, solange das Ausloggen-Menü offen ist
		if show_leashes and (c.control == SimCharacter.Controller.RULES or not preview_rules.is_empty()):
			_draw_leashes(c)


## Leinen: ein Kreis pro Ortsregel um den jeweiligen Ort; die aktive Leine des NPC kräftiger.
## Live (oder im Menü) ist "Hier" die aktuelle Position, als NPC die Ausloggen-Position.
func _draw_leashes(c: SimCharacter) -> void:
	var rules: Array = preview_rules if not preview_rules.is_empty() else c.rules
	var here := c.pos if c.control == SimCharacter.Controller.PLAYER else c.logout_pos
	for rule: Dictionary in rules:
		var params: Dictionary = rule["then"]["params"]
		if not params.has("place") or not params.has("radius"):
			continue
		var place := String(params["place"])
		var center: Vector2 = (here if place == SimData.PLACE_HERE else c.place_pos(place)) * TILE
		draw_arc(center, float(params["radius"]) * TILE, 0.0, TAU, 64, Color(1.0, 0.85, 0.2, 0.35), 1.0)
	if c.control == SimCharacter.Controller.RULES and c.leash_radius > 0.0:
		draw_arc(c.leash_center * TILE, c.leash_radius * TILE, 0.0, TAU, 64, Color(0.4, 0.7, 1.0, 0.8), 2.0)


## Claims: eigene Kacheln grünlich, fremde rötlich; Ankerkachel mit Rahmen.
func _draw_claims() -> void:
	for claim: SimClaim in world.claims.claims.values():
		var own := claim.owner_id == viewer_owner
		var color := Color(0.3, 0.9, 0.4, 0.16) if own else Color(0.95, 0.35, 0.3, 0.16)
		if claim.anchor_building_id < 0:
			color.a = 0.08  # Schonfrist: verblasst
		for tile: Vector2i in claim.tiles:
			draw_rect(Rect2(tile.x * TILE, tile.y * TILE, TILE, TILE), color)
		draw_rect(Rect2(claim.anchor_tile.x * TILE, claim.anchor_tile.y * TILE, TILE, TILE), Color(color.r, color.g, color.b, 0.8), false, 2.0)


func _building_color(part: String) -> Color:
	if not _building_colors.has(part):
		_building_colors[part] = Color.html(String(world.data.buildings.get(part, {}).get("color", "#ff00ff")))
	return _building_colors[part]


## Bauteile: jede Halbzelle ein Rechteck; beschädigte Teile werden dunkler und zeigen einen Balken.
func _draw_buildings() -> void:
	var half := TILE * 0.5
	for b: SimBuilding in world.map.buildings.values():
		if not world.building_visible_to(b, viewer_owner):
			continue
		var color := _building_color(b.part)
		var frac := b.hp / maxf(1.0, b.max_hp)
		var def: Dictionary = world.data.buildings.get(b.part, {})
		if def.has("sensor_radius") and b.owner_id == viewer_owner:
			var triggered := world.time < b.triggered_until
			draw_arc(b.center() * TILE, float(def["sensor_radius"]) * TILE, 0.0, TAU, 48, Color(1.0, 0.3, 0.3, 0.6) if triggered else Color(0.3, 0.8, 1.0, 0.25), 1.0)
			draw_string(ThemeDB.fallback_font, b.center() * TILE + Vector2(8, -6), b.label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.9, 1.0))
		color = color.darkened((1.0 - frac) * 0.5)
		for cell: Vector2i in b.cells:
			draw_rect(Rect2(cell.x * half, cell.y * half, half, half), color)
			draw_rect(Rect2(cell.x * half, cell.y * half, half, half), Color(0, 0, 0, 0.35), false, 1.0)
		if frac < 0.999:
			var c := b.center() * TILE
			draw_rect(Rect2(c.x - 10, c.y - 3, 20, 4), Color(0, 0, 0, 0.6))
			draw_rect(Rect2(c.x - 10, c.y - 3, 20 * frac, 4), Color(0.9, 0.7, 0.2))


func _draw_ghost() -> void:
	if ghost.is_empty():
		return
	var half := TILE * 0.5
	var color := Color(0.3, 1.0, 0.3, 0.45) if ghost.get("valid", false) else Color(1.0, 0.3, 0.3, 0.45)
	for cell: Vector2i in ghost.get("cells", []):
		draw_rect(Rect2(cell.x * half, cell.y * half, half, half), color)


## Chronik-Spur: nummerierte Punkte an den Orten der Einträge, verbunden in Reihenfolge.
func _draw_trail() -> void:
	var c := world.get_character(trail_character_id)
	if c == null or c.chronicle.is_empty():
		return
	var previous := Vector2.INF
	for i in c.chronicle.size():
		var entry: Dictionary = c.chronicle[i]
		if not entry.has("pos"):
			continue
		var p: Vector2 = entry["pos"] * TILE
		if previous != Vector2.INF and previous.distance_to(p) > 1.0:
			draw_line(previous, p, Color(1.0, 0.6, 0.2, 0.5), 1.5)
		previous = p
	var drawn := {}
	for i in c.chronicle.size():
		var entry: Dictionary = c.chronicle[i]
		if not entry.has("pos"):
			continue
		var cell := SimMap.cell_of(entry["pos"])
		var stack: int = drawn.get(cell, 0)
		drawn[cell] = stack + 1
		var p: Vector2 = entry["pos"] * TILE + Vector2(0, -12.0 * stack)
		draw_circle(p, 7.0, Color(1.0, 0.6, 0.2, 0.9))
		draw_string(ThemeDB.fallback_font, p + Vector2(-4 if i < 9 else -7, 4), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.BLACK)


func _character_color(c: SimCharacter) -> Color:
	if c.kind == SimCharacter.Kind.WOLF:
		return Color(0.8, 0.3, 0.2)
	match c.control:
		SimCharacter.Controller.PLAYER:
			return Color(0.95, 0.95, 0.95)
		SimCharacter.Controller.RULES:
			return Color(0.35, 0.6, 1.0)
	return Color(0.5, 0.5, 0.5)


func _draw_characters() -> void:
	for c: SimCharacter in world.characters.values():
		var p := c.render_pos(alpha) * TILE
		var size := TILE * 0.7
		var top_left := p - Vector2(size, size) * 0.5
		if c.dead:
			draw_rect(Rect2(top_left, Vector2(size, size)), Color(0.25, 0.25, 0.25))
			draw_line(top_left, top_left + Vector2(size, size), Color(0.6, 0.1, 0.1), 2.0)
			draw_line(top_left + Vector2(size, 0), top_left + Vector2(0, size), Color(0.6, 0.1, 0.1), 2.0)
			draw_string(ThemeDB.fallback_font, top_left + Vector2(0, size + 12), c.name + " (tot)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.7, 0.7))
			continue
		if c.hidden and c.owner_id != viewer_owner:
			continue
		var color := _character_color(c)
		if c.hidden:
			color.a = 0.35
		draw_rect(Rect2(top_left, Vector2(size, size)), color)
		draw_line(p, p + c.facing * TILE * 0.6, Color(1, 1, 1, 0.9), 2.0)
		# Lebensbalken
		draw_rect(Rect2(top_left.x, top_left.y - 7, size, 4), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(top_left.x, top_left.y - 7, size * c.hp / c.max_hp, 4), Color(0.2, 0.9, 0.2))
		# Sammelfortschritt
		if c.gather_progress > 0.0:
			var frac := c.gather_progress / world.data.balf("gathering.gather_time")
			draw_rect(Rect2(top_left.x, top_left.y + size + 2, size * frac, 3), Color(1.0, 0.85, 0.2))
		# Verband anlegen (Kanalisierung)
		if c.heal_progress > 0.0:
			draw_rect(Rect2(top_left.x, top_left.y + size + 6, size * minf(1.0, c.heal_progress / 3.0), 3), Color(0.9, 0.95, 1.0))
		var label := c.name
		if c.is_weakened():
			label += " (geschwächt)"
		if c.hidden:
			label += " (versteckt)"
		draw_string(ThemeDB.fallback_font, top_left + Vector2(0, size + 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)


func _draw_projectiles() -> void:
	for p: SimProjectile in world.projectiles:
		var pos := p.prev_pos.lerp(p.pos, alpha) * TILE
		draw_rect(Rect2(pos - Vector2(4, 4), Vector2(8, 8)), Color(1.0, 0.95, 0.5))


func _draw_events() -> void:
	for event: Dictionary in world.events:
		if event.get("type") == "hit":
			var pos: Vector2 = event["pos"] * TILE
			draw_arc(pos, TILE * 0.5, 0.0, TAU, 16, Color(1.0, 0.3, 0.2), 3.0)
