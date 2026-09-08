#!/bin/bash
# Baut Client und Server als eigenständige Programme nach build/ (Windows-Client, Windows-Server, Linux-Server).
# Voraussetzung: Godot 4.7.2 als `godot` im PATH (oder GODOT=<Pfad>) und die Export-Vorlagen 4.7.2 unter
# ~/.local/share/godot/export_templates/4.7.2.stable/ (siehe tools/install_templates.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
mkdir -p build
"$GODOT" --headless --path . --import
"$GODOT" --headless --path . --export-release "Windows Client" build/Prototyp-Client.exe
"$GODOT" --headless --path . --export-release "Windows Server" build/Prototyp-Server.exe
"$GODOT" --headless --path . --export-release "Linux Server" build/prototyp-server.x86_64
cp tools/dist/* build/
ls -la build
