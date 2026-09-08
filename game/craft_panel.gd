extends CanvasLayer
## Herstellen: baut Ausrüstung und Verbrauchsgüter aus Rohstoffen, gruppiert nach Station (von Hand, Werkbank,
## Schmelzofen, Schmiede, Lagerfeuer). Zeilen kommen aus items.json/resources.json. Liest den Charakter,
## der Bau selbst läuft über das Signal in die Sim (main.gd -> SimWorld.craft). Rüstung wird hier an- und abgelegt.

signal craft_requested(item_id: String)
signal repair_requested(item_id: String)
signal equip_requested(item_id: String)   # leer = Rüstung ablegen
signal closed

var data: SimData
var character: SimCharacter
var world: SimWorld

var _root: PanelContainer
var _rows: VBoxContainer
var _status: Label
var _buttons: Dictionary = {}  # item_id -> Button
var _info: Dictionary = {}     # item_id -> Label
var _repair: Dictionary = {}   # item_id -> Button
var _equip: Dictionary = {}    # item_id -> Button (nur Rüstung)


func _ready() -> void:
	layer = 9
	visible = false
	_root = PanelContainer.new()
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -440
	_root.offset_right = 440
	_root.offset_top = -200
	_root.offset_bottom = 340
	add_child(_root)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_root.add_child(vbox)
	var title := Label.new()
	title.text = "Herstellen (C schließt) – Werkbank, Schmelzofen und Schmiede sind Bauteile"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 470)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	vbox.add_child(_status)
	var close := Button.new()
	close.text = "Schließen"
	close.pressed.connect(func() -> void: closed.emit())
	vbox.add_child(close)


func open(p_data: SimData, p_character: SimCharacter, p_world: SimWorld = null) -> void:
	data = p_data
	character = p_character
	world = p_world
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
	_repair.clear()
	_equip.clear()
	var all_ids: Array[String] = []
	all_ids.assign(data.item_order)
	all_ids.append_array(data.craftable_resources())
	# Nach Station gruppiert: von Hand zuerst, dann Werkbank, Schmelzofen, Schmiede, Lagerfeuer (Reihenfolge aus buildings.json)
	var groups: Dictionary = {"": []}
	for station: String in data.building_order:
		groups[station] = []
	for item_id: String in all_ids:
		var station := data.station_of(item_id)
		if not groups.has(station):
			groups[station] = []
		groups[station].append(item_id)
	for station: String in groups:
		if groups[station].is_empty():
			continue
		var header := Label.new()
		header.text = "Von Hand (überall)" if station.is_empty() else "%s in Reichweite (Bauteil, B)" % data.buildings[station]["name"]
		header.add_theme_font_size_override("font_size", 15)
		header.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0))
		_rows.add_child(header)
		for item_id: String in groups[station]:
			_rows.add_child(_make_row(item_id))


func _make_row(item_id: String) -> HBoxContainer:
	var def: Dictionary = data.items[item_id] if data.items.has(item_id) else data.resources[item_id]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var name_label := Label.new()
	name_label.text = String(def["name"])
	name_label.custom_minimum_size = Vector2(110, 0)
	row.add_child(name_label)
	var info := Label.new()
	info.text = _describe(def)
	info.custom_minimum_size = Vector2(330, 0)
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
	if data.items.has(item_id):
		var repair := Button.new()
		repair.text = "Reparieren"
		repair.pressed.connect(func() -> void: repair_requested.emit(item_id))
		row.add_child(repair)
		_repair[item_id] = repair
		if String(def.get("kind", "")) == "armor":
			var equip := Button.new()
			equip.text = "Anlegen"
			equip.pressed.connect(func() -> void: equip_requested.emit("" if character.worn_armor == item_id else item_id))
			row.add_child(equip)
			_equip[item_id] = equip
	return row


func _describe(def: Dictionary) -> String:
	if def.has("heal"):
		var cures: Array = def.get("cures", [])
		var cure_text := ""
		if cures.has("poison"):
			cure_text = ", heilt Vergiftung"
		elif cures.has("sick"):
			cure_text = ", stoppt Blutung und Krankheit"
		elif cures.has("bleeding"):
			cure_text = ", stoppt Blutung"
		return "Verbrauchsgut: +%d Leben nach %.0f s (H)%s" % [int(def["heal"]), float(def["heal_time"]), cure_text]
	if def.has("cost") and not def.has("kind"):
		return "Verbrauchsgut, %d Stück je Herstellung" % int(def.get("yield", 1))
	match String(def.get("kind", "")):
		"weapon":
			if def.get("attack", "") == "ranged":
				var ammo := String(def.get("ammo", ""))
				return "Fernkampf: %d Schaden, %d Projektile%s" % [int(def["damage"]), int(def["max_projectiles"]), (", braucht %s" % data.resources[ammo]["name"]) if not ammo.is_empty() else ""]
			return "Nahkampf: %d Schaden, Reichweite %.1f" % [int(def["damage"]), float(def["range"])]
		"armor":
			return "Rüstung: −%d pro Treffer%s" % [int(def["armor"]), (", schwer: −%d %% Tempo" % int(roundf(float(def["slow"]) * 100.0))) if def.has("slow") else ""]
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
		var def: Dictionary = data.items[item_id] if data.items.has(item_id) else data.resources[item_id]
		var button: Button = _buttons[item_id]
		if _repair.has(item_id):
			var repair: Button = _repair[item_id]
			repair.visible = character.items.has(item_id)
			if world != null and character.items.has(item_id):
				var reason := SimCrafting.repair_reason(world, character, item_id)
				var cost_parts: PackedStringArray = []
				for rid: String in SimCrafting.repair_cost(world, item_id):
					cost_parts.append("%d %s" % [int(SimCrafting.repair_cost(world, item_id)[rid]), data.resources[rid]["name"]])
				repair.text = "Reparieren (%s)" % ", ".join(cost_parts)
				repair.disabled = not reason.is_empty()
				repair.tooltip_text = reason
				_info[item_id].text = _describe(def) + " · Zustand %d/%d" % [int(ceilf(SimCrafting.durability_left(world, character, item_id))), int(SimCrafting.durability_max(world, character, item_id))]
		if _equip.has(item_id):
			var equip: Button = _equip[item_id]
			equip.visible = character.items.has(item_id)
			equip.text = "Ablegen" if character.worn_armor == item_id else "Anlegen"
		if data.items.has(item_id) and character.items.has(item_id):
			button.text = "getragen" if character.worn_armor == item_id else "vorhanden"
			button.disabled = true
			continue
		if not data.items.has(item_id):
			_info[item_id].text = _describe(def) + " · du hast %d" % int(character.inventory.get(item_id, 0))
		var cost: Dictionary = def.get("cost", {})
		var affordable := not cost.is_empty()
		for rid: String in cost:
			if int(character.inventory.get(rid, 0)) < int(cost[rid]):
				affordable = false
		var station_missing := world != null and not SimCrafting.station_reason(world, character, item_id).is_empty()
		button.text = "Bauen"
		button.disabled = not affordable or station_missing
		button.tooltip_text = SimCrafting.station_reason(world, character, item_id) if station_missing else ""
