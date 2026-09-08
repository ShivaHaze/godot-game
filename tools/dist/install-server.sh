#!/bin/bash
# Richtet den Spielserver auf einem Ubuntu-Server (z. B. Hetzner) als Systemdienst ein – oder aktualisiert ihn.
# Aufruf als root:  sudo bash install-server.sh [Port] [NPC-Füllung]
# Liegt kein prototyp-server.x86_64 neben dem Skript, wird der aktuelle Build von GitHub (Release "latest") geladen.
# Läuft der Dienst schon, wird er vorher gestoppt (speichert), die Welt gesichert und danach neu gestartet.
# Danach: systemctl status prototyp-server · journalctl -u prototyp-server -f · Welt und Konten in /var/lib/prototyp/
set -euo pipefail
PORT="${1:-7777}"
NPCS="${2:-200}"
BIN_DIR=/opt/prototyp
DATA_DIR=/var/lib/prototyp
SAVE_DIR="$DATA_DIR/godot/app_userdata/Prototyp"
RELEASE_URL="https://github.com/ShivaHaze/godot-game/releases/download/latest"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen: sudo bash $0 $*" >&2
  exit 1
fi
if [ ! -f "$HERE/prototyp-server.x86_64" ]; then
  echo "Lade den aktuellen Server-Build von GitHub …"
  curl -fsSL -o "$HERE/prototyp-server.x86_64" "$RELEASE_URL/prototyp-server.x86_64"
fi
if ! "$HERE/prototyp-server.x86_64" --version >/dev/null 2>&1; then
  chmod +x "$HERE/prototyp-server.x86_64"
  "$HERE/prototyp-server.x86_64" --version >/dev/null 2>&1 || { echo "prototyp-server.x86_64 startet nicht (falsche Architektur oder kaputter Download)." >&2; exit 1; }
fi

id -u prototyp >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin prototyp
mkdir -p "$BIN_DIR" "$DATA_DIR"

# Laufenden Dienst stoppen (SIGINT speichert die Welt) und die Datenbank vor dem Austausch sichern
if systemctl is-active --quiet prototyp-server 2>/dev/null; then
  echo "Stoppe den laufenden Dienst (speichert) …"
  systemctl stop prototyp-server
fi
if [ -f "$SAVE_DIR/world.db" ]; then
  mkdir -p "$SAVE_DIR/backups"
  cp "$SAVE_DIR/world.db" "$SAVE_DIR/backups/world-vor-update-$(date -u +%Y-%m-%dT%H-%M).db"
  [ -f "$SAVE_DIR/accounts.db" ] && cp "$SAVE_DIR/accounts.db" "$SAVE_DIR/backups/accounts-vor-update-$(date -u +%Y-%m-%dT%H-%M).db"
fi

install -m 755 "$HERE/prototyp-server.x86_64" "$BIN_DIR/prototyp-server"
[ -f "$HERE/update-server.sh" ] && install -m 755 "$HERE/update-server.sh" "$BIN_DIR/update-server.sh"
[ -f "$HERE/LIZENZEN.txt" ] && install -m 644 "$HERE/LIZENZEN.txt" "$BIN_DIR/LIZENZEN.txt"
chown -R prototyp:prototyp "$DATA_DIR"

cat > /etc/systemd/system/prototyp-server.service <<EOF
[Unit]
Description=Prototyp Spielserver (Port $PORT/udp)
After=network-online.target
Wants=network-online.target

[Service]
User=prototyp
Group=prototyp
Environment=HOME=$DATA_DIR
Environment=XDG_DATA_HOME=$DATA_DIR
Environment=XDG_CONFIG_HOME=$DATA_DIR/config
Environment=XDG_CACHE_HOME=$DATA_DIR/cache
WorkingDirectory=$BIN_DIR
ExecStart=$BIN_DIR/prototyp-server --headless -- --server $PORT $NPCS
Restart=on-failure
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=30
# Abschottung: nur der Datenordner ist beschreibbar
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prototyp-server
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$PORT/udp" >/dev/null || true
fi
sleep 3
if ! systemctl is-active --quiet prototyp-server; then
  echo "Der Dienst läuft nicht. Letzte Zeilen des Logs:" >&2
  journalctl -u prototyp-server -n 30 --no-pager >&2 || true
  exit 1
fi
systemctl --no-pager status prototyp-server | head -12
echo
echo "Fertig. Spieler tragen im Startbildschirm ein: $(hostname -I 2>/dev/null | awk '{print $1}'):$PORT"
echo "Log: journalctl -u prototyp-server -f · Welt: $SAVE_DIR/world.db (Sicherungen in backups/), Konten: accounts.db"
echo "Update später: sudo bash $BIN_DIR/update-server.sh"
