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

# Serve the EduTerra whiteboard page over HTTPS with nginx.
# Usage: sudo ./setup-whiteboard.sh
#   Prompts for the port and a domain name. With a domain, a trusted
#   Let's Encrypt certificate is obtained and renewed automatically.
#   Without one, a self-signed certificate is generated.
# The page is copied to /var/www/eduterra-whiteboard: re-run the script
# after editing it to publish the new version.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="eduterra-whiteboard"
WEB_ROOT="/var/www/$NAME"
SITE="/etc/nginx/sites-available/$NAME"
SERVER_IP="$(hostname -I | awk '{print $1}')"

read -rp "Port for the whiteboard [443]: " PORT
PORT="${PORT:-443}"
read -rp "Domain name pointing to this server (leave empty for a self-signed certificate): " DOMAIN
if [ -n "$DOMAIN" ]; then
    read -rp "Email for Let's Encrypt expiry notices: " EMAIL
fi

# Remove the previous Python-based setup, if any (it holds the port)
if [ -f "/etc/systemd/system/$NAME.service" ]; then
    systemctl disable --now "$NAME" || true
    rm -f "/etc/systemd/system/$NAME.service"
    systemctl daemon-reload
fi
rm -rf "/opt/$NAME" "/etc/letsencrypt/renewal-hooks/deploy/$NAME.sh"
id -u "$NAME" >/dev/null 2>&1 && userdel "$NAME"

apt-get update
apt-get install -y nginx
[ -n "$DOMAIN" ] && apt-get install -y certbot

install -d -m 755 "$WEB_ROOT"
install -m 644 "$SRC_DIR/EduTerraWhiteboard.html" "$WEB_ROOT/index.html"

# Only touches the firewall if ufw is installed
if command -v ufw >/dev/null; then
    ufw allow "$PORT/tcp"
    ufw allow 80/tcp
fi

if [ -n "$DOMAIN" ]; then
    CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    # Let's Encrypt verifies the domain on port 80, which nginx also uses:
    # pause nginx for those few seconds, now and at each renewal
    mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post}
    printf '#!/bin/sh\nsystemctl stop nginx\n'  > /etc/letsencrypt/renewal-hooks/pre/nginx.sh
    printf '#!/bin/sh\nsystemctl start nginx\n' > /etc/letsencrypt/renewal-hooks/post/nginx.sh
    chmod +x /etc/letsencrypt/renewal-hooks/{pre,post}/nginx.sh

    systemctl stop nginx
    certbot certonly --standalone --non-interactive --agree-tos -d "$DOMAIN" -m "$EMAIL"
    URL="https://$DOMAIN"
else
    CERT_FILE="/etc/nginx/ssl/$NAME.crt"
    KEY_FILE="/etc/nginx/ssl/$NAME.key"
    if [ ! -f "$CERT_FILE" ]; then
        echo "Generating self-signed certificate for $(hostname) / $SERVER_IP..."
        install -d -m 700 /etc/nginx/ssl
        openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$(hostname)" \
            -addext "subjectAltName=DNS:$(hostname),DNS:localhost,IP:$SERVER_IP,IP:127.0.0.1"
        chmod 600 "$KEY_FILE"
    fi
    URL="https://$SERVER_IP"
fi

[ "$PORT" != 443 ] && URL="$URL:$PORT"

cat > "$SITE" <<EOF
# Redirect plain HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    return 301 ${URL}\$request_uri;
}

server {
    listen ${PORT} ssl;
    listen [::]:${PORT} ssl;

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;

    root ${WEB_ROOT};
    index index.html;
    server_tokens off;

    add_header Cache-Control "no-cache";
    add_header Strict-Transport-Security "max-age=31536000";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# Replace nginx's default welcome site with this one
rm -f /etc/nginx/sites-enabled/default
ln -sf "$SITE" "/etc/nginx/sites-enabled/$NAME"

nginx -t
systemctl enable nginx
systemctl restart nginx

echo "Whiteboard hosted at: $URL/"
echo "  Status: systemctl status nginx"
echo "  Logs:   tail -f /var/log/nginx/access.log /var/log/nginx/error.log"
