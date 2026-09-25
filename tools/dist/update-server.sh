#!/bin/bash
# Holt den aktuellen Server-Build von GitHub (Release "latest") und spielt ihn ein: Dienst stoppen (speichert),
# Welt sichern, Programm austauschen, Dienst starten. Port, NPC-Füllung und Karte bleiben wie eingerichtet.
# Aufruf als root:  sudo bash /opt/prototyp/update-server.sh
set -euo pipefail
RELEASE_URL="https://github.com/ShivaHaze/godot-game/releases/download/latest"
UNIT=/etc/systemd/system/prototyp-server.service

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen: sudo bash $0" >&2
  exit 1
fi
if [ ! -f "$UNIT" ]; then
  echo "Der Dienst ist noch nicht eingerichtet – zuerst install-server.sh ausführen." >&2
  exit 1
fi
# Port, Füllung und Karte aus der Dienstdefinition lesen: ExecStart=... --server <Port> <NPCs> [<Laufzeit> <Karte>]
# Die Karte muss erhalten bleiben: die Welt in world.db gehört zu ihr.
PORT=""; NPCS=""; MAP=""
read -r PORT NPCS _RUNTIME MAP _REST < <(sed -n 's/^ExecStart=.*--server //p' "$UNIT") || true
case "$PORT" in ''|*[!0-9]*) PORT=7777 ;; esac
case "$NPCS" in ''|*[!0-9]*) NPCS=10 ;; esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Lade den aktuellen Build …"
curl -fsSL -o "$TMP/prototyp-server.x86_64" "$RELEASE_URL/prototyp-server.x86_64"
curl -fsSL -o "$TMP/install-server.sh" "$RELEASE_URL/install-server.sh"
curl -fsSL -o "$TMP/update-server.sh" "$RELEASE_URL/update-server.sh"
curl -fsSL -o "$TMP/LIZENZEN.txt" "$RELEASE_URL/LIZENZEN.txt" || true
curl -fsSL -o "$TMP/VERSION.txt" "$RELEASE_URL/VERSION.txt" || true
[ -f "$TMP/VERSION.txt" ] && cat "$TMP/VERSION.txt"
echo "Übernehme: Port $PORT, Füllung $NPCS, Karte ${MAP:-Standard}"
if [ -n "$MAP" ]; then
  bash "$TMP/install-server.sh" "$PORT" "$NPCS" "$MAP"
else
  bash "$TMP/install-server.sh" "$PORT" "$NPCS"
fi
