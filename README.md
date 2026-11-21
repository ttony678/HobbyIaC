# HobbyIaC

Infrastructure as code for Tony's hobby self-hosting: Pantry (better AnyList)
and Splitter (better Splitwise/Tab) on a single Hetzner VM, behind Tailscale.

## Decisions (recorded 2026-11-19)

- **Box: Hetzner CPX02, Helsinki (`hel1`), ~$6.59/mo with IPv4.** Cheapest
  orderable plan. CX22 is retired and its replacement CX23 is sold out.
  1 vCPU, 1 GB RAM, 20 GB disk, 20 TB traffic in the EU.
- **Region is a variable, not a commitment.** If the box ever needs to move
  (e.g. to US West / Hillsboro `hil` for latency), the lift is: new VM from
  this repo, copy the two SQLite files and the photo folder, rejoin the
  tailnet. See `docs/region-move.md`. The US lineup is pricier (older tiers,
  ~$20/mo, 1 TB traffic), so cheap EU is the default.
- **Auth is Tailscale.** The VM joins Tony's tailnet; phone and desktop run
  the Tailscale app. Nothing is on the public internet, no login page.
- **One process per app.** Each app is a single Bun process that serves its
  static bundle, answers its API calls, and opens its own SQLite file.
  Pantry on port 3001, Splitter on port 3002, served at `/pantry` and
  `/splitter` via `tailscale serve`.
- **No VM purchase yet.** This repo is the plan and the setup, ready to run
  when the shim proof is done and Tony says go.

## Layout

- `hetzner/bootstrap.sh` - run once on a fresh VM (or via cloud-init).
  Installs Bun and Tailscale, creates the app dirs and systemd units,
  configures `tailscale serve`, sets up the nightly backup cron.
- `hetzner/systemd/` - `pantry.service` and `splitter.service`.
- `hetzner/backup.sh` - nightly copy of both databases and the receipt
  photo folder.
- `deploy/deploy.sh` - ships the built bundles and data files to the VM.
- `docs/region-move.md` - lift-and-shift procedure between regions.

## Secrets

Nothing secret lives in this repo. The Tailscale auth key is passed as
`TAILSCALE_AUTHKEY` at bootstrap time, and the Splitter LLM key
(`LLM_API_KEY`, plus `LLM_BASE_URL` / `LLM_MODEL`) is set on the VM, never
committed.

## Status

- [ ] Shim proof: both Bun shims built and verified locally (pending Tony's
  go-ahead; see the Hosting - Splitter and Pantry chat).
- [ ] First VM built from `hetzner/bootstrap.sh`.
- [ ] Pantry and Splitter verified live from a phone on the tailnet.

<!-- PR workflow test 2, 2026-11-20: branch + PR + bypass merge -->
