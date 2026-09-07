extends SceneTree
## Rauchtest mit Fenster: startet die Hauptszene, öffnet das Ausloggen-Menü (Advanced), wählt eine Rolle,
## loggt aus, schaut kurz zu und loggt wieder ein. Prüft Zeichen- und UI-Code, der headless nicht läuft.
## Aufruf: godot --path . -s tools/smoke_run.gd   (beendet sich selbst, Ausgabe "SMOKE OK")


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var main: Node2D = load("res://game/main.tscn").instantiate()
	root.add_child(main)
	await _frames(20)
	main._open_menu()
	main.menu._advanced.button_pressed = true
	await _frames(10)
	main.menu._select_role("gatherer")
	main.menu._add_rule()
	await _frames(5)
	main.menu._on_confirm()
	await _frames(60)
	main._login()
	await _frames(20)
	print("SMOKE OK")
	quit()


func _frames(n: int) -> void:
	for i in n:
		await process_frame
