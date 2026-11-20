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

## Multi-user SSE

Recorded Nov 20, 2026, per Tony. Also future design, not to be built now.

Today the SSE message is almost nothing: `{"queryKeys": []}`, an empty list
meaning "something changed." No user, no trip, no list. Every connected
client gets the same message, treats it as a trigger, runs its revision
check, and refetches only if its revision moved. That works now because it
is one household and a handful of clients.

For multi-user with sharing (around 1000 users), the broadcast is the
thing that breaks: a change to one list would wake every client, and each
client would get events for lists it cannot see. The shape that fits is
per-list channels. A list is the unit of sharing, so the server keeps a
client set per list, not one global set. When a mutation touches a list, it
broadcasts only to that list's clients. The message then carries the list
ID and that list's revision, and optionally which queries changed and who
made the change. The client discards it if the list ID is not one it is
viewing, or if the revision is not newer than its own.

Two pieces make that work. First, per-list revisions instead of one global
revision, so a change to list A does not bump list B and wake its clients.
Second, the SSE connection is authenticated at connect time, so the server
only sends a client events for lists it can access, and never leaks that
another list changed at all.

Keep the event as a trigger, not the data. The client still refetches
through the normal authenticated API, which is where access control lives.
That keeps the SSE layer small and the authorization in one place.

At 1000 users that scales fine: a mutation wakes only the handful of
clients on that list, not all 1000. The global broadcast is what would not
scale.

Prerequisite: per-list revisions do not exist yet. Pantry today has a
single global revision counter (one row in the `meta` table, key
"revision"), because there is only one list. Per-list revisions arrive
with the multi-user data model (a lists table, `list_id` on every row, and
a revision counter per list).
