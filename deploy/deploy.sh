#!/usr/bin/env bash
# Ship the built app bundles and data files to the VM.
# Run from your workstation after the shim proof build.
# TBD (pending shim proof): the exact build output paths.
set -euo pipefail

VM="${VM:-root@hobby-vm}"  # tailnet hostname or IP of the VM
# Local build outputs (paths from the shim proof; update when it lands):
PANTRY_SRC="${PANTRY_SRC:-$HOME/workspace/ts-spaces/list-app}"
SPLITTER_SRC="${SPLITTER_SRC:-$HOME/workspace/ts-spaces/finance-app}"

echo "Deploying to $VM..."

# App bundles: static client + server shim.
# TODO: replace with the real shim build outputs once the proof exists.
rsync -a --delete "$PANTRY_SRC/client/dist/" "$VM:/opt/pantry/client/"
rsync -a --delete "$SPLITTER_SRC/client/dist/" "$VM:/opt/splitter/client/"

# Data: SQLite files + receipt photos. Only copy the .db files when you mean
# to seed or restore; a routine code deploy should NOT overwrite live data.
# Uncomment the lines below for a first deploy or a restore:
# rsync -a "$PANTRY_SRC/app.db" "$VM:/opt/pantry/app.db"
# rsync -a "$SPLITTER_SRC/app.db" "$VM:/opt/splitter/app.db"
# rsync -a "$SPLITTER_SRC/photos/" "$VM:/opt/splitter/photos/"

ssh "$VM" 'systemctl restart pantry splitter && systemctl status pantry splitter --no-pager'
echo "Deploy done."
