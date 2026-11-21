#!/usr/bin/env bash
# Nightly backup: both SQLite files + Splitter receipt photos.
# Keeps 14 days locally. Offsite copy is a later step, not built yet.
set -euo pipefail

DEST="/var/backups/hobby/$(date +%F)"
mkdir -p "$DEST"

# Use sqlite3 .backup for a consistent snapshot. A plain `cp` of app.db
# misses un-checkpointed WAL data (both DBs run in WAL mode), so a backup
# taken that way can silently miss recent transactions. .backup reads the
# live DB through SQLite and writes a complete, consistent copy.
if [ -f /opt/pantry/app.db ]; then
  sqlite3 /opt/pantry/app.db ".backup $DEST/pantry-app.db"
else
  echo "pantry app.db not present yet"
fi
if [ -f /opt/splitter/app.db ]; then
  sqlite3 /opt/splitter/app.db ".backup $DEST/splitter-app.db"
else
  echo "splitter app.db not present yet"
fi
rsync -a --delete /opt/splitter/photos/ "$DEST/photos/" 2>/dev/null || echo "no photos yet"

# Backup DBs hold personal financial data; keep them out of world-read.
chmod 640 "$DEST"/pantry-app.db "$DEST"/splitter-app.db 2>/dev/null || true

find /var/backups/hobby -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
echo "Backup done: $DEST"
