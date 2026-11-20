#!/usr/bin/env bash
# Bootstrap a fresh Hetzner VM for Pantry + Splitter.
# Run once as root on the new VM, or via cloud-init user_data.
# Region, server type, and hostname are variables at the top.
# Secrets are passed in as environment, never committed.
set -euo pipefail

# --- Config (change per deployment) ---
REGION="${REGION:-hel1}"            # hel1 Helsinki (cheap) | hil Hillsboro (US West)
SERVER_TYPE="${SERVER_TYPE:-cpx02}" # cheapest orderable Hetzner plan, Nov 2026
HOSTNAME="${HOSTNAME:-hobby-vm}"
PANTRY_PORT="${PANTRY_PORT:-3001}"
SPLITTER_PORT="${SPLITTER_PORT:-3002}"
APP_USER="${APP_USER:-apps}"
# TAILSCALE_AUTHKEY must be set in the environment on first run (an
# ephemeral auth key). It is single-use, so a re-run must not require it:
# the join step below is skipped when the node is already on the tailnet.

echo "Bootstrapping $HOSTNAME ($SERVER_TYPE in $REGION)..."

# --- Base packages ---
apt-get update -y
apt-get install -y curl unzip sqlite3 rsync cron

# --- App user and dirs ---
id -u "$APP_USER" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$APP_USER"
mkdir -p /opt/pantry /opt/splitter /opt/splitter/photos /var/backups/hobby
chown -R "$APP_USER:$APP_USER" /opt/pantry /opt/splitter /var/backups/hobby

# --- Bun ---
if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash
  ln -sf /root/.bun/bin/bun /usr/local/bin/bun
fi
bun --version

# --- Tailscale ---
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
# Join the tailnet only if not already on it. The auth key is single-use,
# so a re-run must not require it or call `tailscale up` again.
if tailscale status >/dev/null 2>&1; then
  echo "Already on the tailnet, skipping tailscale up."
else
  if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "TAILSCALE_AUTHKEY is not set. Generate an ephemeral auth key in the Tailscale admin panel and re-run." >&2
    exit 1
  fi
  tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$HOSTNAME" --accept-routes=false
fi
tailscale status

# --- Systemd units ---
cp "$(dirname "$0")/systemd/pantry.service" /etc/systemd/system/pantry.service
cp "$(dirname "$0")/systemd/splitter.service" /etc/systemd/system/splitter.service
systemctl daemon-reload
systemctl enable pantry splitter

# --- Serve both apps on the tailnet ---
# Pantry at /pantry, Splitter at /splitter. No public ports.
# Tailscale 1.104+ dropped the old `serve <path> <target>` form; the path
# now goes in --set-path. Requires the Serve feature to be enabled on the
# tailnet (admin console) or these commands fail.
tailscale serve --bg --https=443 --set-path=/pantry "http://127.0.0.1:${PANTRY_PORT}"
tailscale serve --bg --https=443 --set-path=/splitter "http://127.0.0.1:${SPLITTER_PORT}"
tailscale serve status

# --- Nightly backup cron (02:00 local) ---
cp "$(dirname "$0")/backup.sh" /usr/local/bin/hobby-backup.sh
chmod +x /usr/local/bin/hobby-backup.sh
(crontab -l 2>/dev/null | grep -v hobby-backup; echo "0 2 * * * /usr/local/bin/hobby-backup.sh") | crontab -

echo "Bootstrap done. Next: deploy/deploy.sh ships the app bundles and data,"
echo "then 'systemctl start pantry splitter' brings both apps up."
