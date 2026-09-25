#!/bin/bash
# Spielt den Server vom Entwicklungsrechner aus auf einen Ubuntu-Server (z. B. Hetzner) ein, per SSH.
# Aufruf (Git Bash oder Linux):  tools/deploy.sh root@1.2.3.4 [Port] [NPC-Füllung] [Karte]
# NPC-Füllung (Standard 10) gilt nur für eine neue Welt. Karte: gen:60x45:7 (generiert) oder 'standard'; leer = beim
# ersten Mal die Standardkarte, danach bleibt die eingerichtete (siehe install-server.sh). Eine Karten-JSON wird nicht
# mitkopiert: sie muss schon auf dem Server liegen, lesbar für den Dienstbenutzer (z. B. /var/lib/prototyp/karte.json).
# Nimmt build/prototyp-server.x86_64 (tools/build.sh), sonst den aktuellen Build von GitHub (Release "latest").
# Erstes Mal: richtet den Dienst ein. Später: stoppt (speichert), sichert die Welt, tauscht das Programm, startet.
set -euo pipefail
TARGET="${1:-}"
PORT="${2:-7777}"
NPCS="${3:-10}"
MAP="${4:-}"
RELEASE_URL="https://github.com/ShivaHaze/godot-game/releases/download/latest"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "$TARGET" ]; then
  echo "Aufruf: $0 <user@host> [Port] [NPC-Füllung] [Karte]" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
if [ -f "$ROOT/build/prototyp-server.x86_64" ]; then
  echo "Nehme den lokalen Build build/prototyp-server.x86_64."
  cp "$ROOT/build/prototyp-server.x86_64" "$STAGE/"
else
  echo "Kein lokaler Build – lade den aktuellen Build von GitHub."
  curl -fsSL -o "$STAGE/prototyp-server.x86_64" "$RELEASE_URL/prototyp-server.x86_64"
fi
cp "$ROOT/tools/dist/install-server.sh" "$ROOT/tools/dist/update-server.sh" "$ROOT/tools/dist/LIZENZEN.txt" "$STAGE/"

echo "Kopiere nach $TARGET:~/prototyp-deploy/ …"
ssh "$TARGET" 'mkdir -p ~/prototyp-deploy'
scp -q "$STAGE"/* "$TARGET:~/prototyp-deploy/"
echo "Richte ein bzw. aktualisiere (Port $PORT, $NPCS NPCs, Karte ${MAP:-wie eingerichtet bzw. Standard}) …"
ssh -t "$TARGET" "sudo bash ~/prototyp-deploy/install-server.sh $PORT $NPCS $MAP"
