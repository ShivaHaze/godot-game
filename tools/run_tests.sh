#!/bin/sh
# Führt alle GUT-Tests headless aus (Git Bash). Exit-Code 0 = alle Tests grün.
cd "$(dirname "$0")/.." || exit 1
# Import-Cache (.godot/) aufbauen – nötig, damit class_name-Klassen headless auflösbar sind.
godot --headless --path . --import >/dev/null 2>&1
godot --headless --path . -s addons/gut/gut_cmdln.gd
