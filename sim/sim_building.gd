class_name SimBuilding
extends RefCounted
## Ein gebautes Teil (Wand, Tür …) auf dem Halbkachelraster. Halbzelle (hx, hy) deckt
## [hx/2, (hx+1)/2) × [hy/2, (hy+1)/2) in Kacheleinheiten ab.

var id: int = 0
var part: String = ""             # Kennung aus buildings.json
var owner_id: String = ""
var origin: Vector2i = Vector2i.ZERO   # obere linke Halbzelle
var rotation: int = 0             # 0 = wie definiert, 1 = um 90° gedreht
var hp: float = 0.0
var max_hp: float = 0.0
var placed_time: float = 0.0
var cells: Array[Vector2i] = []   # belegte Halbzellen
var contents: Dictionary = {}     # Handelstisch: Rohstoff -> Anzahl
var offers: Array = []            # Handelstisch: [{sell, sell_amount, price, price_amount}]


func contents_count() -> int:
	var total := 0
	for amount: int in contents.values():
		total += amount
	return total


## Halbzellen für ein Teil an einem Ursprung mit Drehung.
static func cells_for(size: Array, origin: Vector2i, rotation: int) -> Array[Vector2i]:
	var w := int(size[0])
	var h := int(size[1])
	if rotation % 2 == 1:
		var t := w
		w = h
		h = t
	var result: Array[Vector2i] = []
	for dy in h:
		for dx in w:
			result.append(origin + Vector2i(dx, dy))
	return result


static func half_cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x * 2.0), floori(pos.y * 2.0))


static func half_cell_center(half: Vector2i) -> Vector2:
	return Vector2(half.x * 0.5 + 0.25, half.y * 0.5 + 0.25)


func center() -> Vector2:
	var sum := Vector2.ZERO
	for half: Vector2i in cells:
		sum += half_cell_center(half)
	return sum / maxf(1.0, cells.size())
