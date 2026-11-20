#!/usr/bin/env bash
# Ship the built app bundles and data files to the VM.
# Usage: ./deploy.sh [pantry|splitter|all] [--seed] [--staging]
#   --seed copies the SQLite DBs (app.db*) and Splitter receipt photos.
#   Use it for a first deploy or a restore only. A routine code deploy
#   must NOT overwrite live data, so seed is opt-in.
#   --staging deploys to the staging monoliths instead of prod:
#   /opt/pantry-staging (port 3003, /pantry-staging) and
#   /opt/splitter-staging (port 3004, /splitter-staging). Staging is a
#   self-contained copy of each app with its own DB, photos, port, and
#   SSE stream, so staging and prod never share state.
# The systemd units live in hetzner/systemd/; they are installed by
# bootstrap.sh, not by this script. If a unit changes, re-copy it on the
# VM and run `systemctl daemon-reload`.
set -euo pipefail

VM="${VM:-root@hobby-vm}"
PANTRY_SRC="${PANTRY_SRC:-$HOME/workspace/ts-spaces/list-app}"
SPLITTER_SRC="${SPLITTER_SRC:-$HOME/workspace/ts-spaces/finance-app}"

APP="all"
SEED=0
STAGING=0
for arg in "$@"; do
  case "$arg" in
    pantry|splitter|all) APP="$arg" ;;
    --seed) SEED=1 ;;
    --staging) STAGING=1 ;;
    *) echo "Usage: $0 [pantry|splitter|all] [--seed] [--staging]" >&2; exit 1 ;;
  esac
done

# Staging targets the -staging monoliths; prod targets the plain ones.
if [ "$STAGING" = 1 ]; then
  SUFFIX="-staging"
  TARGET="staging"
else
  SUFFIX=""
  TARGET="prod"
fi

echo "Deploying $APP to $VM ($TARGET, seed=$SEED)..."

# OpenSSH runs as root and reads /root/.ssh/config, which is ephemeral and
# is wiped on a VM replacement. The persistent master copy lives at
# ~/.ssh/config. Restore it if missing so SSH uses the egress proxy
# (without it SSH falls back to a direct connection the egress resets).
if [ ! -f /root/.ssh/config ]; then
  if [ ! -f "$HOME/.ssh/config" ]; then
    echo "SSH config missing: neither /root/.ssh/config nor $HOME/.ssh/config exists" >&2
    exit 1
  fi
  echo "Restoring /root/.ssh/config from $HOME/.ssh/config (VM replacement wiped it)..."
  cp "$HOME/.ssh/config" /root/.ssh/config
  chmod 600 /root/.ssh/config
fi

deploy_app() {
  local name="$1" src="$2" dest="$3"
  echo "--- $name: shipping shim, server, node_modules, client ---"
  # rsync creates the destination dir itself but not missing parents,
  # so make the tree first or the server/dist rsync fails with code 11.
  ssh "$VM" "mkdir -p $dest/server/dist $dest/node_modules $dest/client"
  rsync -a --delete "$src/shim.js" "$VM:$dest/shim.js"
  rsync -a --delete "$src/server/dist/" "$VM:$dest/server/dist/"
  rsync -a --delete -z "$src/node_modules/" "$VM:$dest/node_modules/"
  rsync -a --delete "$src/client/dist/" "$VM:$dest/client/dist/"
  if [ "$SEED" = 1 ]; then
    echo "--- $name: seeding DB ---"
    rsync -a "$src"/app.db* "$VM:$dest/"
  fi
}

RESTART=""
CHOWN_DIRS=""
if [ "$APP" = "pantry" ] || [ "$APP" = "all" ]; then
  deploy_app "pantry$SUFFIX" "$PANTRY_SRC" "/opt/pantry$SUFFIX"
  RESTART="$RESTART pantry$SUFFIX"
  CHOWN_DIRS="$CHOWN_DIRS /opt/pantry$SUFFIX"
fi
if [ "$APP" = "splitter" ] || [ "$APP" = "all" ]; then
  deploy_app "splitter$SUFFIX" "$SPLITTER_SRC" "/opt/splitter$SUFFIX"
  if [ "$SEED" = 1 ]; then
    echo "--- splitter$SUFFIX: seeding receipt photos (blobs/ -> photos/) ---"
    rsync -a "$SPLITTER_SRC/blobs/" "$VM:/opt/splitter$SUFFIX/photos/"
  fi
  RESTART="$RESTART splitter$SUFFIX"
  CHOWN_DIRS="$CHOWN_DIRS /opt/splitter$SUFFIX"
fi

# The services run as user `apps`; make the shipped files theirs.
# (DBs and photos must be writable by apps; code just needs to be readable.)
# Only chown the dirs actually deployed, so a staging deploy of one app
# does not fail if the other staging dir does not exist yet.
# shellcheck disable=SC2086
ssh "$VM" "chown -R apps:apps $CHOWN_DIRS"

# shellcheck disable=SC2086
ssh "$VM" "systemctl restart $RESTART && systemctl status $RESTART --no-pager"
echo "Deploy done."
