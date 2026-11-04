#!/bin/bash
# Copyright (C) 2026 Ephraim BOURIAHI
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Install a systemd service hosting the EduTerra whiteboard page over HTTPS.
# Usage: sudo ./setup-whiteboard.sh
#   Prompts for the port and a domain name. With a domain, a trusted
#   Let's Encrypt certificate is obtained and renewed automatically.
#   Without one, a self-signed certificate is generated.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_USER="${SUDO_USER:-root}"
SERVICE_NAME="eduterra-whiteboard"
SERVER_IP="$(hostname -I | awk '{print $1}')"
CERT_FILE="$DIR/certs/cert.pem"
KEY_FILE="$DIR/certs/key.pem"

read -rp "Port for the whiteboard [443]: " PORT
PORT="${PORT:-443}"
read -rp "Domain name pointing to this server (leave empty for a self-signed certificate): " DOMAIN
if [ -n "$DOMAIN" ]; then
    read -rp "Email for Let's Encrypt expiry notices: " EMAIL
fi

mkdir -p "$DIR/certs"

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EduTerra Whiteboard HTTPS Server (port ${PORT})
After=network.target

[Service]
User=${SERVICE_USER}
ExecStart=/usr/bin/python3 ${DIR}/whiteboard_server.py ${PORT} --cert ${CERT_FILE} --key ${KEY_FILE}
Restart=always
# Allows ports below 1024 (e.g. 443) without running as root
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# Only touches the firewall if ufw is installed
HAS_UFW=$(command -v ufw || true)
[ -n "$HAS_UFW" ] && ufw allow "${PORT}/tcp"

if [ -n "$DOMAIN" ]; then
    command -v certbot >/dev/null || { apt-get update && apt-get install -y certbot; }

    # Let's Encrypt checks domain ownership over port 80 (now and at each renewal)
    [ -n "$HAS_UFW" ] && ufw allow 80/tcp

    # Renewal hook: the service doesn't run as root, so it can't read
    # /etc/letsencrypt; copy the cert next to the app and restart it
    HOOK="/etc/letsencrypt/renewal-hooks/deploy/${SERVICE_NAME}.sh"
    mkdir -p "$(dirname "$HOOK")"
    cat > "$HOOK" <<EOF
#!/bin/sh
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${CERT_FILE}
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem ${KEY_FILE}
chown ${SERVICE_USER}: ${CERT_FILE} ${KEY_FILE}
chmod 600 ${KEY_FILE}
systemctl try-restart ${SERVICE_NAME}
EOF
    chmod +x "$HOOK"

    certbot certonly --standalone --non-interactive --agree-tos \
        -d "$DOMAIN" -m "$EMAIL"
    "$HOOK"
    URL="https://${DOMAIN}:${PORT}/"
else
    if [ ! -f "$CERT_FILE" ]; then
        echo "Generating self-signed certificate for $(hostname) / $SERVER_IP..."
        openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$(hostname)" \
            -addext "subjectAltName=DNS:$(hostname),DNS:localhost,IP:$SERVER_IP,IP:127.0.0.1"
        chown "$SERVICE_USER:" "$CERT_FILE" "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi
    URL="https://${SERVER_IP}:${PORT}/"
fi

systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

echo "Whiteboard hosted at: ${URL}"
echo "  Status: systemctl status ${SERVICE_NAME}"
echo "  Logs:   journalctl -u ${SERVICE_NAME} -f"
