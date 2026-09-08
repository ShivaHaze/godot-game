extends CanvasLayer
## Markt-Depot-Tafel: eigene Waren einlagern (Gebühr) und gebührenfrei holen. Änderungen laufen
## über Signale in die Sim (lokal) oder als Nachricht an den Server (online).

signal deposit_requested(building_id: int, resource: String, amount: int)
signal withdraw_requested(building_id: int, resource: String, amount: int)
signal closed

var data: SimData
var world: SimWorld
var viewer: SimCharacter
var building: SimBuilding

var _root: PanelContainer
var _title: Label
var _rows: VBoxContainer
var _status: Label


func _ready() -> void:
	layer = 9
	visible = false
	_root = PanelContainer.new()
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -380
	_root.offset_right = 380
	_root.offset_top = -200
	_root.offset_bottom = 200
	add_child(_root)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_root.add_child(vbox)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_title)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	vbox.add_child(_rows)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)
	var close := Button.new()
	close.text = "Schließen (E)"
	close.pressed.connect(func() -> void: closed.emit())
	vbox.add_child(close)


func open(p_data: SimData, p_world: SimWorld, p_viewer: SimCharacter, p_building: SimBuilding) -> void:
	data = p_data
	world = p_world
	viewer = p_viewer
	building = p_building
	_status.text = ""
	rebuild()
	visible = true


func close() -> void:
	visible = false


func show_status(text: String) -> void:
	_status.text = text


func rebuild() -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if building == null or viewer == null:
		return
	var zone := world.zone_at(building.center())
	var fee := int(roundf(SimTrade.depot_fee_of(world, building) * 100.0))
	_title.text = "%s – %s. Einlagern kostet %d %% Gebühr, holen ist frei%s. Bestand %d/%d." % [
		building.label, zone.get("name", "Depot"), fee, "" if zone.get("raid_goods", false) else ", Raidwaren nicht", SimTrade.depot_stock_count(world, building, viewer.owner_id), data.bali("market.depot_capacity")]
	var stock := SimTrade.depot_stock(world, building, viewer.owner_id)
	for rid: String in data.resource_order:
		var have := int(viewer.inventory.get(rid, 0))
		var stored := int(stock.get(rid, 0))
		if have <= 0 and stored <= 0:
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = "%s: dabei %d · im Depot %d" % [data.resources[rid]["name"], have, stored]
		label.custom_minimum_size = Vector2(300, 0)
		row.add_child(label)
		row.add_child(_button("5 einlagern", have >= 5, func() -> void: deposit_requested.emit(building.id, rid, 5)))
		row.add_child(_button("alles einlagern", have > 0, func() -> void: deposit_requested.emit(building.id, rid, have)))
		row.add_child(_button("5 holen", stored >= 5, func() -> void: withdraw_requested.emit(building.id, rid, 5)))
		row.add_child(_button("alles holen", stored > 0, func() -> void: withdraw_requested.emit(building.id, rid, stored)))
		_rows.add_child(row)
	if _rows.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "Nichts dabei und nichts im Depot."
		_rows.add_child(empty)


func _button(text: String, enabled: bool, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.disabled = not enabled
	button.pressed.connect(callback)
	return button
