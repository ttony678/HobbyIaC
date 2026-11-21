#!/usr/bin/env bash
# Installs Nginx + Authelia on hobby-vm and puts Pantry staging behind it.
# Staging demo only. Run on the VM as root. Idempotent: safe to re-run.
# Usage: ./setup-authelia-staging.sh [DOMAIN] [TEST_PASSWORD]
#   DOMAIN defaults to the VM public IP. TEST_PASSWORD defaults to a random
#   value printed at the end (the demo login is user "tony").
set -euo pipefail
DOMAIN="${1:-$(curl -s https://ifconfig.me)}"
TEST_PASSWORD="${2:-$(openssl rand -hex 8)}"
AUTHELIA_VERSION="${AUTHELIA_VERSION:-v4.39.28}"
PANTRY_STAGING_PORT="${PANTRY_STAGING_PORT:-3003}"

apt-get update -qq
apt-get install -y -qq nginx openssl curl

# Authelia binary (single static binary, no package needed).
if ! [ -x /usr/local/bin/authelia ]; then
  cd /tmp
  curl -sL -o authelia.tar.gz "https://github.com/authelia/authelia/releases/download/${AUTHELIA_VERSION}/authelia-${AUTHELIA_VERSION}-linux-amd64.tar.gz"
  tar xzf authelia.tar.gz authelia
  install -m 755 authelia /usr/local/bin/authelia
  rm -f authelia.tar.gz authelia
fi

mkdir -p /etc/authelia /var/lib/authelia /etc/nginx/ssl
SESSION_SECRET="$(openssl rand -hex 32)"
STORAGE_KEY="$(openssl rand -hex 32)"
PASSWORD_HASH="$(authelia crypto hash generate --password "$TEST_PASSWORD" 2>/dev/null | tail -1)"

# Config from the template in this repo, with secrets filled in.
sed -e "s/DOMAIN/$DOMAIN/g" -e "s/SESSION_SECRET/$SESSION_SECRET/g" -e "s/STORAGE_KEY/$STORAGE_KEY/g" \
  hetzner/authelia/configuration.yml > /etc/authelia/configuration.yml
sed -e "s/PASSWORD_HASH/$PASSWORD_HASH/g" \
  hetzner/authelia/users_database.yml.example > /etc/authelia/users_database.yml
chmod 600 /etc/authelia/configuration.yml /etc/authelia/users_database.yml
authelia config validate --config /etc/authelia/configuration.yml

# Self-signed cert for the demo (30 days). Production uses Lets Encrypt.
if ! [ -f /etc/nginx/ssl/staging.crt ]; then
  openssl req -x509 -newkey rsa:2048 -keyout /etc/nginx/ssl/staging.key \
    -out /etc/nginx/ssl/staging.crt -days 30 -nodes \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=IP:$DOMAIN" 2>/dev/null
fi

cp hetzner/systemd/authelia.service /etc/systemd/system/authelia.service
sed "s/DOMAIN/$DOMAIN/g" hetzner/nginx/pantry-staging-auth.conf \
  > /etc/nginx/sites-available/pantry-staging-auth
ln -sf /etc/nginx/sites-available/pantry-staging-auth /etc/nginx/sites-enabled/pantry-staging-auth
nginx -t
systemctl daemon-reload
systemctl enable --now authelia
systemctl reload nginx

echo "Authelia staging demo is live."
echo "  App (login required): https://$DOMAIN:8080"
echo "  Login portal:         https://$DOMAIN:8081"
echo "  Demo user: tony / $TEST_PASSWORD"
echo "  (Self-signed cert: expect a browser warning. Production uses Lets Encrypt.)"
