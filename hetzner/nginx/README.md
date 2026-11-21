# Nginx staging proxy (no Authelia)

Plain Nginx in front of Pantry staging. Authelia was dropped; auth is
app-level (email codes), so the proxy just routes, terminates TLS, and
adds the protections Nginx is good at.

## What Nginx does here

- **Reverse proxy.** Forwards everything to Pantry staging on 127.0.0.1:3003.
- **TLS termination.** Self-signed cert for the demo; production uses
  Lets Encrypt with a real domain.
- **Security headers.** HSTS, X-Content-Type-Options, X-Frame-Options,
  Referrer-Policy, Permissions-Policy, on every response.
- **Rate limiting.** Two zones: `api` (10 req/s, burst 20) for general
  traffic, `login` (5 req/min, burst 5) for the actions endpoint so
  nobody can spam login codes or brute-force. Returns 429 when exceeded.
- **SSE handling.** `/events` has buffering off and a long read timeout,
  otherwise Nginx would buffer the stream and live sync would stall.

## What Nginx does not do

- No sessions, no login, no 2FA, no CSRF protection. Those are app-level
  (sessions table, SameSite cookies, Origin check) and are covered in the
  app, not the proxy.
- No per-account lockout. Nginx rate-limits by IP; the app locks accounts
  after repeated failures for an email.

## Files

- `pantry-staging.conf` — the server block (template, DOMAIN is a placeholder).
- `../setup-nginx-staging.sh` — install script; idempotent, generates the
  self-signed cert if missing.
