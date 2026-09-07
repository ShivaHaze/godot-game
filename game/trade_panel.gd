extends CanvasLayer
## Handelstisch-Tafel. Besitzer: Waren einlagern/entnehmen und bis zu drei Angebote setzen.
## Fremde: Angebote sehen und kaufen. Änderungen laufen über Signale in die Sim (lokal) oder als Nachricht (online).

signal deposit_requested(building_id: int, resource: String, amount: int)
signal withdraw_requested(building_id: int, resource: String, amount: int)
signal offers_requested(building_id: int, offers: Array)
signal buy_requested(building_id: int, index: int)
signal closed

var data: SimData
var world: SimWorld
var viewer: SimCharacter
var building: SimBuilding
var is_owner: bool = false

var _root: PanelContainer
var _title: Label
var _stock: VBoxContainer
var _offers: VBoxContainer
var _status: Label
var _offer_rows: Array = []   # [{sell: OptionButton, sell_amount: SpinBox, price: OptionButton, price_amount: SpinBox}]


func _ready() -> void:
	layer = 9
	visible = false
	_root = PanelContainer.new()
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -360
	_root.offset_right = 360
	_root.offset_top = -220
	_root.offset_bottom = 220
	add_child(_root)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_root.add_child(vbox)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_title)
	_stock = VBoxContainer.new()
	vbox.add_child(_stock)
	_offers = VBoxContainer.new()
	_offers.add_theme_constant_override("separation", 4)
	vbox.add_child(_offers)
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
	is_owner = building.owner_id == viewer.owner_id
	_status.text = ""
	rebuild()
	visible = true


func close() -> void:
	visible = false


func show_status(text: String) -> void:
	_status.text = text


## Baut Inhalt und Angebote aus dem aktuellen Zustand neu (nach Änderungen oder Snapshots).
func rebuild() -> void:
	if building == null:
		return
	_title.text = ("Dein Handelstisch" if is_owner else "Handelstisch von %s" % building.owner_id) + " · Inhalt %d/%d" % [building.contents_count(), data.bali("building.table_capacity")]
	for child: Node in _stock.get_children():
		_stock.remove_child(child)
		child.queue_free()
	for child: Node in _offers.get_children():
		_offers.remove_child(child)
		child.queue_free()
	_offer_rows.clear()
	if is_owner:
		_build_owner_stock()
		_build_owner_offers()
	else:
		_build_buyer_offers()


func _build_owner_stock() -> void:
	var header := Label.new()
	header.text = "Lager (du hast · im Tisch)"
	_stock.add_child(header)
	for rid: String in data.resource_order:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = "%s: %d · %d" % [data.resources[rid]["name"], int(viewer.inventory.get(rid, 0)), int(building.contents.get(rid, 0))]
		label.custom_minimum_size = Vector2(220, 0)
		row.add_child(label)
		for amount: int in [1, 5]:
			var put := Button.new()
			put.text = "+%d einlagern" % amount
			put.pressed.connect(func() -> void: deposit_requested.emit(building.id, rid, amount))
			row.add_child(put)
			var take := Button.new()
			take.text = "−%d entnehmen" % amount
			take.pressed.connect(func() -> void: withdraw_requested.emit(building.id, rid, amount))
			row.add_child(take)
		_stock.add_child(row)


func _build_owner_offers() -> void:
	var header := Label.new()
	header.text = "Angebote (verkaufe … für …); leere Zeilen zählen nicht"
	_offers.add_child(header)
	var max_offers := data.bali("building.table_max_offers")
	for i in max_offers:
		var offer: Dictionary = building.offers[i] if i < building.offers.size() else {}
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(_label("%d. verkaufe" % (i + 1)))
		var sell_amount := _spin(int(offer.get("sell_amount", 0)), 0)
		row.add_child(sell_amount)
		var sell := _resource_button(String(offer.get("sell", data.resource_order[0])))
		row.add_child(sell)
		row.add_child(_label("für"))
		var price_amount := _spin(int(offer.get("price_amount", 0)), 0)
		row.add_child(price_amount)
		var price := _resource_button(String(offer.get("price", data.resource_order[mini(1, data.resource_order.size() - 1)])))
		row.add_child(price)
		_offers.add_child(row)
		_offer_rows.append({"sell": sell, "sell_amount": sell_amount, "price": price, "price_amount": price_amount})
	var apply := Button.new()
	apply.text = "Angebote speichern"
	apply.pressed.connect(_emit_offers)
	_offers.add_child(apply)


func _emit_offers() -> void:
	var offers := []
	for row: Dictionary in _offer_rows:
		var sell_amount := int(row["sell_amount"].value)
		var price_amount := int(row["price_amount"].value)
		if sell_amount <= 0 or price_amount <= 0:
			continue
		offers.append({
			"sell": data.resource_order[row["sell"].selected], "sell_amount": sell_amount,
			"price": data.resource_order[row["price"].selected], "price_amount": price_amount,
		})
	offers_requested.emit(building.id, offers)


func _build_buyer_offers() -> void:
	if building.offers.is_empty():
		_offers.add_child(_label("Keine Angebote."))
		return
	for i in building.offers.size():
		var offer: Dictionary = building.offers[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var stock := int(building.contents.get(offer["sell"], 0))
		var text := "%d %s für %d %s" % [int(offer["sell_amount"]), data.resources[offer["sell"]]["name"], int(offer["price_amount"]), data.resources[offer["price"]]["name"]]
		text += "  (Vorrat %d, du hast %d %s)" % [stock, int(viewer.inventory.get(offer["price"], 0)), data.resources[offer["price"]]["name"]]
		var label := Label.new()
		label.text = text
		label.custom_minimum_size = Vector2(480, 0)
		row.add_child(label)
		var buy := Button.new()
		buy.text = "Kaufen"
		buy.disabled = stock < int(offer["sell_amount"])
		buy.pressed.connect(func() -> void: buy_requested.emit(building.id, i))
		row.add_child(buy)
		_offers.add_child(row)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _spin(value: int, min_value: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = 99
	spin.value = value
	return spin


func _resource_button(selected: String) -> OptionButton:
	var button := OptionButton.new()
	for i in data.resource_order.size():
		button.add_item(String(data.resources[data.resource_order[i]]["name"]), i)
		if data.resource_order[i] == selected:
			button.select(i)
	return button
