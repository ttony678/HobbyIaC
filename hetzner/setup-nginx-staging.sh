#!/usr/bin/env bash
# Installs Nginx on hobby-vm and puts Pantry staging behind it (no Authelia).
# Staging demo / learning setup. Run on the VM as root. Idempotent.
# Usage: ./setup-nginx-staging.sh [DOMAIN]
#   DOMAIN defaults to the VM public IP.
set -euo pipefail
DOMAIN="${1:-$(curl -s https://ifconfig.me)}"
PANTRY_STAGING_PORT="${PANTRY_STAGING_PORT:-3003}"

apt-get update -qq
apt-get install -y -qq nginx openssl curl

mkdir -p /etc/nginx/ssl
# Self-signed cert for the demo (30 days). Production uses Lets Encrypt.
if ! [ -f /etc/nginx/ssl/staging.crt ]; then
  openssl req -x509 -newkey rsa:2048 -keyout /etc/nginx/ssl/staging.key \
    -out /etc/nginx/ssl/staging.crt -days 30 -nodes \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=IP:$DOMAIN" 2>/dev/null
fi

sed "s/DOMAIN/$DOMAIN/g" hetzner/nginx/pantry-staging.conf \
  > /etc/nginx/sites-available/pantry-staging
ln -sf /etc/nginx/sites-available/pantry-staging /etc/nginx/sites-enabled/pantry-staging
nginx -t
systemctl reload nginx

echo "Nginx staging proxy is live."
echo "  Pantry staging (no proxy auth): https://$DOMAIN:8080"
echo "  (Self-signed cert: expect a browser warning. Production uses Lets Encrypt.)"
