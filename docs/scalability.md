# Future scalability: splitting the monolith

Recorded Nov 20, 2026, per Tony. This is a future design, not to be built
now. The monoliths stay as-is.

## Today

Each app (Pantry, Splitter) is one Bun process, a self-contained monolith
that does everything for that app instance: it serves the static UI bundle,
runs the API actions against its SQLite file, and holds the SSE client set
in memory. There are four such monoliths on hobby-vm (Pantry prod/staging,
Splitter prod/staging), each with its own process, DB file, port, and Serve
path, sharing nothing. This is the right call at household scale.

## The split, when we need it

If an app outgrows a single process (for example the closed beta, many
users, or a DB that outgrows SQLite), the monolith splits into three
processes:

1. **UI server.** Serves only the static client bundle (index.html, JS,
   CSS). It never touches the database. Stateless, so it is easy to
   replicate behind a load balancer.
2. **API server.** Runs the actions (`POST /actions`), owns data access,
   and serves the SSE stream (`GET /events`). The application logic and
   the in-memory SSE client set live here.
3. **DB server.** A separate database server (for example Postgres)
   replacing SQLite. The API server connects to it over the network.
   This one is a "possibly": it only exists when the DB becomes a real
   server. With SQLite the DB is a file the API process opens directly,
   so the split is two processes (UI + API), not three.

## Routing

A reverse proxy (Tailscale Serve, nginx, or Cloudflare) routes by path:
`/` goes to the UI server, `/actions` and `/events` go to the API server.
The API server connects to the DB server. The browser loads the UI from
one process and sends its API calls and SSE connection to the other.

## Applies to

Pantry and Splitter. Both apps follow the same shape, so the same split
applies to each.
