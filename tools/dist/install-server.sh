#!/bin/bash
# Richtet den Spielserver auf einem Ubuntu-Server (z. B. Hetzner) als Systemdienst ein.
# Aufruf als root im Ordner mit prototyp-server.x86_64:  sudo bash install-server.sh [Port] [NPC-Füllung]
# Danach: systemctl status prototyp-server · journalctl -u prototyp-server -f · Spielstand in /var/lib/prototyp/
set -euo pipefail
PORT="${1:-7777}"
NPCS="${2:-200}"
BIN_DIR=/opt/prototyp
DATA_DIR=/var/lib/prototyp
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$HERE/prototyp-server.x86_64" ]; then
  echo "prototyp-server.x86_64 fehlt neben diesem Skript." >&2
  exit 1
fi
id -u prototyp >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin prototyp
mkdir -p "$BIN_DIR" "$DATA_DIR"
install -m 755 "$HERE/prototyp-server.x86_64" "$BIN_DIR/prototyp-server"
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
WorkingDirectory=$BIN_DIR
ExecStart=$BIN_DIR/prototyp-server --headless -- --server $PORT $NPCS
Restart=on-failure
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prototyp-server
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$PORT/udp" >/dev/null || true
fi
sleep 2
systemctl --no-pager status prototyp-server | head -12
echo
echo "Fertig. Spieler tragen im Startbildschirm ein: $(hostname -I 2>/dev/null | awk '{print $1}'):$PORT"
echo "Log: journalctl -u prototyp-server -f · Spielstand: $DATA_DIR/godot/app_userdata/Prototyp/server_save.dat"
