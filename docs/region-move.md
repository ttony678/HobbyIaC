# Region move (lift and shift)

Moving between Hetzner regions is a data copy plus a rebuild from this repo,
not a migration. The whole state is two SQLite files and a photo folder.

## Procedure

1. **Build the new VM from this repo** in the target region. Same
   `hetzner/bootstrap.sh`, with `REGION` changed (e.g. `hel1` to `hil`).
   Same server type if it is available there, otherwise the nearest
   equivalent.
2. **Stop writes on the old VM** so the databases are clean:
   `systemctl stop pantry splitter`. Stopping cleanly checkpoints the
   SQLite WAL into the main `.db` files.
3. **Copy the data.** From the old VM (or from a backup):
   - `/opt/pantry/app.db` to `/opt/pantry/app.db`
   - `/opt/splitter/app.db` to `/opt/splitter/app.db`
   - `/opt/splitter/photos/` to `/opt/splitter/photos/`
   Use `rsync -a`. Verify sizes and row counts after the copy.
4. **Deploy the current bundles** with `deploy/deploy.sh` if the new VM
   does not already have them.
5. **Start the new VM:** `systemctl start pantry splitter`, then check
   `tailscale serve status` and open both apps from a phone on the tailnet.
   Clients resync off the revision counters.
6. **Retire the old VM** only after the new one is verified live. Delete
   the old server in the Hetzner console.

## Downtime

Minutes. The copy itself is under a megabyte of databases plus photos.

## What changes, what does not

- Changes: VM hostname and tailnet address, region, latency.
- Does not change: the app code, the data, the Tailscale auth model, the
  backup layout. Region is a variable in `bootstrap.sh`, nothing else.

## Shortcut (not a replacement)

Hetzner snapshots restore in any region, so a snapshot can clone a VM
across regions. It goes stale, and it bakes in machine identity
(Tailscale keys, hostname) that has to be fixed up after restore. Use the
scripted build above as the source of truth.
