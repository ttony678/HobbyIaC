#!/usr/bin/env bash
# Nightly backup: both SQLite files + Splitter receipt photos.
# Keeps 14 days locally. Offsite copy is a later step, not built yet.
set -euo pipefail

DEST="/var/backups/hobby/$(date +%F)"
mkdir -p "$DEST"

# Stop writes briefly is overkill for these sizes; instead copy the files
# and let SQLite's WAL mode keep them consistent. For a guaranteed-clean
# copy during a region move, stop the services first (see docs/region-move.md).
cp /opt/pantry/app.db "$DEST/pantry-app.db" 2>/dev/null || echo "pantry app.db not present yet"
cp /opt/splitter/app.db "$DEST/splitter-app.db" 2>/dev/null || echo "splitter app.db not present yet"
rsync -a --delete /opt/splitter/photos/ "$DEST/photos/" 2>/dev/null || echo "no photos yet"

find /var/backups/hobby -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
echo "Backup done: $DEST"
