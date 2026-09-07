extends SceneTree
## Schreibt eine generierte Karte als JSON (sim/map_gen.gd). Ergebnis lässt sich als data/map.json einsetzen
## oder dem Server per --map übergeben.
## Aufruf: godot --headless --path . -s tools/map_gen.gd -- <Breite> <Höhe> <Seed> <Ausgabedatei>
## Beispiel: godot --headless --path . -s tools/map_gen.gd -- 120 90 7 data/maps/gross_120x90.json


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var width := int(args[0]) if args.size() > 0 else 120
	var height := int(args[1]) if args.size() > 1 else 90
	var seed := int(args[2]) if args.size() > 2 else 1
	var path := String(args[3]) if args.size() > 3 else "data/maps/gen_%dx%d_%d.json" % [width, height, seed]
	var map := MapGen.generate(width, height, seed)
	var data := SimData.load_from_dir("res://data")
	if data.apply_map(map).is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(map, "  "))
		file.close()
		print("Karte geschrieben: %s (%d×%d, Seed %d, %d Spieler-Spawns, %d Wolf-Spawns)" % [path, width, height, seed, data.player_spawns.size(), data.wolf_spawns.size()])
	else:
		printerr("Karte ungültig: ", data.apply_map(map))
	quit()
