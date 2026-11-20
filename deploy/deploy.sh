#!/usr/bin/env bash
# Ship the built app bundles and data files to the VM.
# Usage: ./deploy.sh [pantry|splitter|all] [--seed]
#   --seed copies the SQLite DBs (app.db*) and Splitter receipt photos.
#   Use it for a first deploy or a restore only. A routine code deploy
#   must NOT overwrite live data, so seed is opt-in.
# The systemd units live in hetzner/systemd/; they are installed by
# bootstrap.sh, not by this script. If a unit changes, re-copy it on the
# VM and run `systemctl daemon-reload`.
set -euo pipefail

VM="${VM:-root@hobby-vm}"
PANTRY_SRC="${PANTRY_SRC:-$HOME/workspace/ts-spaces/list-app}"
SPLITTER_SRC="${SPLITTER_SRC:-$HOME/workspace/ts-spaces/finance-app}"

APP="all"
SEED=0
for arg in "$@"; do
  case "$arg" in
    pantry|splitter|all) APP="$arg" ;;
    --seed) SEED=1 ;;
    *) echo "Usage: $0 [pantry|splitter|all] [--seed]" >&2; exit 1 ;;
  esac
done

echo "Deploying $APP to $VM (seed=$SEED)..."

deploy_app() {
  local name="$1" src="$2" dest="$3"
  echo "--- $name: shipping shim, server, node_modules, client ---"
  rsync -a --delete "$src/shim.js" "$VM:$dest/shim.js"
  rsync -a --delete "$src/server/dist/" "$VM:$dest/server/dist/"
  rsync -a --delete -z "$src/node_modules/" "$VM:$dest/node_modules/"
  rsync -a --delete "$src/client/dist/" "$VM:$dest/client/"
  if [ "$SEED" = 1 ]; then
    echo "--- $name: seeding DB ---"
    rsync -a "$src"/app.db* "$VM:$dest/"
  fi
}

RESTART=""
if [ "$APP" = "pantry" ] || [ "$APP" = "all" ]; then
  deploy_app pantry "$PANTRY_SRC" /opt/pantry
  RESTART="$RESTART pantry"
fi
if [ "$APP" = "splitter" ] || [ "$APP" = "all" ]; then
  deploy_app splitter "$SPLITTER_SRC" /opt/splitter
  if [ "$SEED" = 1 ]; then
    echo "--- splitter: seeding receipt photos (blobs/ -> photos/) ---"
    rsync -a "$SPLITTER_SRC/blobs/" "$VM:/opt/splitter/photos/"
  fi
  RESTART="$RESTART splitter"
fi

# The services run as user `apps`; make the shipped files theirs.
# (DBs and photos must be writable by apps; code just needs to be readable.)
ssh "$VM" 'chown -R apps:apps /opt/pantry /opt/splitter'

# shellcheck disable=SC2086
ssh "$VM" "systemctl restart $RESTART && systemctl status $RESTART --no-pager"
echo "Deploy done."
