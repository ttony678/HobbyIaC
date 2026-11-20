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
apt-get install -y curl unzip sqlite3 rsync cron fail2ban

# --- fail2ban (SSH brute-force defense in depth) ---
# Key-only auth already blocks brute force, but fail2ban adds rate
# limiting so a scanner cannot hammer port 22 forever. The sshd jail is
# disabled by default in the package config, so enable it explicitly.
printf "[sshd]\nenabled = true\n" > /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl start fail2ban 2>/dev/null || systemctl restart fail2ban

# --- App user and dirs ---
id -u "$APP_USER" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$APP_USER"
mkdir -p /opt/pantry /opt/splitter /opt/splitter/photos /var/backups/hobby
chown -R "$APP_USER:$APP_USER" /opt/pantry /opt/splitter /var/backups/hobby

# --- SSH hardening ---
# Key-only auth. No account on this VM has a usable password (root is
# locked, apps has nologin), but turn password auth off outright so a
# password can never become a way in. Safe to re-run.
mkdir -p /etc/ssh/sshd_config.d
printf "PasswordAuthentication no\n" > /etc/ssh/sshd_config.d/99-disable-password-auth.conf
# X11 forwarding is unused; turn it off to shrink the surface.
printf "X11Forwarding no\n" > /etc/ssh/sshd_config.d/99-disable-x11-forwarding.conf
sshd -t
systemctl reload sshd 2>/dev/null || systemctl reload ssh

# --- Bun ---
if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash
fi
# Copy (not symlink) the binary to /usr/local/bin. The app services run
# as user `apps`, which cannot traverse root's home, so a symlink into
# /root/.bun fails with "Permission denied" (status 203/EXEC).
if [ -f "$HOME/.bun/bin/bun" ]; then
  rm -f /usr/local/bin/bun
  cp "$HOME/.bun/bin/bun" /usr/local/bin/bun
  chmod 755 /usr/local/bin/bun
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
#
# Fail fast with a clear, actionable error if Serve is not enabled,
# instead of dying mid-script on a confusing serve error. The check greps
# the status output for the "not enabled" message rather than trusting
# the exit code, so it triggers on the real disabled output either way.
# The script is idempotent, so after enabling Serve, re-running it picks
# up where it left off.
serve_out=$(tailscale serve status 2>&1) || true
if echo "$serve_out" | grep -qi "not enabled"; then
  echo "ERROR: Tailscale Serve is not enabled on this tailnet." >&2
  echo "The apps cannot be exposed until it is enabled." >&2
  echo "$serve_out" >&2
  echo "Enable Serve in the Tailscale admin console, then re-run this script." >&2
  exit 1
fi
tailscale serve --bg --https=443 --set-path=/pantry "http://127.0.0.1:${PANTRY_PORT}"
tailscale serve --bg --https=443 --set-path=/splitter "http://127.0.0.1:${SPLITTER_PORT}"
tailscale serve status

# --- Nightly backup cron (02:00 local) ---
cp "$(dirname "$0")/backup.sh" /usr/local/bin/hobby-backup.sh
chmod +x /usr/local/bin/hobby-backup.sh
# The || true matters: on a fresh VM there is no crontab yet, so
# `crontab -l` and `grep -v` both exit 1, and with set -e + pipefail that
# would kill the script before the echo runs.
(crontab -l 2>/dev/null | grep -v hobby-backup || true; echo "0 2 * * * /usr/local/bin/hobby-backup.sh") | crontab -

echo "Bootstrap done. Next: deploy/deploy.sh ships the app bundles and data,"
echo "then 'systemctl start pantry splitter' brings both apps up."
