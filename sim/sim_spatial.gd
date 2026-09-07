class_name SimSpatial
extends RefCounted
## Räumliches Raster für schnelle Nachbarschaftsabfragen (statt O(n²) über alle Charaktere).
## Wird pro Tick neu gefüllt (O(n)); Abfragen prüfen nur die Rasterzellen im Radius und liefern Kandidaten,
## deren genaue Distanz der Aufrufer selbst prüft. Tote Charaktere sind nicht enthalten.

var cell_size: float = 4.0
var _buckets: Dictionary = {}  # Vector2i -> Array (SimCharacter)


func _init(p_cell_size: float = 4.0) -> void:
	cell_size = p_cell_size


func rebuild(characters: Dictionary) -> void:
	_buckets.clear()
	for c: SimCharacter in characters.values():
		if c.dead:
			continue
		var key := _key(c.pos)
		if not _buckets.has(key):
			_buckets[key] = []
		_buckets[key].append(c)


## Kandidaten innerhalb radius um pos (plus Rasterrand). Distanz selbst prüfen.
func query(pos: Vector2, radius: float) -> Array:
	var result := []
	var min_key := _key(pos - Vector2(radius, radius))
	var max_key := _key(pos + Vector2(radius, radius))
	for y in range(min_key.y, max_key.y + 1):
		for x in range(min_key.x, max_key.x + 1):
			var bucket: Variant = _buckets.get(Vector2i(x, y))
			if bucket != null:
				result.append_array(bucket)
	return result


func _key(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / cell_size), floori(pos.y / cell_size))
