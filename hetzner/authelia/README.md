# Authelia staging demo

Puts Pantry staging behind an Authelia login, via Nginx `auth_request`.
This is the public-hosting exploration: a self-hosted, open source
replacement for Cloudflare Access (which caps the free tier at 50 users).

## How it works

- Nginx listens on 8080 (the app) and 8081 (the Authelia login portal),
  both HTTPS with a self-signed cert for the demo.
- Every request to the app hits `auth_request /authelia` first. Nginx asks
  Authelia's `/api/verify` whether the request has a valid session.
- Unauthenticated requests get a 302 to the login portal. After login,
  Authelia sets a session cookie and redirects back to the app.
- Authelia runs on 127.0.0.1:9091, users are file-based, one-factor auth
  for the demo. The Pantry staging app itself is untouched; it still runs
  on port 3003 behind the proxy.

## Files

- `configuration.yml` — Authelia config template (secrets are placeholders).
- `users_database.yml.example` — example users file (hash is a placeholder).
- `../systemd/authelia.service` — systemd unit.
- `../nginx/pantry-staging-auth.conf` — Nginx server blocks (template).
- `../setup-authelia-staging.sh` — install script; generates secrets, the
  password hash, and the self-signed cert, then enables the services.

## Demo credentials

The install script prints a test password for user `tony`. The password
and the generated secrets live only on the VM, never in this repo.

## What this does not do

- No real domain or Lets Encrypt cert yet (self-signed, browser warning).
- No 2FA (one_factor for the demo).
- Staging only. Prod is untouched and still tailnet-only.
