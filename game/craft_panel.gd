extends CanvasLayer
## Werkbank: baut Ausrüstung aus Rohstoffen. Zeilen kommen aus data/items.json. Liest den Charakter,
## der Bau selbst läuft über das Signal in die Sim (main.gd -> SimWorld.craft).

signal craft_requested(item_id: String)
signal closed

var data: SimData
var character: SimCharacter

var _root: PanelContainer
var _rows: VBoxContainer
var _status: Label
var _buttons: Dictionary = {}  # item_id -> Button
var _info: Dictionary = {}     # item_id -> Label


func _ready() -> void:
	layer = 9
	visible = false
	_root = PanelContainer.new()
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -300
	_root.offset_right = 300
	_root.offset_top = -160
	_root.offset_bottom = 160
	add_child(_root)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_root.add_child(vbox)
	var title := Label.new()
	title.text = "Werkbank – Ausrüstung bauen (C schließt)"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	vbox.add_child(_rows)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	vbox.add_child(_status)
	var close := Button.new()
	close.text = "Schließen"
	close.pressed.connect(func() -> void: closed.emit())
	vbox.add_child(close)


func open(p_data: SimData, p_character: SimCharacter) -> void:
	data = p_data
	character = p_character
	_status.text = ""
	_build_rows()
	refresh()
	visible = true


func close() -> void:
	visible = false


func show_status(text: String) -> void:
	_status.text = text


func _build_rows() -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_buttons.clear()
	_info.clear()
	for item_id: String in data.item_order:
		var def: Dictionary = data.items[item_id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var name_label := Label.new()
		name_label.text = String(def["name"])
		name_label.custom_minimum_size = Vector2(110, 0)
		row.add_child(name_label)
		var info := Label.new()
		info.text = _describe(def)
		info.custom_minimum_size = Vector2(230, 0)
		row.add_child(info)
		_info[item_id] = info
		var cost := Label.new()
		cost.text = _cost_text(def)
		cost.custom_minimum_size = Vector2(120, 0)
		row.add_child(cost)
		var button := Button.new()
		button.text = "Bauen"
		button.pressed.connect(func() -> void: craft_requested.emit(item_id))
		row.add_child(button)
		_buttons[item_id] = button
		_rows.add_child(row)


func _describe(def: Dictionary) -> String:
	match String(def["kind"]):
		"weapon":
			if def.get("attack", "") == "ranged":
				return "Fernkampf: %d Schaden, %d Projektile" % [int(def["damage"]), int(def["max_projectiles"])]
			return "Nahkampf: %d Schaden, Reichweite %.1f" % [int(def["damage"]), float(def["range"])]
		"armor":
			return "Rüstung: −%d pro Treffer" % int(def["armor"])
	return ""


func _cost_text(def: Dictionary) -> String:
	var cost: Dictionary = def.get("cost", {})
	if cost.is_empty():
		return "nicht baubar"
	var parts: PackedStringArray = []
	for rid: String in cost:
		parts.append("%d %s" % [int(cost[rid]), data.resources[rid]["name"]])
	return ", ".join(parts)


## Aktualisiert Knöpfe: vorhanden, baubar oder zu teuer.
func refresh() -> void:
	if character == null:
		return
	for item_id: String in _buttons:
		var def: Dictionary = data.items[item_id]
		var button: Button = _buttons[item_id]
		if character.items.has(item_id):
			button.text = "vorhanden"
			button.disabled = true
			continue
		var cost: Dictionary = def.get("cost", {})
		var affordable := not cost.is_empty()
		for rid: String in cost:
			if int(character.inventory.get(rid, 0)) < int(cost[rid]):
				affordable = false
		button.text = "Bauen"
		button.disabled = not affordable
